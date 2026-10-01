import 'dart:io';

import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp(
      'piliplus-audio-handler-test-',
    );
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'deduplicates same-second playback updates but emits when status changes',
    () async {
      final handler = VideoPlayerServiceHandler();
      addTearDown(handler.clear);
      handler.onVideoDetailChange(
        Part(cid: 1, part: 'test', duration: 60),
        1,
        'test',
      );

      var emissions = 0;
      final subscription = handler.playbackState.listen((_) => emissions++);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      emissions = 0;

      handler
        ..onUpdateState(
          .playing,
          false,
          false,
          position: const Duration(seconds: 12),
          speed: 1,
        )
        ..onUpdateState(
          .playing,
          false,
          false,
          position: const Duration(seconds: 12, milliseconds: 500),
          speed: 1,
        )
        ..onUpdateState(
          .playing,
          false,
          false,
          position: const Duration(seconds: 12, milliseconds: 500),
          speed: 1.25,
        );

      await Future<void>.delayed(Duration.zero);

      expect(emissions, 2);
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 12, milliseconds: 500),
      );
    },
  );
}
