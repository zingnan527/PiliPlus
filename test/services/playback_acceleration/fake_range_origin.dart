// ignore_for_file: prefer_initializing_formals, unnecessary_underscores

import 'dart:async';
import 'dart:io';

/// Response behaviours exposed by [FakeRangeOrigin].
///
/// The class is intentionally a const-value type instead of an enum.  This
/// keeps the fixture source-compatible with tests that use either the short
/// names (for example, [ok]) or the more descriptive names (for example,
/// [correct206]).  [FakeRangeMode] is an alias for this type.
final class FakeRangeOriginMode {
  final String name;
  final int index;

  const FakeRangeOriginMode._(this.name, this.index);

  static const correct206 = FakeRangeOriginMode._('correct206', 0);
  static const forbidden403 = FakeRangeOriginMode._('forbidden403', 1);
  static const timeout = FakeRangeOriginMode._('timeout', 2);
  static const connectionInterruption = FakeRangeOriginMode._(
    'connectionInterruption',
    3,
  );
  static const ignoreRange200 = FakeRangeOriginMode._('ignoreRange200', 4);
  static const wrongContentRange = FakeRangeOriginMode._(
    'wrongContentRange',
    5,
  );
  static const shortBody = FakeRangeOriginMode._('shortBody', 6);
  static const longBody = FakeRangeOriginMode._('longBody', 7);
  static const candidateTotalMismatch = FakeRangeOriginMode._(
    'candidateTotalMismatch',
    8,
  );
  static const slowFirstByte = FakeRangeOriginMode._('slowFirstByte', 9);
  static const slowHeader = FakeRangeOriginMode._('slowHeader', 10);
  static const tailStall = FakeRangeOriginMode._('tailStall', 11);

  // Common short spellings.  They intentionally point at the canonical value
  // so equality and URI generation remain deterministic.
  static const ok = correct206;
  static const normal = correct206;
  static const success = correct206;
  static const valid = correct206;
  static const partial = correct206;
  static const forbidden = forbidden403;
  static const deny = forbidden403;
  static const status403 = forbidden403;
  static const interrupt = connectionInterruption;
  static const interrupted = connectionInterruption;
  static const connectionInterrupted = connectionInterruption;
  static const ignoreRange = ignoreRange200;
  static const fullResponse = ignoreRange200;
  static const badContentRange = wrongContentRange;
  static const wrongRange = wrongContentRange;
  static const bodyShort = shortBody;
  static const bodyLong = longBody;
  static const totalMismatch = candidateTotalMismatch;
  static const candidateTotal = candidateTotalMismatch;
  static const slow = slowFirstByte;
  static const headerSlow = slowHeader;
  static const stall = tailStall;
  static const stallTail = tailStall;

  static const values = <FakeRangeOriginMode>[
    correct206,
    forbidden403,
    timeout,
    connectionInterruption,
    ignoreRange200,
    wrongContentRange,
    shortBody,
    longBody,
    candidateTotalMismatch,
    slowFirstByte,
    slowHeader,
    tailStall,
  ];

  @override
  bool operator ==(Object other) {
    return other is FakeRangeOriginMode && other.name == name;
  }

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

typedef FakeRangeMode = FakeRangeOriginMode;
typedef RangeOriginMode = FakeRangeOriginMode;
typedef RangeMode = FakeRangeOriginMode;

/// A single Range header observed by the fixture.
///
/// [raw] is the value sent by the client.  [start] and [end] are the
/// effective, inclusive byte offsets used for a valid single-byte-range
/// request.  A request without a Range header is recorded with null offsets.
final class FakeRangeRequest {
  final String? raw;
  final int? start;
  final int? end;

  const FakeRangeRequest({this.raw, this.start, this.end});

  String? get header => raw;
  int? get first => start;
  int? get last => end;
  int? get length {
    final first = start;
    final last = end;
    if (first == null || last == null || last < first) return null;
    return last - first + 1;
  }

  bool get hasRange => start != null && end != null;

