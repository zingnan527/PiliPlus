import 'dart:async';

final class ProbeCancelled implements Exception {
  const ProbeCancelled();
}

final class ProbeCancellation {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;

  void throwIfCancelled() {
    if (_isCancelled) throw const ProbeCancelled();
  }
}

final class RouteProbeSample {
  final int bytes;
  final Duration ttfb;
  final Duration elapsed;

  const RouteProbeSample({
    required this.bytes,
    required this.ttfb,
    required this.elapsed,
  }) : assert(bytes >= 0);

  double get bytesPerSecond {
    final micros = elapsed.inMicroseconds;
    if (micros <= 0) return double.infinity;
    return bytes * Duration.microsecondsPerSecond / micros;
  }
}

final class RouteProbeResult<T> {
  final T candidate;
  final RouteProbeSample? sample;
  final Object? error;

  const RouteProbeResult.success(this.candidate, this.sample) : error = null;

  const RouteProbeResult.failure(this.candidate, this.error) : sample = null;

  bool get isSuccess => sample != null;
}

typedef RouteProbe<T> = Future<RouteProbeSample> Function(
  T candidate,
  ProbeCancellation cancellation,
);

/// Runs small cold-start probes without saturating every route at once.
///
/// Probe results are only a health and initial-ordering signal. Sustained
/// playback scheduling must use metrics from real media chunks.
final class RouteProbeService<T> {
  final int maxConcurrency;
  final RouteProbe<T> probe;

  const RouteProbeService({
    required this.probe,
    this.maxConcurrency = 4,
  }) : assert(maxConcurrency > 0);

  Future<List<RouteProbeResult<T>>> probeAll(
    Iterable<T> candidates, {
    ProbeCancellation? cancellation,
  }) async {
    final token = cancellation ?? ProbeCancellation();
    final pending = candidates.toList(growable: false);
    if (pending.isEmpty || token.isCancelled) return const [];

    final results = <RouteProbeResult<T>>[];
    var nextIndex = 0;

    Future<void> worker() async {
      while (!token.isCancelled) {
        if (nextIndex >= pending.length) return;
        final candidate = pending[nextIndex++];
        try {
          token.throwIfCancelled();
          final sample = await probe(candidate, token);
          token.throwIfCancelled();
          results.add(RouteProbeResult<T>.success(candidate, sample));
        } on ProbeCancelled {
          return;
        } catch (error) {
          if (!token.isCancelled) {
            results.add(RouteProbeResult<T>.failure(candidate, error));
          }
        }
      }
    }

    final workerCount = maxConcurrency < pending.length
        ? maxConcurrency
        : pending.length;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    results.sort((left, right) {
      if (left.isSuccess != right.isSuccess) return left.isSuccess ? -1 : 1;
      final leftSample = left.sample;
      final rightSample = right.sample;
      if (leftSample == null || rightSample == null) return 0;
      final throughput = rightSample.bytesPerSecond.compareTo(
        leftSample.bytesPerSecond,
      );
      if (throughput != 0) return throughput;
      return leftSample.ttfb.compareTo(rightSample.ttfb);
    });
    return results;
  }
}
