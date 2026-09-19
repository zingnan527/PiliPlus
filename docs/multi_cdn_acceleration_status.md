# Multi-CDN playback acceleration status

Date: 2026-09-19

## Baseline audit

- Upstream: `bggRGjQaUbCoE/PiliPlus` at
  `a85ae21c005da23ad53d93f2b76e25c1ecc32dfb` (2026-09-18).
- Feature branch: `feature/multi-cdn-range-proxy`.
- The original CDN speed test was embedded in the settings dialog and tested
  every `CDNService` serially, up to 8 MiB and 15 seconds per candidate.
- Playback used the selected URL directly. The player retried the same source
  after an open error and had no bounded route cursor.
- The upstream test tree contained one tracked unit test. `.gitignore` ignores
  `test*`, so new tests are intentionally force-added without changing the
  repository-wide ignore rule.

## Delivered phases

### Phase 0: reproducible failure fixture

`FakeRangeOrigin` binds IPv4 loopback on a random port and covers correct 206,
403, response timeout, interrupted connection, 200 ignoring Range, incorrect
Content-Range, short/long body, total mismatch, slow headers/first byte, and a
stalled tail. It records ranges and maximum active requests for concurrency
assertions.

### Phase 1: bounded route recovery and probes

- `PlaybackRouteSession` keeps complete API-supplied signed URLs, de-duplicates
  hosts, advances only forward, and stops after at most eight routes.
- Akamai is only used when the API supplied the complete URL. Host rewriting
  is limited to the ordinary UPOS hosts enumerated in code.
- Sustained buffering uses a 2.5-second grace period and a 5-second retry
  cadence. Progress resets the grace window; exhaustion stops automatic
  switching. Playback position is preserved across a route reload.
- Settings probes now run through a cancellable service capped at four active
  candidates. Probe results are cold-start health signals; they do not become
  permanent playback winners.

### Single-CDN Range proxy MVP

- The server binds only `127.0.0.1` on an OS-assigned port.
- Local URLs contain only a 192-bit random token. Upstream URLs and query
  strings remain in the private session map; the endpoint never accepts a URL
  parameter.
- GET/HEAD accept one closed byte range or mpv's observed `bytes=<start>-`
  form. An open range is converted to a closed range only after a validated
  `bytes=0-0` probe establishes the resource total. Suffix and multipart
  ranges remain rejected. Each upstream chunk must return exact 206,
  Content-Range start/end/total, Content-Length, and body length.
- Chunks use bounded rolling concurrency and are written to the player in byte
  order. Video and audio have separate sessions and share a global budget of
  16. Emulator A/B testing showed response timeouts at Wi-Fi 8, so conservative
  per-track defaults are Wi-Fi 4 and mobile 2, capped at 16.
- Session close and explicit transfer cancellation terminate active clients.
- One proxy failure notification disables the proxy for the current playback
  and reopens the original signed URL once. This prevents an error/reopen loop.
- Android cleartext is denied by default and allowed only for `127.0.0.1`.
- The experimental switch defaults off until Android device verification is
  complete.

## Verification evidence

The focused suite passes 35 tests:

```text
flutter test --no-pub \
  test/utils/playback_route_session_test.dart \
  test/services/playback_acceleration/byte_range_test.dart \
  test/services/playback_acceleration/route_probe_service_test.dart \
  test/services/playback_acceleration/loopback_range_proxy_test.dart

00:01 +35: All tests passed!
```

Focused analysis of the acceleration modules, route utilities, settings UI,
video controller, and player controller reports no issues.

The exact repository-declared toolchain is Flutter 3.47.4 / Dart 3.13.3. The
build uses a short, task-local Pub cache with process-scoped Git long-path
support. The same Android Flutter/material patches as upstream CI were applied
without the upstream script's global Git writes or hard reset. Because Windows
Developer Mode is disabled, the first full Android tooling generation was run
with the unrelated Windows/Linux project directories temporarily moved aside
and restored immediately afterward. A subsequent
`flutter build apk --debug --no-pub` exited 0 and produced `app-debug.apk`.

The APK was installed on the `Pixel_6a_API_34` emulator. Startup plugin/JNI
registration, public-video playback, open Range handling, seek,
pause/resume, and background/foreground recovery were exercised. The app
process remained alive and the main activity resumed without an unhandled
exception. An intentional transfer cancellation can still surface as one
ffmpeg 502 warning while the replacement loopback request continues playing.

## Performance evidence

No real-device baseline/enabled dataset exists yet. Therefore this branch does
not claim that acceleration improves playback. The required paired run still
needs startup time, stall count and duration, p50/p95 chunk completion,
effective throughput, traffic amplification, CPU, and battery trend for the
same video, quality, network, and time window.

## Remaining risks and Phase 3 entry

1. Run continuous playback, seek, quality change, part change, pause/resume,
   background/foreground, and exit tests on Android for at least 30 minutes.
2. Confirm behavior on a physical Android device and on slower real Wi-Fi;
   mpv open ranges are supported, while suffix and multipart ranges remain
   intentionally rejected.
3. Add structured metrics without logging media URL, query, cookies, or token.
4. Only after the single-CDN device gate passes, add multiple complete API URLs
   per chunk with EWMA throughput, TTFB, failure rate, cooldown, hysteresis, and
   one limited hedge. Total mismatch must quarantine a candidate.
5. Add SIDX-aware prefetch only after Phase 3, gated on at least 15 seconds of
   buffer and complete byte coverage.