  @override
  bool operator ==(Object other) {
    if (other is FakeRangeRequest) {
      return other.raw == raw && other.start == start && other.end == end;
    }
    // Comparing to the raw string makes matcher-style assertions such as
    // contains('bytes=0-1023') useful without giving up parsed offsets.
    return other is String && other == raw;
  }

  @override
  int get hashCode => Object.hash(raw, start, end);

  @override
  String toString() => raw ?? '<no range>';
}

typedef RequestedRange = FakeRangeRequest;

final class _ParsedRequest {
  final String target;
  final Map<String, String> headers;

  const _ParsedRequest(this.target, this.headers);
}

final class _EffectiveRange {
  final int start;
  final int end;

  const _EffectiveRange(this.start, this.end);

  int get length => end - start + 1;
}

/// A tiny local HTTP origin for range-probe tests.
///
/// It deliberately uses [ServerSocket] instead of [HttpServer].  Raw HTTP
/// gives the tests deterministic control over a truncated response, a stalled
/// tail, or headers that are never sent.  No package dependency is required;
/// the fixture is suitable for `flutter_test` and ordinary Dart tests.
final class FakeRangeOrigin {
  final ServerSocket _server;
  final String responsePath;
  final List<int> _payload;
  final Duration _timeoutDelay;
  final Duration _slowFirstByteDelay;
  final Duration _slowHeaderDelay;
  final Duration _tailStallDelay;
  final int _shortBodyDelta;
  final int _longBodyDelta;
  final int _wrongRangeStartDelta;
  final int _wrongRangeEndDelta;
  final int _wrongRangeTotalDelta;
  final int? _candidateTotal;
  final int _candidateTotalDelta;
  final int _interruptAfterBytes;
  final int? _shortBodyLength;
  final int? _longBodyLength;
  final int? _tailBytes;

  final Set<Socket> _sockets = <Socket>{};
  final Map<Socket, StreamSubscription<List<int>>> _subscriptions =
      <Socket, StreamSubscription<List<int>>>{};
  final Completer<void> _closeSignal = Completer<void>();
  final List<FakeRangeRequest> _requestedRanges = <FakeRangeRequest>[];

  bool _closed = false;
  int _active = 0;
  int _maxActive = 0;

  FakeRangeOrigin._(
    this._server, {
    required this.responsePath,
    required List<int> payload,
    required Duration timeoutDelay,
    required Duration slowFirstByteDelay,
    required Duration slowHeaderDelay,
    required Duration tailStallDelay,
    required int shortBodyDelta,
    required int longBodyDelta,
    required int wrongRangeStartDelta,
    required int wrongRangeEndDelta,
    required int wrongRangeTotalDelta,
    required int? candidateTotal,
    required int candidateTotalDelta,
    required int interruptAfterBytes,
    required int? shortBodyLength,
    required int? longBodyLength,
    required int? tailBytes,
  }) : _payload = List<int>.unmodifiable(payload),
       _timeoutDelay = timeoutDelay,
       _slowFirstByteDelay = slowFirstByteDelay,
       _slowHeaderDelay = slowHeaderDelay,
       _tailStallDelay = tailStallDelay,
       _shortBodyDelta = shortBodyDelta,
       _longBodyDelta = longBodyDelta,
       _wrongRangeStartDelta = wrongRangeStartDelta,
       _wrongRangeEndDelta = wrongRangeEndDelta,
       _wrongRangeTotalDelta = wrongRangeTotalDelta,
       _candidateTotal = candidateTotal,
       _candidateTotalDelta = candidateTotalDelta,
       _interruptAfterBytes = interruptAfterBytes,
       _shortBodyLength = shortBodyLength,
       _longBodyLength = longBodyLength,
       _tailBytes = tailBytes {
    _server.listen(_accept, onError: (_) {});
  }

