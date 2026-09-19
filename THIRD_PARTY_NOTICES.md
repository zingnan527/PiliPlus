# Third-party notices for playback acceleration work

The playback route and Range-proxy implementation was informed by the
following projects. PiliPlus remains distributed under GPL-3.0.

- `taresky/PiliPlus`, branch `japan-cdn`, commit `5022c1d`: GPL-3.0. The
  `PlaybackRouteSession` and stall-recovery integration were adapted from this
  fork, with a stricter hostname-rewrite allowlist.
- `MrTangLuyao/Bilibili-thread-ripper`: MIT, Copyright (c) 2026
  Bilibili-thread-ripper contributors. Range parsing, strict response
  validation, bounded concurrency, and ordered delivery informed the Dart
  implementation.
- `siwei-yuan/bili-pilot`: MIT, Copyright (c) 2026 Bili Pilot contributors.
  Complete-range delivery and fail-open behavior informed the Dart design.
- `stabruriss/bilibili-accelerator`: MIT, Copyright (c) 2026 stabruriss.
  Probe bounding and route hysteresis informed the route-probe design.

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
