import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/services/playback_acceleration/byte_range.dart';
import 'package:PiliPlus/services/playback_acceleration/range_fetcher.dart';
import 'package:crypto/crypto.dart' show Digest, sha256;

enum ProxyTrackType { video, audio }

/// A point-in-time view of the range work owned by one proxy session.
///
/// [activeRequests] counts only upstream Range requests that are currently
/// inside the fetcher.  Requests waiting for the shared budget are not counted
/// until they actually start, and audio sessions never contribute to this
/// value.  [maxConcurrency] is the user-selected per-session ceiling.
final class RangeConcurrencySnapshot {
  final int activeRequests;
  final int maxConcurrency;

  const RangeConcurrencySnapshot(this.activeRequests, this.maxConcurrency)
    : assert(activeRequests >= 0),
      assert(maxConcurrency >= 0);

  int get activeVideoRequests => activeRequests;
  int get configuredLimit => maxConcurrency;

  @override
  bool operator ==(Object other) =>
      other is RangeConcurrencySnapshot &&
      other.activeRequests == activeRequests &&
      other.maxConcurrency == maxConcurrency;

  @override
  int get hashCode => Object.hash(activeRequests, maxConcurrency);
}

int recommendedRangeProxyConcurrency({
  required bool isWifi,
  int maxConcurrency = 128,
}) {
  final ceiling = maxConcurrency.clamp(1, 128);
  return isWifi ? ceiling : min(16, ceiling);
}

/// An aggressive, demand-driven controller for slow cross-region CDNs.
///
/// [maxConcurrency] is a hard user-selected ceiling, not a target that must be
/// kept busy. Buffer pressure, slow chunks and transport stalls rapidly open
/// more slots. Only an explicit server throttling response reduces the window.
/// Existing transfers are not interrupted when the window changes.
final class RangeConcurrencyController {
  final int maxConcurrency;
  int _currentConcurrency;

  RangeConcurrencyController({
    required int initialConcurrency,
    required this.maxConcurrency,
  }) : _currentConcurrency = initialConcurrency {
    if (maxConcurrency < 1 || maxConcurrency > 128) {
      throw ArgumentError.value(
        maxConcurrency,
        'maxConcurrency',
        'must be between 1 and 128',
      );
    }
    if (initialConcurrency < 1 || initialConcurrency > maxConcurrency) {
      throw ArgumentError.value(
        initialConcurrency,
        'initialConcurrency',
        'must be between 1 and maxConcurrency',
      );
    }
  }

  int get currentConcurrency => _currentConcurrency;

  void requestMoreCapacity() {
    if (_currentConcurrency >= maxConcurrency) return;
    _currentConcurrency = min(
      maxConcurrency,
      max(_currentConcurrency + 1, _currentConcurrency * 2),
    );
  }

  void recordSuccess(RangeChunk chunk) {
    if (chunk.ttfb >= const Duration(seconds: 1) ||
        chunk.elapsed >= const Duration(seconds: 2)) {
      requestMoreCapacity();
    }
  }

  void recordFailure(Object error) {
    if (_isExplicitRateLimit(error)) {
      _currentConcurrency = max(1, (_currentConcurrency / 2).ceil());
      return;
    }
    if (_isRecoverableTransportPressure(error)) {
      requestMoreCapacity();
    }
  }

  bool _isExplicitRateLimit(Object error) {
    if (error is! RangeFetchException) return false;
    return error.reason.contains('got 429') || error.reason.contains('got 503');
  }

  bool _isRecoverableTransportPressure(Object error) {
    if (error is! RangeFetchException) return false;
    return error.reason.contains('timeout') ||
        error.reason.contains('stalled') ||
        error.reason.contains('transport failure') ||
        error.reason.contains('socket failure');
  }
}

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

  void requestMoreConcurrency() => _proxy.requestMoreConcurrency(sessionId);

  RangeConcurrencySnapshot get concurrencySnapshot =>
      _proxy.concurrencySnapshot(sessionId);

  Stream<RangeConcurrencySnapshot> get concurrencyChanges =>
      _proxy.concurrencyChanges(sessionId);
}