  /// Starts on IPv4 loopback and asks the OS for a free port by default.
  static Future<FakeRangeOrigin> start({
    List<int>? payload,
    int payloadLength = 32 * 1024,
    int? payloadSize,
    String path = '/test/media',
    String? resourcePath,
    int port = 0,
    Duration timeoutDelay = const Duration(seconds: 30),
    Duration? timeoutDuration,
    Duration slowFirstByteDelay = const Duration(milliseconds: 250),
    Duration slowHeaderDelay = const Duration(milliseconds: 250),
    Duration? slowDelay,
    Duration? firstByteDelay,
    Duration? headerDelay,
    Duration tailStallDelay = const Duration(milliseconds: 250),
    Duration? stallDuration,
    int shortBodyDelta = 1,
    int longBodyDelta = 1,
    int? wrongBodyLengthDelta,
    int? shortBodyBytes,
    int? longBodyBytes,
    int? shortBodyLength,
    int? longBodyLength,
    int wrongRangeStartDelta = 1,
    int wrongRangeEndDelta = 1,
    int wrongRangeTotalDelta = 1,
    int? candidateTotal,
    int candidateTotalDelta = 1,
    int interruptAfterBytes = 1,
    int? interruptAfter,
    int? tailBytes,
  }) async {
    final requestedLength = payload?.length ?? payloadSize ?? payloadLength;
    if (requestedLength <= 0 && payload == null) {
      throw ArgumentError.value(requestedLength, 'payloadLength');
    }
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(port, 'port');
    }

