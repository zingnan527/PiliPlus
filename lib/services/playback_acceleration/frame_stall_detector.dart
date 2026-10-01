/// Detects audio advancing while an already-playing video's clock is frozen.
/// A stalled startup is deliberately excluded; the video must have advanced
/// at least once before this detector can report a freeze.
final class FrameStallDetector {
  static const freezeThreshold = Duration(seconds: 4);
  static const videoProgressTolerance = Duration(milliseconds: 250);
  static const audioProgressTolerance = Duration(milliseconds: 250);

  Duration? _lastWallTime;
  Duration? _lastAudioTime;
  Duration? _lastVideoTime;
  Duration? _freezeStartedAt;
  bool _videoHasAdvanced = false;
  bool _reported = false;

  bool get isFrozen => _reported;

  bool sample({
    required Duration wallTime,
    required Duration audioTime,
    required Duration videoTime,
  }) {
    final previousWall = _lastWallTime;
    final previousAudio = _lastAudioTime;
    final previousVideo = _lastVideoTime;
    _lastWallTime = wallTime;
    _lastAudioTime = audioTime;
    _lastVideoTime = videoTime;
    if (previousWall == null ||
        previousAudio == null ||
        previousVideo == null) {
      return false;
    }
    if (wallTime <= previousWall ||
        audioTime < previousAudio ||
        videoTime < previousVideo) {
      reset();
      return false;
    }
    if (videoTime - previousVideo >= videoProgressTolerance) {
      _videoHasAdvanced = true;
      _freezeStartedAt = null;
      _reported = false;
      return false;
    }
    if (!_videoHasAdvanced ||
        audioTime - previousAudio < audioProgressTolerance) {
      _freezeStartedAt = null;
      return false;
    }
    _freezeStartedAt ??= wallTime;
    if (!_reported && wallTime - _freezeStartedAt! >= freezeThreshold) {
      _reported = true;
      return true;
    }
    return false;
  }

  void reset() {
    _lastWallTime = null;
    _lastAudioTime = null;
    _lastVideoTime = null;
    _freezeStartedAt = null;
    _videoHasAdvanced = false;
    _reported = false;
  }
}
