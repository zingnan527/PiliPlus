import 'dart:async';

import 'package:PiliPlus/services/playback_acceleration/playback_reload_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native reloads cannot complete out of order', () async {
    final queue = PlaybackReloadQueue();
    final oldOpen = Completer<void>();
    final opened = <String>[];
    final oldPending = queue.run(() async {
      opened.add('old-start');
      await oldOpen.future;
      opened.add('old-end');
    });
    final newPending = queue.run(() async => opened.add('new'));
    await Future<void>.delayed(Duration.zero);
    expect(opened, ['old-start']);
    oldOpen.complete();
    await Future.wait([oldPending, newPending]);
    expect(opened, ['old-start', 'old-end', 'new']);
  });

  test('a queued native reload is skipped if it became stale', () async {
    final queue = PlaybackReloadQueue();
    final oldOpen = Completer<void>();
    final opened = <String>[];
    var current = true;
    final oldPending = queue.run(() => oldOpen.future);
    final stalePending = queue.run(
      () async => opened.add('stale'),
      isCurrent: () => current,
    );
    current = false;
    oldOpen.complete();
    await Future.wait([oldPending, stalePending]);
    expect(opened, isEmpty);
  });

  test('a failed native reload does not block the next one', () async {
    final queue = PlaybackReloadQueue();
    final opened = <String>[];
    final failed = queue.run(() async => throw StateError('open failed'));
    final assertion = expectLater(failed, throwsStateError);
    final next = queue.run(() async => opened.add('next'));
    await assertion;
    await next;
    expect(opened, ['next']);
  });

  test('a current fallback reloads after cleanup completes', () async {
    final guard = PlaybackReloadGuard();
    final cleanup = Completer<void>();
    final opened = <String>[];
    final pending = guard.run(
      prepare: () => cleanup.future,
      isPlaybackCurrent: () => true,
      reload: () async => opened.add('current'),
    );

    expect(opened, isEmpty);
    cleanup.complete();
    expect(await pending, isTrue);
    expect(opened, ['current']);
  });

  test(
    'reset during cleanup prevents the old fallback from reopening',
    () async {
      final guard = PlaybackReloadGuard();
      final cleanup = Completer<void>();
      final opened = <String>[];
      final pending = guard.run(
        prepare: () => cleanup.future,
        isPlaybackCurrent: () => true,
        reload: () async => opened.add('old'),
      );

      guard.invalidate();
      cleanup.complete();
      expect(await pending, isFalse);
      expect(opened, isEmpty);
    },
  );

  test('a newer CDN reload is not overwritten by an older fallback', () async {
    final guard = PlaybackReloadGuard();
    final oldCleanup = Completer<void>();
    final opened = <String>[];
    final oldPending = guard.run(
      prepare: () => oldCleanup.future,
      isPlaybackCurrent: () => true,
      reload: () async => opened.add('old'),
    );

    guard.invalidate();
    expect(
      await guard.run(
        prepare: () async {},
        isPlaybackCurrent: () => true,
        reload: () async => opened.add('new'),
      ),
      isTrue,
    );
    oldCleanup.complete();
    expect(await oldPending, isFalse);
    expect(opened, ['new']);
  });

  test('a closed playback never starts fallback reload', () async {
    final guard = PlaybackReloadGuard();
    final opened = <String>[];
    expect(
      await guard.run(
        prepare: () async {},
        isPlaybackCurrent: () => false,
        reload: () async => opened.add('closed'),
      ),
      isFalse,
    );
    expect(opened, isEmpty);
  });
}
