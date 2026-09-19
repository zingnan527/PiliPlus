import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/playback_acceleration/byte_range.dart';

final class RangeFetchException implements Exception {
  final String reason;

  const RangeFetchException(this.reason);

  @override
  String toString() => 'RangeFetchException($reason)';
}

final class RangeChunk {
  final ByteRange range;
  final int total;
  final List<int> bytes;
  final Duration ttfb;
  final Duration elapsed;

  const RangeChunk({
    required this.range,
    required this.total,
    required this.bytes,
    required this.ttfb,
    required this.elapsed,
  });
}

/// Fetches one upstream range and validates it before exposing any bytes.
final class StrictRangeFetcher {
  final Duration responseTimeout;
  final Duration bodyStallTimeout;
  final Duration totalTimeout;

  const StrictRangeFetcher({
    this.responseTimeout = const Duration(seconds: 6),
    this.bodyStallTimeout = const Duration(seconds: 4),
    this.totalTimeout = const Duration(seconds: 15),
  });

  Future<RangeChunk> fetch(
    HttpClient client,
    Uri upstream,
    ByteRange range, {
    int? expectedTotal,
    Map<String, String> headers = const {},
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final request = await client.getUrl(upstream).timeout(responseTimeout);
      request.headers.set(HttpHeaders.rangeHeader, range.toString());
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close().timeout(responseTimeout);
      final ttfb = stopwatch.elapsed;
      if (response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        throw RangeFetchException('expected 206, got ${response.statusCode}');
      }
      final rawContentRange = response.headers.value(
        HttpHeaders.contentRangeHeader,
      );
      if (rawContentRange == null) {
        await response.drain<void>();
        throw const RangeFetchException('missing Content-Range');
      }
      final contentRange = ContentByteRange.parse(rawContentRange);
      if (contentRange.range != range) {
        await response.drain<void>();
        throw const RangeFetchException('Content-Range mismatch');
      }
      if (expectedTotal != null && contentRange.total != expectedTotal) {
        await response.drain<void>();
        throw const RangeFetchException('resource total mismatch');
      }
      final declaredLength = response.contentLength;
      if (declaredLength >= 0 && declaredLength != range.length) {
        await response.drain<void>();
        throw const RangeFetchException('Content-Length mismatch');
      }
      final bytes = await _readBody(response, range.length);
      if (bytes.length != range.length) {
        throw const RangeFetchException('body length mismatch');
      }
      stopwatch.stop();
      return RangeChunk(
        range: range,
        total: contentRange.total,
        bytes: List.unmodifiable(bytes),
        ttfb: ttfb,
        elapsed: stopwatch.elapsed,
      );
    } on RangeFetchException {
      rethrow;
    } on TimeoutException {
      throw const RangeFetchException('timeout');
    } on FormatException {
      throw const RangeFetchException('invalid Content-Range');
    } on HttpException {
      throw const RangeFetchException('HTTP transport failure');
    } on SocketException {
      throw const RangeFetchException('socket failure');
    }
  }

  Future<List<int>> _readBody(HttpClientResponse response, int limit) {
    final completer = Completer<List<int>>();
    final bytes = <int>[];
    Timer? stallTimer;
    Timer? totalTimer;
    late StreamSubscription<List<int>> subscription;

    void finishError(Object error) {
      if (completer.isCompleted) return;
      completer.completeError(error);
      unawaited(subscription.cancel());
    }

    void armStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(
        bodyStallTimeout,
        () => finishError(const RangeFetchException('body stalled')),
      );
    }

    subscription = response.listen(
      (chunk) {
        armStallTimer();
        bytes.addAll(chunk);
        if (bytes.length > limit) {
          finishError(const RangeFetchException('body exceeds range'));
        }
      },
      onError: finishError,
      onDone: () {
        if (!completer.isCompleted) completer.complete(bytes);
      },
      cancelOnError: true,
    );
    armStallTimer();
    totalTimer = Timer(
      totalTimeout,
      () => finishError(const RangeFetchException('body total timeout')),
    );
    return completer.future.whenComplete(() {
      stallTimer?.cancel();
      totalTimer?.cancel();
    });
  }
}
