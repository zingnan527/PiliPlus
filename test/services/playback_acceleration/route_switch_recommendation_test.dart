import 'package:PiliPlus/models/common/video/cdn_switch_mode.dart';
import 'package:PiliPlus/services/playback_acceleration/route_probe_service.dart';
import 'package:PiliPlus/services/playback_acceleration/route_switch_recommendation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const current = 'https://current.example/video.m4s';
  const faster = 'https://faster.example/video.m4s';

  RouteProbeResult<String> result(
    String candidate, {
    required int bytes,
    required int milliseconds,
    int ttfbMilliseconds = 20,
  }) => RouteProbeResult.success(
    candidate,
    RouteProbeSample(
      bytes: bytes,
      ttfb: Duration(milliseconds: ttfbMilliseconds),
      elapsed: Duration(milliseconds: milliseconds),
    ),
  );

  test('recommends the measured fastest different CDN with improvement', () {
    final recommendation = CdnSwitchRecommendation.fromProbeResults(
      currentUrl: current,
      results: [
        result(current, bytes: 1000, milliseconds: 1000),
        result(faster, bytes: 2500, milliseconds: 1000),
      ],
    );

    expect(recommendation, isNotNull);
    expect(recommendation!.targetUrl, faster);
    expect(recommendation.improvementPercent, 150);
  });

  test('does not suggest a switch when the current CDN is already fastest', () {
    final recommendation = CdnSwitchRecommendation.fromProbeResults(
      currentUrl: current,
      results: [
        result(current, bytes: 3000, milliseconds: 1000),
        result(faster, bytes: 2500, milliseconds: 1000),
      ],
    );

    expect(recommendation, isNull);
  });

  test('can recommend a healthy CDN when the current CDN probe fails', () {
    final recommendation = CdnSwitchRecommendation.fromProbeResults(
      currentUrl: current,
      results: [
        const RouteProbeResult.failure(current, 'timeout'),
        result(faster, bytes: 2500, milliseconds: 1000),
      ],
    );

    expect(recommendation, isNotNull);
    expect(recommendation!.improvementPercent, isNull);
    expect(recommendation.isMeaningfulImprovement, isTrue);
  });

  test('ignores tiny measured improvements that would cause route churn', () {
    final recommendation = CdnSwitchRecommendation.fromProbeResults(
      currentUrl: current,
      results: [
        result(current, bytes: 1000, milliseconds: 1000),
        result(faster, bytes: 1050, milliseconds: 1000),
      ],
    );
    expect(recommendation, isNotNull);
    expect(recommendation!.isMeaningfulImprovement, isFalse);
    expect(
      chooseCdnSwitchAction(CdnSwitchMode.automatic, recommendation),
      CdnSwitchAction.none,
    );
  });

  test('maps the same measured recommendation to the three user modes', () {
    final recommendation = CdnSwitchRecommendation.fromProbeResults(
      currentUrl: current,
      results: [
        result(current, bytes: 1000, milliseconds: 1000),
        result(faster, bytes: 2500, milliseconds: 1000),
      ],
    );
    expect(recommendation, isNotNull);
    expect(
      chooseCdnSwitchAction(CdnSwitchMode.off, recommendation),
      CdnSwitchAction.none,
    );
    expect(
      chooseCdnSwitchAction(CdnSwitchMode.manual, recommendation),
      CdnSwitchAction.suggest,
    );
    expect(
      chooseCdnSwitchAction(CdnSwitchMode.automatic, recommendation),
      CdnSwitchAction.switchAutomatically,
    );
  });

  test(
    'keeps the last positive position when a stalled player reports zero',
    () {
      expect(
        chooseResumePosition(
          playerPosition: Duration.zero,
          lastReportedSeconds: 73,
          previousResumePosition: const Duration(seconds: 71),
        ),
        const Duration(seconds: 73),
      );
    },
  );

  test('uses current position after a backward seek, not an older maximum', () {
    expect(
      chooseResumePosition(
        playerPosition: const Duration(seconds: 24),
        lastReportedSeconds: 23,
        previousResumePosition: const Duration(seconds: 75),
      ),
      const Duration(seconds: 24),
    );
  });

  test('resumes at the audio clock when video frames are frozen', () {
    expect(
      chooseResumePosition(
        playerPosition: const Duration(seconds: 42),
        audioPosition: const Duration(seconds: 49),
        lastReportedSeconds: 42,
        previousResumePosition: const Duration(seconds: 40),
      ),
      const Duration(seconds: 49),
    );
  });

  test('automatic switching has a cooldown and a per-video limit', () {
    final guard = AutomaticCdnSwitchGuard();
    expect(guard.canSwitch(Duration.zero), isTrue);
    guard.recordSwitch(Duration.zero);
    expect(guard.canSwitch(const Duration(seconds: 10)), isFalse);
    expect(guard.canSwitch(const Duration(seconds: 30)), isTrue);
    guard.recordSwitch(const Duration(seconds: 30));
    expect(guard.canSwitch(const Duration(seconds: 60)), isTrue);
    guard.recordSwitch(const Duration(seconds: 60));
    expect(guard.canSwitch(const Duration(minutes: 10)), isFalse);
    guard.reset();
    expect(guard.canSwitch(const Duration(minutes: 10)), isTrue);
  });
}
