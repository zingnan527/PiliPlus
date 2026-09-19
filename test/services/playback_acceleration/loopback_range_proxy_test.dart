import 'dart:io';

import 'package:PiliPlus/services/playback_acceleration/loopback_range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_range_origin.dart';

void main() {
  late FakeRangeOrigin origin;
  late LoopbackRangeProxy proxy;

  setUp(() async {
    origin = await FakeRangeOrigin.start(
      payloadLength: 16 * 1024,
      timeoutDuration: const Duration(seconds: 1),
      slowDelay: const Duration(milliseconds: 250),
      stallDuration: const Duration(seconds: 1),
    );
    proxy = LoopbackRangeProxy(
      chunkSize: 512,
      globalMaxConcurrency: 8,
      responseTimeout: const Duration(milliseconds: 100),
      bodyStallTimeout: const Duration(milliseconds: 100),
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.close();
    await origin.close();
  });

  test('uses conservative per-track concurrency defaults', () {
    expect(recommendedRangeProxyConcurrency(isWifi: true), 4);
    expect(recommendedRangeProxyConcurrency(isWifi: false), 2);
  });

  test(
    'uses an opaque loopback token and streams valid bytes in order',
    () async {
      final handle = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.correct206),
        trackType: ProxyTrackType.video,
        maxConcurrency: 4,
      );

      expect(proxy.address.address, InternetAddress.loopbackIPv4.address);
      expect(proxy.port, isNonZero);
      expect(handle.localUri.host, InternetAddress.loopbackIPv4.address);
      expect(handle.localUri.query, isEmpty);
      expect(handle.localUri.toString(), isNot(contains('mode=')));
      expect(
        handle.localUri.pathSegments.last,
        hasLength(greaterThanOrEqualTo(32)),
      );

      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=256-2303');
      final response = await request.close();
      final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      client.close(force: true);

      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.headers.contentLength, 2048);
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 256-2303/16384',
      );
      expect(body, origin.payload.sublist(256, 2304));
      expect(origin.maxActiveRequests, inInclusiveRange(2, 4));
      expect(origin.requestedRanges, hasLength(4));
    },
  );

  test('resolves an open range against the validated upstream total', () async {
    final handle = proxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.correct206),
      trackType: ProxyTrackType.video,
      maxConcurrency: 4,
    );

    final client = HttpClient();
    final request = await client.getUrl(handle.localUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=4096-');
    final response = await request.close();
    final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
      bytes.addAll(chunk);
      return bytes;
    });
    client.close(force: true);

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 4096-16383/16384',
    );
    expect(body, origin.payload.sublist(4096));
  });

  test(
    'rejects unknown tokens and never accepts an upstream URL parameter',
    () async {
      final client = HttpClient();
      final unknown = Uri(
        scheme: 'http',
        host: proxy.address.address,
        port: proxy.port,
        path: '/v1/media/not-a-session',
        queryParameters: {'url': origin.url.toString()},
      );
      final request = await client.getUrl(unknown);
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      expect(response.statusCode, HttpStatus.badRequest);
      expect(origin.requestedRanges, isEmpty);
    },
  );

  for (final mode in <FakeRangeMode>[
    FakeRangeMode.forbidden403,
    FakeRangeMode.timeout,
    FakeRangeMode.connectionInterruption,
    FakeRangeMode.ignoreRange200,
    FakeRangeMode.wrongContentRange,
    FakeRangeMode.shortBody,
    FakeRangeMode.longBody,
    FakeRangeMode.slowFirstByte,
    FakeRangeMode.slowHeader,
    FakeRangeMode.tailStall,
  ]) {
    test('fails closed for upstream mode $mode', () async {
      final handle = proxy.createSession(
        upstream: origin.uriFor(mode),
        trackType: ProxyTrackType.video,
        maxConcurrency: 1,
      );
      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
      final response = await request.close();
      final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      client.close(force: true);

      expect(response.statusCode, HttpStatus.badGateway);
      expect(body, isEmpty);
    });
  }

  test(
    'rejects a candidate whose total differs from the session identity',
    () async {
      final handle = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.candidateTotalMismatch),
        trackType: ProxyTrackType.audio,
        maxConcurrency: 2,
        expectedTotal: origin.totalLength,
      );
      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      expect(response.statusCode, HttpStatus.badGateway);
    },
  );

  test('notifies the owner once so playback can fail open', () async {
    final failures = <ProxyFailure>[];
    final handle = proxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.forbidden403),
      trackType: ProxyTrackType.video,
      onFailure: failures.add,
    );

    Future<void> failRequest() async {
      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
    }

    await failRequest();
    await failRequest();
    expect(failures, hasLength(1));
    expect(failures.single.sessionId, handle.sessionId);
    expect(failures.single.trackType, ProxyTrackType.video);
    expect(failures.single.reason, 'expected 206, got 403');
  });

  test('closing a session makes its token unusable', () async {
    final handle = proxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.correct206),
      trackType: ProxyTrackType.video,
    );
    await handle.close();

    final client = HttpClient();
    final response = await (await client.getUrl(handle.localUri)).close();
    await response.drain<void>();
    client.close(force: true);
    expect(response.statusCode, HttpStatus.notFound);
  });

  test(
    'video and audio sessions share the global concurrency budget',
    () async {
      final video = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.slowFirstByte),
        trackType: ProxyTrackType.video,
        maxConcurrency: 8,
      );
      final audio = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.slowFirstByte),
        trackType: ProxyTrackType.audio,
        maxConcurrency: 8,
      );

      Future<int> load(Uri uri) async {
        final client = HttpClient();
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
        final response = await request.close();
        await response.drain<void>();
        client.close(force: true);
        return response.statusCode;
      }

      final statuses = await Future.wait([
        load(video.localUri),
        load(audio.localUri),
      ]);
      expect(statuses, everyElement(HttpStatus.badGateway));
      expect(origin.maxActiveRequests, lessThanOrEqualTo(8));
    },
  );

  test(
    'explicit seek cancellation aborts an active upstream transfer',
    () async {
      final handle = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.tailStall),
        trackType: ProxyTrackType.video,
        maxConcurrency: 1,
      );
      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
      final pending = request.close();
      while (origin.requestedRanges.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      handle.cancelActiveTransfers();
      final response = await pending.timeout(const Duration(seconds: 1));
      await response.drain<void>();
      client.close(force: true);
      expect(response.statusCode, HttpStatus.badGateway);
    },
  );

  test('HEAD validates the resource and returns no body', () async {
    final handle = proxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.correct206),
      trackType: ProxyTrackType.audio,
    );
    final client = HttpClient();
    final request = await client.openUrl('HEAD', handle.localUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final response = await request.close();
    final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
      bytes.addAll(chunk);
      return bytes;
    });
    client.close(force: true);

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 10-19/16384',
    );
    expect(body, isEmpty);
  });
}
