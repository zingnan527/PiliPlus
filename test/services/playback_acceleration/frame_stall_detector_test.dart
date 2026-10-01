import 'package:PiliPlus/services/playback_acceleration/frame_stall_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects video freeze only after video has previously advanced', () {
    final detector = FrameStallDetector();
    bool sample(int wall, int audio, int video) => detector.sample(
      wallTime: Duration(seconds: wall),
      audioTime: Duration(seconds: audio),
      videoTime: Duration(seconds: video),
    );

    expect(sample(0, 0, 0), isFalse);
    expect(sample(5, 5, 0), isFalse); // Startup is not a frame freeze.
    expect(sample(6, 6, 1), isFalse);
    expect(sample(7, 7, 2), isFalse);
    expect(sample(8, 8, 2), isFalse);
    expect(sample(11, 11, 2), isFalse);
    expect(sample(12, 12, 2), isTrue);
    expect(detector.isFrozen, isTrue);
    expect(sample(13, 13, 2), isFalse); // One alert per incident.
    expect(sample(14, 14, 4), isFalse); // Recovery resets the incident.
    expect(detector.isFrozen, isFalse);
    expect(sample(15, 15, 4), isFalse);
    expect(sample(19, 19, 4), isTrue);
  });

  test('pause or seek resets the freeze clock', () {
    final detector = FrameStallDetector();
    detector.sample(
      wallTime: Duration.zero,
      audioTime: Duration.zero,
      videoTime: Duration.zero,
    );
    detector.sample(
      wallTime: const Duration(seconds: 1),
      audioTime: const Duration(seconds: 1),
      videoTime: const Duration(seconds: 1),
    );
    expect(
      detector.sample(
        wallTime: const Duration(seconds: 3),
        audioTime: const Duration(seconds: 3),
        videoTime: const Duration(seconds: 1),
      ),
      isFalse,
    );
    detector.reset();
    expect(
      detector.sample(
        wallTime: const Duration(seconds: 10),
        audioTime: const Duration(seconds: 10),
        videoTime: const Duration(seconds: 10),
      ),
      isFalse,
    );
    expect(
      detector.sample(
        wallTime: const Duration(seconds: 15),
        audioTime: const Duration(seconds: 15),
        videoTime: const Duration(seconds: 10),
      ),
      isFalse,
    );
  });
}
