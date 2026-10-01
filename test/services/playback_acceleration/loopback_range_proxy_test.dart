import 'dart:io';

import 'package:PiliPlus/services/playback_acceleration/byte_range.dart';
import 'package:PiliPlus/services/playback_acceleration/loopback_range_proxy.dart';
import 'package:PiliPlus/services/playback_acceleration/range_fetcher.dart';
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

  test('uses aggressive startup concurrency within the configured ceiling', () {
    expect(recommendedRangeProxyConcurrency(isWifi: true), 128);
    expect(recommendedRangeProxyConcurrency(isWifi: false), 16);
    expect(
      recommendedRangeProxyConcurrency(isWifi: true, maxConcurrency: 3),
      3,
    );
    expect(
      recommendedRangeProxyConcurrency(isWifi: false, maxConcurrency: 1),
      1,
    );
  });

  test('expands under pressure and only shrinks on explicit rate limits', () {
    final controller = RangeConcurrencyController(
      initialConcurrency: 16,
      maxConcurrency: 128,
    );
    const fastChunk = RangeChunk(
      range: ByteRange(0, 255),
      total: 1024,
      bytes: <int>[],
      ttfb: Duration(milliseconds: 100),
      elapsed: Duration(milliseconds: 250),
    );
    const slowChunk = RangeChunk(
      range: ByteRange(0, 255),
      total: 1024,
      bytes: <int>[],
      ttfb: Duration(seconds: 1),
      elapsed: Duration(seconds: 2),
    );

    expect((controller..recordSuccess(fastChunk)).currentConcurrency, 16);
    expect((controller..recordSuccess(slowChunk)).currentConcurrency, 32);
    expect((controller..requestMoreCapacity()).currentConcurrency, 64);

    expect(
      (controller..recordFailure(const RangeFetchException('timeout')))
          .currentConcurrency,
      128,
    );
    expect(
      (controller..recordFailure(
            const RangeFetchException('expected 206, got 429'),
          ))
          .currentConcurrency,
      64,
    );

    expect(
      (controller..recordFailure(
            const RangeFetchException('Content-Range mismatch'),
          ))
          .currentConcurrency,
      64,
    );
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
    'reports only active video range requests and clears them on cancellation',
    () async {
      final video = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.tailStall),
        trackType: ProxyTrackType.video,
        maxConcurrency: 4,
      );
      final audio = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.tailStall),
        trackType: ProxyTrackType.audio,
        maxConcurrency: 4,
      );
      final videoEvents = <RangeConcurrencySnapshot>[];
      final subscription = video.concurrencyChanges.listen(videoEvents.add);
      addTearDown(subscription.cancel);

      Future<void> load(ProxyMediaHandle handle) async {
        final client = HttpClient();
        final request = await client.getUrl(handle.localUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
        final response = await request.close();
        await response.drain<void>();
        client.close(force: true);
      }

      final pendingVideo = load(video);
      final pendingAudio = load(audio);
      while (origin.requestedRanges.length < 2 ||
          video.concurrencySnapshot.activeRequests != 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(video.concurrencySnapshot, const RangeConcurrencySnapshot(1, 4));
      expect(audio.concurrencySnapshot, const RangeConcurrencySnapshot(0, 4));

      video.cancelActiveTransfers();
      await pendingVideo.timeout(const Duration(seconds: 1));
      await pendingAudio.timeout(const Duration(seconds: 1));

      expect(video.concurrencySnapshot, const RangeConcurrencySnapshot(0, 4));
      expect(videoEvents.map((snapshot) => snapshot.activeRequests), [1, 0]);
    },
  );

  test(
    'video failover recovers while the independent audio session continues',
    () async {
      final video = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.tailStall),
        fallbackUpstreams: [origin.uriFor(FakeRangeMode.correct206)],
        trackType: ProxyTrackType.video,
        maxConcurrency: 1,
      );
      final audio = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.correct206),
        trackType: ProxyTrackType.audio,
        maxConcurrency: 1,
      );

      Future<(int, List<int>)> load(Uri uri, String range) async {
        final client = HttpClient();
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.rangeHeader, range);
        final response = await request.close();
        final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
          bytes.addAll(chunk);
          return bytes;
        });
        client.close(force: true);
        return (response.statusCode, body);
      }

      final results = await Future.wait([
        load(video.localUri, 'bytes=0-511'),
        load(audio.localUri, 'bytes=512-1023'),
      ]);

      expect(results[0].$1, HttpStatus.partialContent);
      expect(results[0].$2, origin.payload.sublist(0, 512));
      expect(results[1].$1, HttpStatus.partialContent);
      expect(results[1].$2, origin.payload.sublist(512, 1024));
      expect(origin.requestedRanges.length, greaterThanOrEqualTo(3));
    },
  );

  test('queued video work is served before queued audio work', () async {
    final priorityProxy = LoopbackRangeProxy(
      chunkSize: 512,
      globalMaxConcurrency: 1,
      responseTimeout: const Duration(milliseconds: 100),
      bodyStallTimeout: const Duration(milliseconds: 100),
    );
    await priorityProxy.start();
    addTearDown(priorityProxy.close);

    final blockingAudio = priorityProxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.slowFirstByte),
      trackType: ProxyTrackType.audio,
    );
    final queuedAudio = priorityProxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.correct206),
      trackType: ProxyTrackType.audio,
    );
    final queuedVideo = priorityProxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.correct206),
      trackType: ProxyTrackType.video,
    );

    Future<int> load(Uri uri, String range) async {
      final client = HttpClient();
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      return response.statusCode;
    }

    final first = load(blockingAudio.localUri, 'bytes=0-511');
    while (origin.requestedRanges.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final audio = load(queuedAudio.localUri, 'bytes=1024-1535');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final video = load(queuedVideo.localUri, 'bytes=512-1023');

    final statuses = await Future.wait([first, audio, video]);
    expect(statuses, [HttpStatus.badGateway, 206, 206]);
    expect(
      origin.requestedRanges.map((request) => request.start),
      containsAllInOrder([0, 512, 1024]),
    );
  });

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

  test(
    'proves fallback identity before mixing sources mid-stream',
    () async {
      final handle = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.prefixTailStall),
        fallbackUpstreams: [origin.uriFor(FakeRangeMode.correct206)],
        trackType: ProxyTrackType.video,
        maxConcurrency: 2,
      );

      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=4096-8191');
      final response = await request.close();
      final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      client.close(force: true);

      expect(response.statusCode, HttpStatus.partialContent);
      // Every piece stalls on the primary beyond the probed prefix and must
      // be re-fetched from the verified fallback; the bytes stay canonical.
      expect(body, origin.payload.sublist(4096, 8192));
      // Both upstreams were fingerprinted exactly once over the init window.
      final probes = origin.requestedRanges
          .where((request) => request.raw == 'bytes=0-4095')
          .length;
      expect(probes, 2);
    },
  );

  test(
    'refuses to mix bytes from a same-length fallback with different init bytes',
    () async {
      final impostor = await FakeRangeOrigin.start(
        payload: List<int>.generate(
          16 * 1024,
          (index) => (index * 7 + 3) & 0xff,
        ),
        timeoutDuration: const Duration(seconds: 1),
        slowDelay: const Duration(milliseconds: 250),
        stallDuration: const Duration(seconds: 1),
      );
      addTearDown(impostor.close);

      final handle = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.prefixTailStall),
        fallbackUpstreams: [impostor.uriFor(FakeRangeMode.correct206)],
        trackType: ProxyTrackType.video,
        maxConcurrency: 2,
      );

      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-8191');
      final response = await request.close();
      final body = <int>[];
      Object? truncation;
      try {
        await response.fold<List<int>>(body, (bytes, chunk) {
          bytes.addAll(chunk);
          return bytes;
        });
      } catch (error) {
        truncation = error;
      }
      client.close(force: true);

      // The impostor has the same total length but a different fingerprint,
      // so it is excluded before any byte mixing.  Once the primary stalls
      // beyond the verified prefix, the proxy fails closed instead of
      // borrowing foreign bytes: the client keeps only the canonical prefix
      // that was already streamed and sees an explicit truncation error.
      expect(response.statusCode, HttpStatus.partialContent);
      expect(body, origin.payload.sublist(0, 4096));
      expect(truncation, isNotNull);
      expect(
        impostor.requestedRanges.map((request) => request.raw),
        everyElement(anyOf('bytes=0-0', 'bytes=0-4095')),
      );
      expect(impostor.requestedRanges, hasLength(2));
    },
  );

  test(
    'verifies identity for resources smaller than the probe window',
    () async {
      final smallA = await FakeRangeOrigin.start(
        payloadLength: 2000,
        timeoutDuration: const Duration(seconds: 1),
        slowDelay: const Duration(milliseconds: 250),
        stallDuration: const Duration(seconds: 1),
      );
      addTearDown(smallA.close);
      final smallB = await FakeRangeOrigin.start(
        payload: smallA.payload,
        timeoutDuration: const Duration(seconds: 1),
        slowDelay: const Duration(milliseconds: 250),
        stallDuration: const Duration(seconds: 1),
      );
      addTearDown(smallB.close);

      final handle = proxy.createSession(
        upstream: smallA.uriFor(FakeRangeMode.correct206),
        fallbackUpstreams: [smallB.uriFor(FakeRangeMode.correct206)],
        trackType: ProxyTrackType.video,
        maxConcurrency: 2,
      );

      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1999');
      final response = await request.close();
      final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      client.close(force: true);

      expect(response.statusCode, HttpStatus.partialContent);
      expect(body, smallA.payload);
      // The fingerprint window clamps to the real total (0-1999), so the
      // sub-4KiB resource is accepted instead of rejected.  Each upstream is
      // probed exactly twice: one-byte total discovery + clamped fingerprint.
      expect(smallB.requestedRanges.map((request) => request.raw), [
        'bytes=0-0',
        'bytes=0-1999',
      ]);
      expect(
        smallA.requestedRanges.where(
          (request) => request.raw == 'bytes=0-1999',
        ),
        hasLength(1),
      );
      // Primary: 2 probes + 4 data pieces of 512 bytes.
      expect(smallA.requestedRanges, hasLength(6));
    },
  );

  test('streams out-of-order completions in strict byte order', () async {
    final handle = proxy.createSession(
      upstream: origin.uriFor(FakeRangeMode.reverseJitter),
      trackType: ProxyTrackType.video,
      maxConcurrency: 4,
    );

    final client = HttpClient();
    final request = await client.getUrl(handle.localUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-4095');
    final response = await request.close();
    final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
      bytes.addAll(chunk);
      return bytes;
    });
    client.close(force: true);

    expect(response.statusCode, HttpStatus.partialContent);
    expect(body, origin.payload.sublist(0, 4096));
    // Single upstream: no identity probe, exactly the 8 data pieces.
    expect(origin.requestedRanges, hasLength(8));
  });

  test(
    'discards a stale in-flight response after seek cancellation',
    () async {
      // A dedicated origin/proxy pair: the 300 ms first-byte delay keeps the
      // first request in flight long enough for a deterministic cancel, yet
      // stays inside the patient proxy's 1 s stall budget so the next
      // generation can succeed.
      final slowOrigin = await FakeRangeOrigin.start(
        payloadLength: 16 * 1024,
        timeoutDuration: const Duration(seconds: 1),
        slowDelay: const Duration(milliseconds: 300),
        stallDuration: const Duration(seconds: 1),
      );
      addTearDown(slowOrigin.close);
      final patientProxy = LoopbackRangeProxy(
        chunkSize: 512,
        globalMaxConcurrency: 8,
        responseTimeout: const Duration(seconds: 1),
        bodyStallTimeout: const Duration(seconds: 1),
      );
      await patientProxy.start();
      addTearDown(patientProxy.close);

      final handle = patientProxy.createSession(
        upstream: slowOrigin.uriFor(FakeRangeMode.slowFirstByte),
        trackType: ProxyTrackType.video,
        maxConcurrency: 1,
      );

      final clientA = HttpClient();
      final requestA = await clientA.getUrl(handle.localUri);
      requestA.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
      final pendingA = requestA.close();
      while (slowOrigin.requestedRanges.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      handle.cancelActiveTransfers();
      final responseA = await pendingA.timeout(const Duration(seconds: 2));
      final bodyA = await responseA.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      clientA.close(force: true);
      expect(responseA.statusCode, HttpStatus.badGateway);
      expect(bodyA, isEmpty);

      // The next generation must not see any byte from the cancelled one.
      final clientB = HttpClient();
      final requestB = await clientB.getUrl(handle.localUri);
      requestB.headers.set(HttpHeaders.rangeHeader, 'bytes=512-1023');
      final responseB = await requestB.close();
      final bodyB = await responseB.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      clientB.close(force: true);
      expect(responseB.statusCode, HttpStatus.partialContent);
      expect(bodyB, slowOrigin.payload.sublist(512, 1024));
    },
  );

  test(
    'rapid repeated cancellation never splices bytes across generations',
    () async {
      final slowOrigin = await FakeRangeOrigin.start(
        payloadLength: 16 * 1024,
        timeoutDuration: const Duration(seconds: 1),
        slowDelay: const Duration(milliseconds: 300),
        stallDuration: const Duration(seconds: 1),
      );
      addTearDown(slowOrigin.close);
      final patientProxy = LoopbackRangeProxy(
        chunkSize: 512,
        globalMaxConcurrency: 8,
        responseTimeout: const Duration(seconds: 1),
        bodyStallTimeout: const Duration(seconds: 1),
      );
      await patientProxy.start();
      addTearDown(patientProxy.close);

      final handle = patientProxy.createSession(
        upstream: slowOrigin.uriFor(FakeRangeMode.slowFirstByte),
        trackType: ProxyTrackType.video,
        maxConcurrency: 1,
      );

      for (var index = 0; index < 3; index += 1) {
        final seen = slowOrigin.requestedRanges.length;
        final client = HttpClient();
        final request = await client.getUrl(handle.localUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
        final pending = request.close();
        while (slowOrigin.requestedRanges.length == seen) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        handle.cancelActiveTransfers();
        final response = await pending.timeout(const Duration(seconds: 2));
        await response.drain<void>();
        client.close(force: true);
        expect(response.statusCode, HttpStatus.badGateway);
      }

      // After three rapid cancellations the next generation still streams
      // canonical bytes — the 300 ms first-byte delay is inside the patient
      // proxy's stall budget.
      final client = HttpClient();
      final request = await client.getUrl(handle.localUri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final response = await request.close();
      final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        return bytes;
      });
      client.close(force: true);
      expect(response.statusCode, HttpStatus.partialContent);
      expect(body, slowOrigin.payload.sublist(0, 1024));
    },
  );

  test(
    'notifies the owner at most once when every candidate fails',
    () async {
      final failures = <ProxyFailure>[];
      final handle = proxy.createSession(
        upstream: origin.uriFor(FakeRangeMode.forbidden403),
        fallbackUpstreams: [origin.uriFor(FakeRangeMode.timeout)],
        trackType: ProxyTrackType.video,
        maxConcurrency: 2,
        onFailure: failures.add,
      );

      Future<void> failRequest() async {
        final client = HttpClient();
        final request = await client.getUrl(handle.localUri);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-511');
        final response = await request.close();
        await response.drain<void>();
        client.close(force: true);
        expect(response.statusCode, HttpStatus.badGateway);
      }

      await failRequest();
      await failRequest();
      expect(failures, hasLength(1));
      expect(failures.single.sessionId, handle.sessionId);
    },
  );
}
