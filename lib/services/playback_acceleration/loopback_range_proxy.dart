import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/playback_acceleration/byte_range.dart';
import 'package:PiliPlus/services/playback_acceleration/range_fetcher.dart';

enum ProxyTrackType { video, audio }

int recommendedRangeProxyConcurrency({required bool isWifi}) => isWifi ? 4 : 2;

final class ProxyFailure {
  final String sessionId;
  final ProxyTrackType trackType;
  final String reason;

  const ProxyFailure({
    required this.sessionId,
    required this.trackType,
    required this.reason,
  });
}

final class ProxyMediaHandle {
  final LoopbackRangeProxy _proxy;
  final String sessionId;
  final Uri localUri;
  final Uri fallbackUri;

  ProxyMediaHandle._(
    this._proxy,
    this.sessionId,
    this.localUri,
    this.fallbackUri,
  );

  Future<void> close() => _proxy.closeSession(sessionId);

  void cancelActiveTransfers() => _proxy.cancelActiveTransfers(sessionId);
}

final class LoopbackRangeProxy {
  final int chunkSize;
  final int globalMaxConcurrency;
  final Duration responseTimeout;
  final Duration bodyStallTimeout;
  final Duration totalTimeout;

  final Map<String, _ProxySession> _sessions = {};
  final Random _random = Random.secure();
  late final _AsyncSemaphore _budget;
  HttpServer? _server;

  LoopbackRangeProxy({
    this.chunkSize = 256 * 1024,
    this.globalMaxConcurrency = 16,
    this.responseTimeout = const Duration(seconds: 6),
    this.bodyStallTimeout = const Duration(seconds: 4),
    this.totalTimeout = const Duration(seconds: 15),
  }) {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    if (globalMaxConcurrency < 1 || globalMaxConcurrency > 16) {
      throw ArgumentError.value(
        globalMaxConcurrency,
        'globalMaxConcurrency',
        'must be between 1 and 16',
      );
    }
    _budget = _AsyncSemaphore(globalMaxConcurrency);
  }

  InternetAddress get address {
    final server = _server;
    if (server == null) throw StateError('Proxy has not started');
    return server.address;
  }

