import 'dart:async';

import 'package:PiliPlus/services/playback_acceleration/route_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RouteProbeService', () {
    test('never exceeds the configured concurrency bound', () async {
      var active = 0;
      var maxActive = 0;
      final gate = Completer<void>();
      final service = RouteProbeService<int>(
        maxConcurrency: 3,
        probe: (candidate, cancellation) async {
          active += 1;
          maxActive = active > maxActive ? active : maxActive;
          await gate.future;
          active -= 1;
          return RouteProbeSample(
            bytes: candidate * 1024,
            ttfb: const Duration(milliseconds: 10),
            elapsed: const Duration(milliseconds: 20),
          );
        },
      );

      final pending = service.probeAll(List.generate(10, (index) => index + 1));
      await Future<void>.delayed(Duration.zero);

      expect(maxActive, 3);
      gate.complete();
      final results = await pending;
      expect(results, hasLength(10));
      expect(results.every((result) => result.isSuccess), isTrue);
      expect(maxActive, 3);
    });

    test('cancellation prevents queued candidates from starting', () async {
      final cancellation = ProbeCancellation();
      final started = <int>[];
      final firstWave = Completer<void>();
      final service = RouteProbeService<int>(
        maxConcurrency: 2,
        probe: (candidate, token) async {
          started.add(candidate);
          await firstWave.future;
          token.throwIfCancelled();
          return const RouteProbeSample(
            bytes: 1024,
            ttfb: Duration(milliseconds: 5),
            elapsed: Duration(milliseconds: 10),
          );
        },
      );

      final pending = service.probeAll(
        List.generate(8, (index) => index),
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      firstWave.complete();

      final results = await pending;
      expect(started, hasLength(2));
      expect(results, isEmpty);
    });

    test('ranks successful routes by real sample throughput', () async {
      final service = RouteProbeService<String>(
        maxConcurrency: 2,
        probe: (candidate, cancellation) async {
          return switch (candidate) {
            'slow' => const RouteProbeSample(
              bytes: 1000,
              ttfb: Duration(milliseconds: 5),
              elapsed: Duration(seconds: 1),
            ),
            'fast' => const RouteProbeSample(
              bytes: 4000,
              ttfb: Duration(milliseconds: 20),
              elapsed: Duration(seconds: 1),
            ),
            _ => throw StateError('unavailable'),
          };
        },
      );

      final results = await service.probeAll(['slow', 'failed', 'fast']);
      expect(results.map((result) => result.candidate), [
        'fast',
        'slow',
        'failed',
      ]);
      expect(results.last.isSuccess, isFalse);
    });
  });
}
