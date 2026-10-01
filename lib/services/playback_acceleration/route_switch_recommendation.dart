import 'package:PiliPlus/models/common/video/cdn_switch_mode.dart';
import 'package:PiliPlus/services/playback_acceleration/route_probe_service.dart';

enum CdnSwitchAction { none, suggest, switchAutomatically }

CdnSwitchAction chooseCdnSwitchAction(
  CdnSwitchMode mode,
  CdnSwitchRecommendation? recommendation,
) {
  if (recommendation == null || !recommendation.isMeaningfulImprovement) {
    return CdnSwitchAction.none;
  }
  return switch (mode) {
    CdnSwitchMode.off => CdnSwitchAction.none,
    CdnSwitchMode.manual => CdnSwitchAction.suggest,
    CdnSwitchMode.automatic => CdnSwitchAction.switchAutomatically,
  };
}

final class CdnSwitchRecommendation {
  final String currentUrl;
  final String targetUrl;
  final RouteProbeSample? currentSample;
  final RouteProbeSample targetSample;

  const CdnSwitchRecommendation({
    required this.currentUrl,
    required this.targetUrl,
    required this.currentSample,
    required this.targetSample,
  });

  int? get improvementPercent {
    final currentSpeed = currentSample?.bytesPerSecond;
    if (currentSpeed == null || currentSpeed <= 0 || !currentSpeed.isFinite) {
      return null;
    }
    return ((targetSample.bytesPerSecond / currentSpeed - 1) * 100).round();
  }

  /// Avoids switching routes for measurement noise or negligible gains.
  /// A failed current probe still permits recovery to a working candidate.
  bool get isMeaningfulImprovement {
    final improvement = improvementPercent;
    return improvement == null || improvement >= 20;
  }

  static CdnSwitchRecommendation? fromProbeResults({
    required String currentUrl,
    required List<RouteProbeResult<String>> results,
  }) {
    RouteProbeResult<String>? best;
    RouteProbeSample? currentSample;
    for (final result in results) {
      if (result.candidate == currentUrl) currentSample = result.sample;
      final sample = result.sample;
      final bestSample = best?.sample;
      if (sample != null &&
          (bestSample == null ||
              sample.bytesPerSecond > bestSample.bytesPerSecond ||
              (sample.bytesPerSecond == bestSample.bytesPerSecond &&
                  sample.ttfb < bestSample.ttfb))) {
        best = result;
      }
    }
    final targetSample = best?.sample;
    if (best == null || targetSample == null || best.candidate == currentUrl) {
      return null;
    }
    return CdnSwitchRecommendation(
      currentUrl: currentUrl,
      targetUrl: best.candidate,
      currentSample: currentSample,
      targetSample: targetSample,
    );
  }
}

/// Prevents an automatic recovery loop from rapidly exhausting CDN routes.
final class AutomaticCdnSwitchGuard {
  static const cooldown = Duration(seconds: 30);
  static const maxSwitchesPerVideo = 3;

  Duration? _lastSwitchAt;
  int _switchCount = 0;

  bool canSwitch(Duration now) =>
      _switchCount < maxSwitchesPerVideo &&
      (_lastSwitchAt == null || now - _lastSwitchAt! >= cooldown);

  void recordSwitch(Duration now) {
    _lastSwitchAt = now;
    _switchCount += 1;
  }

  void reset() {
    _lastSwitchAt = null;
    _switchCount = 0;
  }
}

Duration chooseResumePosition({
  required Duration? playerPosition,
  Duration? audioPosition,
  required int lastReportedSeconds,
  required Duration? previousResumePosition,
}) {
  if (audioPosition case final position? when position > Duration.zero) {
    return position;
  }
  if (playerPosition case final position? when position > Duration.zero) {
    return position;
  }
  if (lastReportedSeconds > 0) return Duration(seconds: lastReportedSeconds);
  return previousResumePosition ?? Duration.zero;
}