  int get port {
    final server = _server;
    if (server == null) throw StateError('Proxy has not started');
    return server.port;
  }

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(server.forEach(_handleRequest));
  }

  ProxyMediaHandle createSession({
    required Uri upstream,
    required ProxyTrackType trackType,
    int? maxConcurrency,
    int? expectedTotal,
    Map<String, String> headers = const {},
    void Function(ProxyFailure failure)? onFailure,
  }) {
    final server = _server;
    if (server == null) throw StateError('Proxy has not started');
    if (upstream.scheme != 'http' && upstream.scheme != 'https') {
      throw ArgumentError.value(upstream.scheme, 'upstream', 'must be HTTP(S)');
    }
    final concurrency = (maxConcurrency ?? 8).clamp(1, 16);
    final token = _newToken();
    final session = _ProxySession(
      id: token,
      upstream: upstream,
      trackType: trackType,
      maxConcurrency: concurrency,
      expectedTotal: expectedTotal,
      headers: Map.unmodifiable(headers),
      onFailure: onFailure,
    );
    _sessions[token] = session;
    final localUri = Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: '/v1/media/$token',
    );
    return ProxyMediaHandle._(this, token, localUri, upstream);
  }

  Future<void> closeSession(String sessionId) async {
    _sessions.remove(sessionId)?.close();
  }

  void cancelActiveTransfers(String sessionId) {
    _sessions[sessionId]?.cancelActiveTransfers();
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
    await server?.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.set('X-Content-Type-Options', 'nosniff');
    if (request.uri.query.isNotEmpty) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    final segments = request.uri.pathSegments;
    if (segments.length != 3 || segments[0] != 'v1' || segments[1] != 'media') {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final session = _sessions[segments[2]];
    if (session == null || session.isClosed) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }

    final rawRange = request.headers.value(HttpHeaders.rangeHeader);
    if (rawRange == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await response.close();
      return;
    }
    ByteRange requestedRange;
    try {
      requestedRange = ByteRange.parseHeader(rawRange);
    } on FormatException {
      final openRange = RegExp(
        r'^bytes=(\d+)-$',
      ).firstMatch(rawRange.trim());
      if (openRange == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      final start = int.parse(openRange.group(1)!);
      var total = session.expectedTotal;
      if (total == null) {
        final client = session.openClient();
        try {
          final probe = await _fetch(client, session, const ByteRange(0, 0));
          total = probe.total;
          session.expectedTotal = total;
        } catch (error) {
          session.notifyFailure(error);
          response
            ..statusCode = HttpStatus.badGateway
            ..contentLength = 0;
          await response.close();
          return;
        } finally {
          session.releaseClient(client);
        }
      }
      if (start >= total) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      requestedRange = ByteRange(start, total - 1);
    }

    if (request.method == 'HEAD') {
      await _serveHead(response, session, requestedRange);
      return;
    }
    await _serveGet(response, session, requestedRange);
  }

  Future<void> _serveHead(
    HttpResponse response,
    _ProxySession session,
    ByteRange requestedRange,
  ) async {
    final client = session.openClient();
    try {
      final chunk = await _fetch(
        client,
        session,
        ByteRange(requestedRange.start, requestedRange.start),
      );
      session.expectedTotal ??= chunk.total;
      response.statusCode = HttpStatus.partialContent;
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(
          HttpHeaders.contentRangeHeader,
          'bytes ${requestedRange.start}-${requestedRange.end}/${chunk.total}',
        )
        ..contentLength = requestedRange.length;
      await response.close();
    } catch (error) {
      session.notifyFailure(error);
      response
        ..statusCode = HttpStatus.badGateway
        ..contentLength = 0;
      await response.close();
    } finally {
      session.releaseClient(client);
    }
  }

  Future<void> _serveGet(
    HttpResponse response,
    _ProxySession session,
    ByteRange requestedRange,
  ) async {
    final client = session.openClient();
    var headersSent = false;
    try {
      final pieces = _splitFixed(requestedRange, chunkSize);
      final inFlight = <int, Future<_FetchOutcome>>{};
      var nextToLaunch = 0;

      void fillWindow() {
        while (nextToLaunch < pieces.length &&
            inFlight.length < session.maxConcurrency) {
          final index = nextToLaunch++;
          inFlight[index] = _fetch(client, session, pieces[index]).then(
            _FetchOutcome.success,
            onError: _FetchOutcome.failure,
          );
        }
      }

      fillWindow();
      int? total = session.expectedTotal;
      for (var index = 0; index < pieces.length; index += 1) {
        final outcome = await inFlight.remove(index)!;
        if (outcome.error case final error?) {
          Error.throwWithStackTrace(error, outcome.stackTrace!);
        }
        final chunk = outcome.chunk!;
        total ??= chunk.total;
        if (chunk.total != total) {
          throw const RangeFetchException('resource total changed');
        }
        session.expectedTotal ??= total;
        if (!headersSent) {
          response
            ..statusCode = HttpStatus.partialContent
            ..bufferOutput = false
            ..contentLength = requestedRange.length;
          response.headers
            ..set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
            ..set(
              HttpHeaders.contentRangeHeader,
              'bytes ${requestedRange.start}-${requestedRange.end}/$total',
            );
          headersSent = true;
        }
        response.add(chunk.bytes);
        await response.flush();
        fillWindow();
      }
      await response.close();
    } catch (error) {
      client.close(force: true);
      session.notifyFailure(error);
      if (!headersSent) {
        response
          ..statusCode = HttpStatus.badGateway
          ..contentLength = 0;
      }
      await response.close();
    } finally {
      session.releaseClient(client);
    }
  }

  Future<RangeChunk> _fetch(
    HttpClient client,
    _ProxySession session,
    ByteRange range,
  ) async {
    await _budget.acquire();
    try {
      final fetcher = StrictRangeFetcher(
        responseTimeout: responseTimeout,
        bodyStallTimeout: bodyStallTimeout,
        totalTimeout: totalTimeout,
      );
      return await fetcher.fetch(
        client,
        session.upstream,
        range,
        expectedTotal: session.expectedTotal,
        headers: session.headers,
      );
    } finally {
      _budget.release();
    }
  }

  List<ByteRange> _splitFixed(ByteRange range, int size) {
    final result = <ByteRange>[];
    var cursor = range.start;
    while (cursor <= range.end) {
      final end = min(range.end, cursor + size - 1);
      result.add(ByteRange(cursor, end));
      cursor = end + 1;
    }
    return result;
  }

  String _newToken() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

final class _ProxySession {
  final String id;
  final Uri upstream;
  final ProxyTrackType trackType;
  final int maxConcurrency;
  final Map<String, String> headers;
  final void Function(ProxyFailure failure)? onFailure;
  final Set<HttpClient> _clients = {};
  int? expectedTotal;
  bool isClosed = false;
  bool _intentionalCancellation = false;
  bool _failureNotified = false;

  _ProxySession({
    required this.id,
    required this.upstream,
    required this.trackType,
    required this.maxConcurrency,
    required this.expectedTotal,
    required this.headers,
    required this.onFailure,
  });

  HttpClient openClient() {
    if (isClosed) throw StateError('Session is closed');
    _intentionalCancellation = false;
    final client = HttpClient()..autoUncompress = false;
    _clients.add(client);
    return client;
  }

  void releaseClient(HttpClient client) {
    _clients.remove(client);
    client.close(force: true);
  }

  void cancelActiveTransfers() {
    _intentionalCancellation = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  void close() {
    if (isClosed) return;
    isClosed = true;
    cancelActiveTransfers();
  }

  void notifyFailure(Object error) {
    if (isClosed || _intentionalCancellation || _failureNotified) return;
    _failureNotified = true;
    final reason = switch (error) {
      RangeFetchException(:final reason) => reason,
      FormatException() => 'invalid upstream response',
      StateError() => 'session state failure',
      _ => 'unexpected proxy failure',
    };
    onFailure?.call(
      ProxyFailure(sessionId: id, trackType: trackType, reason: reason),
    );
  }
}

final class _AsyncSemaphore {
  final int limit;
  final List<Completer<void>> _waiters = [];
  int _active = 0;

  _AsyncSemaphore(this.limit);

  Future<void> acquire() {
    if (_active < limit) {
      _active += 1;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    if (_active <= 0) throw StateError('Semaphore released too often');
    _active -= 1;
  }
}

final class _FetchOutcome {
  final RangeChunk? chunk;
  final Object? error;
  final StackTrace? stackTrace;

  const _FetchOutcome.success(this.chunk) : error = null, stackTrace = null;

  const _FetchOutcome.failure(this.error, this.stackTrace) : chunk = null;
}
