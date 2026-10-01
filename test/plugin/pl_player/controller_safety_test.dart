import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/audio_handler.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp(
      'piliplus-player-controller-test-',
    );
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'changing speed before player initialization does not dereference a null player',
    () async {
      videoPlayerServiceHandler = VideoPlayerServiceHandler();
      addTearDown(() => videoPlayerServiceHandler = null);
      final controller = PlPlayerController.getInstance();

      await controller.setPlaybackSpeed(1.25);

      expect(controller.playbackSpeed, 1.25);
    },
  );
}
