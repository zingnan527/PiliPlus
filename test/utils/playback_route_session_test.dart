// SPDX-License-Identifier: GPL-3.0-only
// Adapted from taresky/PiliPlus japan-cdn commit 5022c1d.

import 'package:PiliPlus/utils/playback_route_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackRouteSession', () {
    const cosov =
        'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/video.m4s?os=cosov&upsig=cos-signature';
    const tfHw =
        'https://upos-tf-all-hw.bilivideo.com/upgcxcode/video.m4s?os=hw&upsig=tf-signature';
    const akamai =
        'https://upos-sz-mirrorakam.akamaized.net/upgcxcode/video.m4s?os=akam&upsig=akam-signature';

    test('uses the server supplied URL for the preferred host', () {
      final session = PlaybackRouteSession(
        videoUrls: const [cosov, tfHw, akamai],
        preferredVideoHost: 'upos-tf-all-hw.bilivideo.com',
      );

      expect(session.videoUrl, tfHw);
      expect(session.videoUrl, contains('upsig=tf-signature'));
    });

    test('tries each video host once and never wraps after exhaustion', () {
      final session = PlaybackRouteSession(
        videoUrls: const [cosov, tfHw, akamai, cosov],
      );

      expect(session.videoUrl, cosov);
      expect(session.nextVideo(), tfHw);
      expect(session.nextVideo(), akamai);
      expect(session.nextVideo(), isNull);
      expect(session.nextVideo(), isNull);
    });

    test('keeps a whitelisted bilivideo override as the first route', () {
      final session = PlaybackRouteSession(
        videoUrls: const [cosov, tfHw],
        preferredVideoHost: 'cn-hk-eq-01-04.bilivideo.com',
        rewriteHostAllowlist: const {'cn-hk-eq-01-04.bilivideo.com'},
      );

      expect(
        Uri.parse(session.videoUrl).host,
        'cn-hk-eq-01-04.bilivideo.com',
      );
      expect(session.nextVideo(), cosov);
      expect(session.nextVideo(), tfHw);
      expect(session.nextVideo(), isNull);
    });

    test('does not rewrite to a host outside the code allowlist', () {
      final session = PlaybackRouteSession(
        videoUrls: const [cosov, tfHw],
        preferredVideoHost: 'custom.example',
      );

      expect(session.videoUrl, cosov);
      expect(session.nextVideo(), tfHw);
      expect(session.nextVideo(), isNull);
    });

    test('fallback order only uses server supplied hosts', () {
      final session = PlaybackRouteSession(
        videoUrls: const [cosov, tfHw, akamai],
        fallbackVideoHostOrder: const [
          'cn-hk-eq-01-04.bilivideo.com',
          'upos-sz-mirrorakam.akamaized.net',
          'upos-tf-all-hw.bilivideo.com',
        ],
      );

      expect(session.videoUrl, cosov);
      expect(session.nextVideo(), akamai);
      expect(session.nextVideo(), tfHw);
      expect(session.nextVideo(), isNull);
    });

    test('advances video and audio candidates independently', () {
      const audioCosov =
          'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/audio.m4s?upsig=audio-cos';
      const audioAli =
          'https://upos-sz-mirroraliov.bilivideo.com/upgcxcode/audio.m4s?upsig=audio-ali';
      final session = PlaybackRouteSession(
        videoUrls: const [cosov, tfHw],
        audioUrls: const [audioCosov, audioAli],
      );

      expect(session.nextVideo(), tfHw);
      expect(session.audioUrl, audioCosov);
      expect(session.nextAudio(), audioAli);
      expect(session.videoUrl, tfHw);
    });

    test('bounds recovery to eight routes even with a larger local pool', () {
      final urls = List.generate(
        12,
        (index) =>
            'https://route-$index.bilivideo.com/upgcxcode/video.m4s?upsig=$index',
      );
      final session = PlaybackRouteSession(videoUrls: urls);

      final attempted = <String>[session.videoUrl];
      while (true) {
        final next = session.nextVideo();
        if (next == null) break;
        attempted.add(next);
      }

      expect(attempted, hasLength(8));
      expect(session.nextVideo(), isNull);
    });
  });
}