    final bytes = payload == null
        ? List<int>.generate(
            requestedLength,
            (index) => index & 0xff,
            growable: false,
          )
        : List<int>.from(payload, growable: false);
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes.length, 'payload');
    }

    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    final effectiveSlowDelay = slowDelay;
    final effectiveStallDelay = stallDuration ?? tailStallDelay;
    final effectiveShortDelta = wrongBodyLengthDelta ?? shortBodyDelta;
    final effectiveLongDelta = wrongBodyLengthDelta ?? longBodyDelta;
    return FakeRangeOrigin._(
      server,
      responsePath: resourcePath ?? path,
      payload: bytes,
      timeoutDelay: timeoutDuration ?? timeoutDelay,
      slowFirstByteDelay:
          firstByteDelay ?? effectiveSlowDelay ?? slowFirstByteDelay,
      slowHeaderDelay: headerDelay ?? effectiveSlowDelay ?? slowHeaderDelay,
      tailStallDelay: effectiveStallDelay,
      shortBodyDelta: effectiveShortDelta,
      longBodyDelta: effectiveLongDelta,
      wrongRangeStartDelta: wrongRangeStartDelta,
      wrongRangeEndDelta: wrongRangeEndDelta,
      wrongRangeTotalDelta: wrongRangeTotalDelta,
      candidateTotal: candidateTotal,
      candidateTotalDelta: candidateTotalDelta,
      interruptAfterBytes: interruptAfter ?? interruptAfterBytes,
      shortBodyLength: shortBodyLength ?? shortBodyBytes,
      longBodyLength: longBodyLength ?? longBodyBytes,
      tailBytes: tailBytes,
    );
  }

  InternetAddress get address => _server.address;
  String get host => _server.address.address;
  int get port => _server.port;
  Uri get originUri => Uri(scheme: 'http', host: host, port: port);
  Uri get baseUri => originUri;
  Uri get origin => originUri;
  Uri get url => originUri.replace(path: responsePath);
  String get path => responsePath;
  String get resource => responsePath;

  List<int> get payload => _payload;
  List<int> get payloadBytes => _payload;
  int get payloadLength => _payload.length;
  int get totalLength => _payload.length;

  int get active => _active;
  int get activeRequests => _active;
  int get maxActive => _maxActive;
  int get maxActiveRequests => _maxActive;
  List<FakeRangeRequest> get requestedRanges => _requestedRanges;
  List<FakeRangeRequest> get ranges => _requestedRanges;
  List<FakeRangeRequest> get requests => _requestedRanges;
  List<String> get requestedRangeHeaders => [
    for (final request in _requestedRanges)
      if (request.raw != null) request.raw!,
  ];
  bool get isClosed => _closed;

  /// Builds a URL for the single resource path.  The mode is encoded as a
  /// query parameter for easy inspection, but query data is never recorded in
  /// [requestedRanges].
  Uri uriFor(Object mode) {
    final token = _modeName(mode);
    return url.replace(queryParameters: <String, String>{'mode': token});
  }

  void clearMetrics() {
    _requestedRanges.clear();
    _maxActive = _active;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_closeSignal.isCompleted) _closeSignal.complete();
    await _server.close();
    final sockets = List<Socket>.of(_sockets);
    for (final socket in sockets) {
      _destroy(socket);
    }
    final subscriptions = List<StreamSubscription<List<int>>>.of(
      _subscriptions.values,
    );
    await Future.wait<void>([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);
  }

  void _accept(Socket socket) {
    if (_closed) {
      _destroy(socket);
      return;
    }
    _sockets.add(socket);
    final bytes = <int>[];
    var handled = false;
    late StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (chunk) {
        if (handled || _closed) return;
        bytes.addAll(chunk);
        final end = _headerEnd(bytes);
        if (end < 0) {
          if (bytes.length > 64 * 1024) {
            handled = true;
            unawaited(
              _sendSimple(socket, 431, 'Request Header Fields Too Large'),
            );
          }
          return;
        }
        handled = true;
        subscription.pause();
        final request = _parseRequest(bytes.sublist(0, end));
        unawaited(
          _serve(socket, request).whenComplete(() async {
            await subscription.cancel();
            _subscriptions.remove(socket);
            _sockets.remove(socket);
            if (!_closed) _destroy(socket);
          }),
        );
      },
      onError: (_, __) {
        _sockets.remove(socket);
        _subscriptions.remove(socket);
      },
      onDone: () {
        _sockets.remove(socket);
        _subscriptions.remove(socket);
      },
      cancelOnError: true,
    );
    _subscriptions[socket] = subscription;
  }

  Future<void> _serve(Socket socket, _ParsedRequest? request) async {
    if (request == null) {
      await _sendSimple(socket, 400, 'Bad Request');
      return;
    }
    final uri = Uri.tryParse(request.target);
    if (uri == null || uri.path != responsePath) {
      await _sendSimple(socket, 404, 'Not Found');
      return;
    }
    final rawRange = request.headers['range'];
    final range = _parseRange(rawRange);
    _requestedRanges.add(
      FakeRangeRequest(raw: rawRange, start: range?.start, end: range?.end),
    );
    _active += 1;
    if (_active > _maxActive) _maxActive = _active;
    try {
      final mode = _canonicalMode(
        uri.queryParameters['mode'] ?? uri.queryParameters['scenario'],
      );
      await _serveMode(socket, mode, range);
    } finally {
      _active -= 1;
    }
  }

  Future<void> _serveMode(
    Socket socket,
    String mode,
    _EffectiveRange? range,
  ) async {
    if (mode == 'forbidden403') {
      await _sendSimple(socket, 403, 'Forbidden');
      return;
    }
    if (mode == 'timeout') {
      // The delay is useful when a test wants a bounded fixture lifetime; the
      // response itself remains pending until the origin is closed.
      await _wait(_timeoutDelay);
      if (!_closed) await _closeSignal.future;
      return;
    }

    if (range == null && mode != 'ignoreRange200') {
      await _sendSimple(socket, 416, 'Range Required', <String>[
        'Content-Range: bytes */${_payload.length}',
      ]);
      return;
    }

    if (mode == 'ignoreRange200') {
      final body = List<int>.of(_payload);
      await _writeResponse(
        socket,
        status: 200,
        body: body,
        contentRange: null,
      );
      return;
    }

    final effectiveRange = range!;
    final expectedBodyLength = effectiveRange.length;
    final normalBody = _bytesForRange(effectiveRange.start, expectedBodyLength);
    final normalContentRange =
        'bytes ${effectiveRange.start}-${effectiveRange.end}/${_payload.length}';

    if (mode == 'connectionInterruption') {
      final count = _interruptAfterBytes.clamp(0, normalBody.length);
      final prefix = normalBody.sublist(0, count);
      await _writeHeaders(
        socket,
        status: 206,
        contentLength: normalBody.length,
        contentRange: normalContentRange,
      );
      if (prefix.isNotEmpty) {
        try {
          socket.add(prefix);
          await socket.flush();
        } catch (_) {
          return;
        }
      }
      _destroy(socket);
      return;
    }

    if (mode == 'tailStall') {
      final count = (_tailBytes ?? (normalBody.length ~/ 2)).clamp(
        0,
        normalBody.length,
      );
      await _writeHeaders(
        socket,
        status: 206,
        contentLength: normalBody.length,
        contentRange: normalContentRange,
      );
      if (count > 0) {
        try {
          socket.add(normalBody.sublist(0, count));
          await socket.flush();
        } catch (_) {
          return;
        }
      }
      await _wait(_tailStallDelay);
      if (!_closed) await _closeSignal.future;
      return;
    }

    final body = switch (mode) {
      'shortBody' => _bodyWithLength(
        effectiveRange.start,
        _shortBodyLength ??
            (expectedBodyLength - _shortBodyDelta).clamp(0, 1 << 30),
      ),
      'longBody' => _bodyWithLength(
        effectiveRange.start,
        _longBodyLength ?? expectedBodyLength + _longBodyDelta,
      ),
      _ => normalBody,
    };
    final total = mode == 'candidateTotalMismatch'
        ? (_candidateTotal ?? _payload.length + _candidateTotalDelta)
        : _payload.length;
    final contentRange = mode == 'wrongContentRange'
        ? 'bytes ${effectiveRange.start + _wrongRangeStartDelta}-'
              '${effectiveRange.end + _wrongRangeEndDelta}/'
              '${_payload.length + _wrongRangeTotalDelta}'
        : 'bytes ${effectiveRange.start}-${effectiveRange.end}/$total';

    if (mode == 'slowHeader') {
      if (!await _wait(_slowHeaderDelay)) return;
    }
    if (mode == 'slowFirstByte') {
      final sent = await _writeHeaders(
        socket,
        status: 206,
        contentLength: body.length,
        contentRange: contentRange,
      );
      if (!sent || !await _wait(_slowFirstByteDelay)) return;
      await _writeBody(socket, body);
      return;
    }
    await _writeResponse(
      socket,
      status: 206,
      body: body,
      contentRange: contentRange,
    );
  }

  Future<bool> _writeResponse(
    Socket socket, {
    required int status,
    required List<int> body,
    required String? contentRange,
  }) async {
    final sent = await _writeHeaders(
      socket,
      status: status,
      contentLength: body.length,
      contentRange: contentRange,
    );
    if (!sent) return false;
    return _writeBody(socket, body);
  }

  Future<bool> _writeHeaders(
    Socket socket, {
    required int status,
    required int contentLength,
    required String? contentRange,
  }) async {
    if (!_canWrite(socket)) return false;
    final lines = <String>[
      'HTTP/1.1 $status ${_reasonPhrase(status)}',
      'Content-Type: application/octet-stream',
      'Content-Length: $contentLength',
      'Accept-Ranges: bytes',
      if (contentRange != null) 'Content-Range: $contentRange',
      'Connection: close',
      '',
      '',
    ];
    try {
      socket.add(lines.join('\r\n').codeUnits);
      await socket.flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _writeBody(Socket socket, List<int> body) async {
    if (!_canWrite(socket)) return false;
    try {
      if (body.isNotEmpty) socket.add(body);
      await socket.flush();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sendSimple(
    Socket socket,
    int status,
    String message, [
    List<String> extraHeaders = const <String>[],
  ]) async {
    if (!_canWrite(socket)) return;
    final body = message.codeUnits;
    final lines = <String>[
      'HTTP/1.1 $status ${_reasonPhrase(status)}',
      'Content-Type: text/plain; charset=utf-8',
      'Content-Length: ${body.length}',
      ...extraHeaders,
      'Connection: close',
      '',
      '',
    ];
    try {
      socket.add(lines.join('\r\n').codeUnits);
      if (body.isNotEmpty) socket.add(body);
      await socket.flush();
    } catch (_) {
      // The client may intentionally close the socket while probing.
    }
  }

  bool _canWrite(Socket socket) => !_closed && _sockets.contains(socket);

  Future<bool> _wait(Duration duration) async {
    if (_closed) return false;
    if (duration <= Duration.zero) return true;
    return Future.any<bool>(<Future<bool>>[
      Future<bool>.delayed(duration, () => true),
      _closeSignal.future.then((_) => false),
    ]);
  }

  _EffectiveRange? _parseRange(String? header) {
    if (header == null) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty && endText.isEmpty) return null;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      final start = suffix >= _payload.length ? 0 : _payload.length - suffix;
      return _EffectiveRange(start, _payload.length - 1);
    }
    final start = int.tryParse(startText);
    if (start == null || start < 0 || start >= _payload.length) return null;
    var end = endText.isEmpty ? _payload.length - 1 : int.tryParse(endText);
    if (end == null || end < start) return null;
    if (end >= _payload.length) end = _payload.length - 1;
    return _EffectiveRange(start, end);
  }

  List<int> _bytesForRange(int start, int length) {
    return List<int>.generate(length, (offset) => _byteAt(start + offset));
  }

  List<int> _bodyWithLength(int start, int length) {
    final safeLength = length < 0 ? 0 : length;
    return _bytesForRange(start, safeLength);
  }

  int _byteAt(int offset) => _payload[offset % _payload.length];

  static _ParsedRequest? _parseRequest(List<int> bytes) {
    final text = String.fromCharCodes(bytes);
    final lines = text.split('\r\n');
    if (lines.isEmpty) return null;
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2 || requestLine[1].isEmpty) return null;
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.isEmpty) break;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      headers[line.substring(0, colon).trim().toLowerCase()] = line
          .substring(colon + 1)
          .trim();
    }
    return _ParsedRequest(requestLine[1], headers);
  }

  static int _headerEnd(List<int> bytes) {
    for (var index = 3; index < bytes.length; index += 1) {
      if (bytes[index - 3] == 13 &&
          bytes[index - 2] == 10 &&
          bytes[index - 1] == 13 &&
          bytes[index] == 10) {
        return index - 3;
      }
    }
    return -1;
  }

  static String _modeName(Object? mode) {
    if (mode == null) return 'correct206';
    if (mode is FakeRangeOriginMode) return mode.name;
    if (mode is Enum) return mode.name;
    final text = mode.toString();
    final dot = text.lastIndexOf('.');
    return dot < 0 ? text : text.substring(dot + 1);
  }

  static String _canonicalMode(Object? mode) {
    final normalized = _modeName(mode)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return switch (normalized) {
      'correct206' ||
      'correct' ||
      'ok' ||
      'normal' ||
      'success' ||
      'valid' ||
      'partial' => 'correct206',
      'forbidden403' || 'forbidden' || 'deny' || 'status403' => 'forbidden403',
      'timeout' || 'timedout' => 'timeout',
      'connectioninterruption' ||
      'connectioninterrupted' ||
      'connectioninterrupt' ||
      'interrupt' ||
      'interrupted' => 'connectionInterruption',
      'ignorerange200' ||
      'ignorerange' ||
      'fullresponse' ||
      'ignore' => 'ignoreRange200',
      'wrongcontentrange' ||
      'badcontentrange' ||
      'wrongrange' => 'wrongContentRange',
      'shortbody' || 'bodyshort' || 'short' => 'shortBody',
      'longbody' || 'bodylong' || 'long' => 'longBody',
      'candidatetotalmismatch' ||
      'totalmismatch' ||
      'candidatetotal' => 'candidateTotalMismatch',
      'slowfirstbyte' || 'slowttfb' || 'slow' => 'slowFirstByte',
      'slowheader' || 'headerslow' => 'slowHeader',
      'tailstall' || 'stalltail' || 'stall' => 'tailStall',
      _ => 'correct206',
    };
  }

  static String _reasonPhrase(int status) {
    return switch (status) {
      200 => 'OK',
      206 => 'Partial Content',
      400 => 'Bad Request',
      403 => 'Forbidden',
      404 => 'Not Found',
      416 => 'Range Not Satisfiable',
      431 => 'Request Header Fields Too Large',
      _ => 'Error',
    };
  }

  static void _destroy(Socket socket) {
    try {
      socket.destroy();
    } catch (_) {
      // Closing an already closed probe socket is harmless.
    }
  }
}
