# PiliPlus overseas playback experiment

This is my public testing fork of [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus), currently based on upstream **2.1.5**. I am still using and testing it myself. Others with similar needs are welcome to try it. The complete acceleration/CDN feature set is not being submitted for upstream inclusion and does not represent the upstream author's roadmap.

## Download the Android test build

**[Download APK directly (about 137 MiB)](https://github.com/zingnan527/PiliPlus/releases/download/v2.1.5-overseas-test.20261001/v2.1.5-overseas-test.20261001-android-debug.apk)** · [Release notes and checksums](https://github.com/zingnan527/PiliPlus/releases/tag/v2.1.5-overseas-test.20261001) · [All test releases](https://github.com/zingnan527/PiliPlus/releases)

This is a **debug prerelease**, not a stable release. Package ID: `com.example.piliplus.debug`; Android 7.0 or newer; arm64-v8a, armeabi-v7a and x86_64. It normally installs alongside the original app. In-place updates require the same package ID and signing certificate as this fork's previous test build. Back up settings before switching builds; do not uninstall the original app just to force an update.

## Motivation

The idea was inspired by [Bilibili Thread Ripper](https://github.com/MrTangLuyao/Bilibili-thread-ripper): split media into byte ranges and fetch them concurrently to reduce dependence on one connection's speed.

I live overseas, where a stable connection to Chinese video CDNs is difficult to take for granted. In my experience, a CDN that works well for one video can be slow for another, especially less popular videos. I kept testing and switching routes manually, so I wanted those controls and concurrent loading inside my phone's player.

The goal is smoother viewing and an open experiment for people with similar needs. Results depend on the video, CDN, region, ISP and device. No fixed speed improvement or universal stall fix is promised.

## Usage and limitations

- Enable **Experimental Range concurrency acceleration** in video settings; it is off by default. It fetches ranges from the selected CDN rather than mixing multiple CDNs concurrently.
- The **cloud + number** control, left of the heatmap control, shows active video range requests. Open it for the current CDN, speed-test list, manual selection, a **1–128** concurrency ceiling, and automatic / manual-confirmation / off switching modes.
- The default ceiling is 64. Actual concurrency is scheduled automatically; ceiling changes apply on the next load. Both settings entries share the same configuration.
- A zero count may mean buffered playback, no current range request, or native fallback. Check the panel's acceleration status. The number is not the ceiling or an OS thread count.
- CDN reloads preserve the captured position. Stale reload/retry work is invalidated, and native opens are serialized.

More requests, probing and retries may use more data, battery and memory, increase heat, or trigger CDN throttling. Mobile networks consume mobile data too. Lower the ceiling or disable acceleration when unnecessary.

Player code in this APK is from `7a613b60f70d869427e91f0626415138b6eb468d`; the release tag additionally includes documentation. Before packaging, **78 tests passed**, analysis had no errors/warnings (38 info diagnostics), and Android debug build/signature checks passed. Long-term device stability remains under testing, including audio-playing/video-frozen cases.

Please report issues in [this fork](https://github.com/zingnan527/PiliPlus/issues), with app/device/Android versions, region/ISP, network type, video ID/time, CDN hostname, concurrency/ceiling and switching mode. Remove credentials, signed playback URLs and personal IPs from logs.

Credits and licenses: [GPL-3.0](LICENSE), [third-party notices](THIRD_PARTY_NOTICES.md). [中文说明](README.md).

---

The upstream introduction follows. Its platform support is not a claim that this fork has released or verified accelerated builds for every platform.

<div align="center">
    <img width="200" height="200" src="assets/images/logo/logo.png" alt="PiliPlus logo">
    <h1>PiliPlus</h1>
</div>

<div align="center">

[中文](README.md) | English

![GitHub repo size](https://img.shields.io/github/repo-size/bggRGjQaUbCoE/PiliPlus)
![GitHub Repo stars](https://img.shields.io/github/stars/bggRGjQaUbCoE/PiliPlus)
![GitHub all releases](https://img.shields.io/github/downloads/bggRGjQaUbCoE/PiliPlus/total)

</div>

<div align="center">
    <p>A third-party Bilibili client built with Flutter</p>

<img src="assets/screenshots/510shots_so.png" width="32%" alt="PiliPlus mobile screenshot" />
<img src="assets/screenshots/174shots_so.png" width="32%" alt="PiliPlus mobile screenshot" />
<img src="assets/screenshots/850shots_so.png" width="32%" alt="PiliPlus mobile screenshot" />
<br/>
<img src="assets/screenshots/main_screen.png" width="96%" alt="PiliPlus desktop screenshot" />
<br/>
</div>

<br/>

## Download

Use the download link above or [this fork's Releases](https://github.com/zingnan527/PiliPlus/releases) for the Android experiment. For original PiliPlus builds, use [upstream Releases](https://github.com/bggRGjQaUbCoE/PiliPlus/releases). Source for this experiment is available in this repository's public testing branch.

## Disclaimer

PiliPlus is a personal project developed for educational purposes, intended only for learning and testing. Please delete it within 24 hours of downloading.
All APIs used were collected from the official website. This project does not provide any cracked content.

Credit to the original project: [guozhigq/pilipala](https://github.com/guozhigq/pilipala).
Credit to the upstream project: [orz12/PiliPalaX](https://github.com/orz12/PiliPalaX).
This repository makes more extensive changes. Thank you to the original authors for sharing their work as open source.

Thank you for using PiliPlus.

## Acknowledgements

- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [flutter_meedu_videoplayer](https://github.com/zezo357/flutter_meedu_videoplayer)
- [media-kit](https://github.com/media-kit/media-kit)
- [dio](https://pub.dev/packages/dio)
- And others

## Star History

<a href="https://star-history.dera.page/#bggRGjQaUbCoE/PiliPlus&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=bggRGjQaUbCoE/PiliPlus&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=bggRGjQaUbCoE/PiliPlus&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=bggRGjQaUbCoE/PiliPlus&type=Date" />
 </picture>
</a>