final class LoopbackRangeProxy {
  /// The identity fingerprint covers at most the first 4 KiB of a resource.
  /// The probe window is clamped to the discovered total so that resources
  /// smaller than 4 KiB are fingerprinted over their full length instead of
  /// being rejected for an unsatisfiable range.
  static const _identityProbeRange = ByteRange(0, 4095);
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
    this.globalMaxConcurrency = 128,
    this.responseTimeout = const Duration(seconds: 6),
    this.bodyStallTimeout = const Duration(seconds: 4),
    this.totalTimeout = const Duration(seconds: 15),
  }) {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    if (globalMaxConcurrency < 1 || globalMaxConcurrency > 128) {
      throw ArgumentError.value(
        globalMaxConcurrency,
        'globalMaxConcurrency',
        'must be between 1 and 128',
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
    Iterable<Uri> fallbackUpstreams = const [],
    required ProxyTrackType trackType,
    int? maxConcurrency,
    int? initialConcurrency,
    int? expectedTotal,
    Map<String, String> headers = const {},
    void Function(ProxyFailure failure)? onFailure,
  }) {
    final server = _server;
    if (server == null) throw StateError('Proxy has not started');
    final upstreams = _validatedUpstreams(upstream, fallbackUpstreams);
    final concurrencyLimit = (maxConcurrency ?? 8).clamp(1, 128);
    final startingConcurrency = (initialConcurrency ?? concurrencyLimit).clamp(
      1,
      concurrencyLimit,
    );
    final token = _newToken();
    final session = _ProxySession(
      id: token,
      upstreams: upstreams,
      trackType: trackType,
      maxConcurrency: concurrencyLimit,
      initialConcurrency: startingConcurrency,
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

  List<Uri> _validatedUpstreams(Uri primary, Iterable<Uri> fallbacks) {
    final result = <Uri>[];
    final seen = <String>{};
    for (final candidate in [primary, ...fallbacks]) {
      if (candidate.scheme != 'http' && candidate.scheme != 'https') {
        throw ArgumentError.value(
          candidate.scheme,
          'upstream',
          'must be HTTP(S)',
        );
      }
      // A fallback may change host and signed query parameters, but it must
      // still name the same DASH representation. Total length is validated on
      // every fetched piece as a second identity check.
      if (candidate.path != primary.path) {
        throw ArgumentError.value(
          candidate,
          'fallbackUpstreams',
          'must use the same media path as the primary upstream',
        );
      }
      if (seen.add(candidate.toString())) result.add(candidate);
    }
    return List.unmodifiable(result);
  }

  Future<void> closeSession(String sessionId) async {
    _sessions.remove(sessionId)?.close();
  }

  void cancelActiveTransfers(String sessionId) {
    _sessions[sessionId]?.cancelActiveTransfers();
  }

  void requestMoreConcurrency(String sessionId) {
    _sessions[sessionId]?.requestMoreConcurrency();
  }

  RangeConcurrencySnapshot concurrencySnapshot(String sessionId) =>
      _sessions[sessionId]?.concurrencySnapshot ??
      const RangeConcurrencySnapshot(0, 0);

  Stream<RangeConcurrencySnapshot> concurrencyChanges(String sessionId) =>
      _sessions[sessionId]?.concurrencyChanges ??
      const Stream<RangeConcurrencySnapshot>.empty();

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
    final generation = session.generation;
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
        final client = session.openClient(generation);
        try {
          await _ensureVerifiedUpstreams(session, generation);
          session.throwIfStale(generation);
          total = session.expectedTotal;
          if (total == null) {
            final probe = await _fetch(
              client,
              session,
              const ByteRange(0, 0),
              generation,
            );
            total = probe.total;
            session.expectedTotal = total;
          }
        } catch (error) {
          session.notifyFailure(error, generation);
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
      await _serveHead(response, session, requestedRange, generation);
      return;
    }
    await _serveGet(response, session, requestedRange, generation);
  }

  Future<void> _serveHead(
    HttpResponse response,
    _ProxySession session,
    ByteRange requestedRange,
    int generation,
  ) async {
    final client = session.openClient(generation);
    try {
      await _ensureVerifiedUpstreams(session, generation);
      final chunk = await _fetch(
        client,
        session,
        ByteRange(requestedRange.start, requestedRange.start),
        generation,
      );
      session
        ..throwIfStale(generation)
        ..expectedTotal ??= chunk.total;
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
      session.notifyFailure(error, generation);
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
    int generation,
  ) async {
    final client = session.openClient(generation);
    var headersSent = false;
    try {
      await _ensureVerifiedUpstreams(session, generation);
      session.throwIfStale(generation);
      final pieces = _splitFixed(requestedRange, chunkSize);
      final inFlight = <int, Future<_FetchOutcome>>{};
      var nextToLaunch = 0;

      void fillWindow() {
        while (nextToLaunch < pieces.length &&
            inFlight.length < session.currentConcurrency) {
          final index = nextToLaunch++;
          inFlight[index] =
              _fetch(
                client,
                session,
                pieces[index],
                generation,
              ).then(
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
        session.throwIfStale(generation);
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
      session.notifyFailure(error, generation);
      if (!headersSent) {
        response
          ..statusCode = HttpStatus.badGateway
          ..contentLength = 0;
        await response.close();
      } else {
        // The 206 headers and a declared Content-Length are already on the
        // wire, so the body can no longer be completed honestly. Closing the
        // response aborts the stream; the close itself throws because the
        // short body violates the declared Content-Length. That error is the
        // expected cost of failing closed — the downstream must observe a
        // truncation instead of silently accepting a short body — so it is
        // handled locally and never escapes into the server loop.
        unawaited(
          response.close().catchError((Object _) {
            // Expected: short body vs. declared Content-Length.
          }),
        );
      }
    } finally {
      session.releaseClient(client);
    }
  }

  Future<RangeChunk> _fetch(
    HttpClient client,
    _ProxySession session,
    ByteRange range,
    int generation,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (final upstream in session.upstreamsByPreference) {
      session.throwIfStale(generation);
      try {
        final chunk = await _fetchFrom(
          client,
          session,
          upstream,
          range,
          generation,
        );
        session
          ..recordTransferSuccess(chunk)
          ..markSuccess(upstream);
        return chunk;
      } catch (error, stackTrace) {
        session
          ..throwIfStale(generation)
          ..recordTransferFailure(error);
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    Error.throwWithStackTrace(
      lastError ?? const RangeFetchException('no upstream candidates'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  Future<RangeChunk> _fetchFrom(
    HttpClient client,
    _ProxySession session,
    Uri upstream,
    ByteRange range,
    int generation,
  ) async {
    await _budget.acquire(
      highPriority: session.trackType == ProxyTrackType.video,
    );
    int? transferId;
    try {
      session.throwIfStale(generation);
      transferId = session.beginRangeTransfer();
      final chunk =
          await StrictRangeFetcher(
            responseTimeout: responseTimeout,
            bodyStallTimeout: bodyStallTimeout,
            totalTimeout: totalTimeout,
          ).fetch(
            client,
            upstream,
            range,
            expectedTotal: session.expectedTotal,
            headers: session.headers,
          );
      session.throwIfStale(generation);
      return chunk;
    } finally {
      session.endRangeTransfer(transferId);
      _budget.release();
    }
  }

  Future<void> _ensureVerifiedUpstreams(
    _ProxySession session,
    int generation,
  ) {
    if (session.hasVerifiedUpstreams) return Future.value();
    if (session.identityFuture case final pending?
        when session.identityGeneration == generation) {
      return pending;
    }
    final future = _verifyUpstreamIdentities(session, generation);
    session
      ..identityGeneration = generation
      ..identityFuture = future;
    return future;
  }

  Future<void> _verifyUpstreamIdentities(
    _ProxySession session,
    int generation,
  ) async {
    if (session.upstreams.length == 1) {
      // A single source can never mix bytes with another CDN, so the
      // init-range fingerprint probe would only add startup latency and an
      // extra request. Strict per-range validation and the first-chunk total
      // lock still apply on every fetch.
      session.installVerifiedUpstreams(session.upstreams, null, generation);
      return;
    }
    final outcomes = List<_IdentityOutcome?>.filled(
      session.upstreams.length,
      null,
    );
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < session.upstreams.length) {
        final index = nextIndex++;
        final upstream = session.upstreams[index];
        HttpClient? client;
        try {
          session.throwIfStale(generation);
          client = session.openClient(generation);
          final identity = await _probeResourceIdentity(
            client,
            session,
            upstream,
            generation,
          );
          outcomes[index] = _IdentityOutcome.success(identity);
        } catch (error, stackTrace) {
          outcomes[index] = _IdentityOutcome.failure(error, stackTrace);
        } finally {
          if (client != null) session.releaseClient(client);
        }
      }
    }

    final workerCount = min(session.maxConcurrency, session.upstreams.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    session.throwIfStale(generation);

    final baselineOutcome = outcomes.whereType<_IdentityOutcome>().firstWhere(
      (outcome) => outcome.identity != null,
      orElse: () {
        final failure = outcomes.whereType<_IdentityOutcome>().first;
        Error.throwWithStackTrace(failure.error!, failure.stackTrace!);
      },
    );
    final baseline = baselineOutcome.identity!;
    final verified = outcomes
        .whereType<_IdentityOutcome>()
        .map((outcome) => outcome.identity)
        .whereType<_ResourceIdentity>()
        .where(
          (identity) =>
              identity.total == baseline.total &&
              identity.digest == baseline.digest,
        )
        .map((identity) => identity.upstream)
        .toList(growable: false);
    if (verified.isEmpty) {
      throw const RangeFetchException('no compatible upstream candidates');
    }
    session.installVerifiedUpstreams(verified, baseline.total, generation);
  }

  /// Proves one upstream's resource identity: its total length plus the
  /// SHA-256 of its init window `bytes=0-min(4095, total - 1)`.
  ///
  /// When the session does not yet know the total, a one-byte discovery
  /// request learns it first so the fingerprint window can be clamped;
  /// without clamping, any resource smaller than 4 KiB would be rejected
  /// because a strict server truncates `bytes=0-4095` to its real end.
  Future<_ResourceIdentity> _probeResourceIdentity(
    HttpClient client,
    _ProxySession session,
    Uri upstream,
    int generation,
  ) async {
    var total = session.expectedTotal;
    List<int>? headByte;
    if (total == null) {
      final discovery = await _fetchFrom(
        client,
        session,
        upstream,
        const ByteRange(0, 0),
        generation,
      );
      total = discovery.total;
      headByte = discovery.bytes;
    }
    if (total <= 0) {
      throw const RangeFetchException('empty upstream resource');
    }
    final probeEnd = min(_identityProbeRange.end, total - 1);
    final List<int> fingerprintBytes;
    if (probeEnd == 0 && headByte != null) {
      fingerprintBytes = headByte;
    } else {
      final chunk = await _fetchFrom(
        client,
        session,
        upstream,
        ByteRange(0, probeEnd),
        generation,
      );
      if (chunk.total != total) {
        throw const RangeFetchException('resource total changed');
      }
      fingerprintBytes = chunk.bytes;
    }
    return _ResourceIdentity(
      upstream: upstream,
      total: total,
      digest: sha256.convert(fingerprintBytes),
    );
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
  final List<Uri> upstreams;
  final ProxyTrackType trackType;
  final int maxConcurrency;
  final RangeConcurrencyController _concurrencyController;
  final Map<String, String> headers;
  final void Function(ProxyFailure failure)? onFailure;
  final Set<HttpClient> _clients = {};
  final Set<int> _activeRangeTransfers = {};
  final StreamController<RangeConcurrencySnapshot> _concurrencyChanges =
      StreamController<RangeConcurrencySnapshot>.broadcast(sync: true);
  int? expectedTotal;
  bool isClosed = false;
  bool _intentionalCancellation = false;
  bool _failureNotified = false;
  int _preferredUpstreamIndex = 0;
  int generation = 0;
  List<Uri>? _verifiedUpstreams;
  Future<void>? identityFuture;
  int? identityGeneration;

  _ProxySession({
    required this.id,
    required this.upstreams,
    required this.trackType,
    required this.maxConcurrency,
    required int initialConcurrency,
    required this.expectedTotal,
    required this.headers,
    required this.onFailure,
  }) : _concurrencyController = RangeConcurrencyController(
         initialConcurrency: initialConcurrency,
         maxConcurrency: maxConcurrency,
       );

  int get currentConcurrency => _concurrencyController.currentConcurrency;

  RangeConcurrencySnapshot get concurrencySnapshot => RangeConcurrencySnapshot(
    _activeRangeTransfers.length,
    maxConcurrency,
  );

  Stream<RangeConcurrencySnapshot> get concurrencyChanges =>
      _concurrencyChanges.stream;

  void requestMoreConcurrency() => _concurrencyController.requestMoreCapacity();

  void recordTransferSuccess(RangeChunk chunk) =>
      _concurrencyController.recordSuccess(chunk);

  void recordTransferFailure(Object error) =>
      _concurrencyController.recordFailure(error);

  int? beginRangeTransfer() {
    if (trackType != ProxyTrackType.video || isClosed) return null;
    final transferId = ++_nextTransferId;
    _activeRangeTransfers.add(transferId);
    _publishConcurrencySnapshot();
    return transferId;
  }

  void endRangeTransfer(int? transferId) {
    if (transferId == null || !_activeRangeTransfers.remove(transferId)) {
      return;
    }
    _publishConcurrencySnapshot();
  }

  bool get hasVerifiedUpstreams => _verifiedUpstreams != null;

  Iterable<Uri> get upstreamsByPreference sync* {
    final candidates = _verifiedUpstreams ?? upstreams;
    for (var offset = 0; offset < candidates.length; offset += 1) {
      yield candidates[(_preferredUpstreamIndex + offset) % candidates.length];
    }
  }

  void markSuccess(Uri upstream) {
    final index = (_verifiedUpstreams ?? upstreams).indexOf(upstream);
    if (index >= 0) _preferredUpstreamIndex = index;
  }

  void installVerifiedUpstreams(
    List<Uri> verified,
    int? total,
    int requestGeneration,
  ) {
    throwIfStale(requestGeneration);
    _verifiedUpstreams = List.unmodifiable(verified);
    _preferredUpstreamIndex = 0;
    if (total != null) expectedTotal ??= total;
  }

  void throwIfStale(int requestGeneration) {
    if (isClosed || requestGeneration != generation) {
      throw StateError('stale proxy generation');
    }
  }

  HttpClient openClient(int requestGeneration) {
    throwIfStale(requestGeneration);
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
    generation += 1;
    _intentionalCancellation = true;
    identityFuture = null;
    identityGeneration = null;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    if (_activeRangeTransfers.isNotEmpty) {
      _activeRangeTransfers.clear();
      _publishConcurrencySnapshot();
    }
  }

  void close() {
    if (isClosed) return;
    isClosed = true;
    cancelActiveTransfers();
    unawaited(_concurrencyChanges.close());
  }

  void _publishConcurrencySnapshot() {
    if (!_concurrencyChanges.isClosed) {
      _concurrencyChanges.add(concurrencySnapshot);
    }
  }

  int _nextTransferId = 0;

  void notifyFailure(Object error, int requestGeneration) {
    if (isClosed ||
        requestGeneration != generation ||
        _intentionalCancellation ||
        _failureNotified) {
      return;
    }
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

final class _ResourceIdentity {
  final Uri upstream;
  final int total;
  final Digest digest;

  const _ResourceIdentity({
    required this.upstream,
    required this.total,
    required this.digest,
  });
}

final class _IdentityOutcome {
  final _ResourceIdentity? identity;
  final Object? error;
  final StackTrace? stackTrace;

  const _IdentityOutcome.success(this.identity)
    : error = null,
      stackTrace = null;

  const _IdentityOutcome.failure(this.error, this.stackTrace) : identity = null;
}

final class _AsyncSemaphore {
  final int limit;
  final List<Completer<void>> _highPriorityWaiters = [];
  final List<Completer<void>> _normalWaiters = [];
  int _active = 0;

  _AsyncSemaphore(this.limit);

  Future<void> acquire({bool highPriority = false}) {
    if (_active < limit) {
      _active += 1;
      return Future.value();
    }
    final waiter = Completer<void>();
    (highPriority ? _highPriorityWaiters : _normalWaiters).add(waiter);
    return waiter.future;
  }

  void release() {
    if (_highPriorityWaiters.isNotEmpty) {
      _highPriorityWaiters.removeAt(0).complete();
      return;
    }
    if (_normalWaiters.isNotEmpty) {
      _normalWaiters.removeAt(0).complete();
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
