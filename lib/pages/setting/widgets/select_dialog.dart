import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/services/playback_acceleration/route_probe_service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget Function(BuildContext, int)? subtitleBuilder;
  final Widget? header;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.header,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?header,
                ...List.generate(
                  values.length,
                  (index) {
                    final item = values[index];
                    return RadioListTile<T>(
                      toggleable: toggleable,
                      dense: true,
                      value: item.$1,
                      title: Text(
                        item.$2,
                        style: titleMedium,
                      ),
                      subtitle: subtitleBuilder?.call(context, index),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CdnSelectDialog extends StatefulWidget {
  final BaseItem? sample;
  final Widget? header;
  final bool? speedTest;
  final CDNService? selectedService;

  const CdnSelectDialog({
    super.key,
    this.sample,
    this.header,
    this.speedTest,
    this.selectedService,
  });

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

class _CdnSelectDialogState extends State<CdnSelectDialog> {
  late final List<ValueNotifier<String?>> _cdnResList;
  late final List<CancelToken?> _tokens;
  late final bool _cdnSpeedTest;
  late final ProbeCancellation _probeCancellation;

  @override
  void initState() {
    _cdnSpeedTest = widget.speedTest ?? Pref.cdnSpeedTest;
    if (_cdnSpeedTest) {
      _probeCancellation = ProbeCancellation();
      _dio =
          Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
              ),
            )
            ..options.headers = {
              'user-agent': BrowserUa.pc,
              'referer': HttpString.baseUrl,
            };
      final length = CDNService.values.length;
      _cdnResList = List.generate(
        length,
        (_) => ValueNotifier<String?>(null),
      );
      _tokens = List.generate(length, (_) => CancelToken());
      _startSpeedTest();
    }
    super.initState();
  }

  @override
  void dispose() {
    if (_cdnSpeedTest) {
      _probeCancellation.cancel();
      for (final e in _tokens) {
        e?.cancel();
      }
      for (final notifier in _cdnResList) {
        notifier.dispose();
      }
      _dio.close(force: true);
    }
    super.dispose();
  }

  Future<BaseItem> _getSampleUrl() async {
    final result = await VideoHttp.videoUrl(
      cid: 196018899,
      bvid: 'BV1fK4y1t7hj',
      qn: VideoQuality.high1080.code,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    final item = result.dataOrNull?.dash?.video?.first;
    if (item == null) throw Exception('无法获取视频流');
    return item;
  }

  Future<void> _startSpeedTest() async {
    try {
      final videoItem = widget.sample ?? await _getSampleUrl();
      await _testAllCdnServices(videoItem);
    } catch (e) {
      if (kDebugMode) debugPrint('CDN speed test failed: $e');
    }
  }

  Future<void> _testAllCdnServices(BaseItem videoItem) async {
    final service = RouteProbeService<CDNService>(
      maxConcurrency: 4,
      probe: (item, cancellation) async {
        cancellation.throwIfCancelled();
        if (!mounted) throw const ProbeCancelled();
        final sample = await _testSingleCdn(item, videoItem);
        cancellation.throwIfCancelled();
        return sample;
      },
    );
    await service.probeAll(
      CDNService.values,
      cancellation: _probeCancellation,
    );
  }

  Future<RouteProbeSample> _testSingleCdn(
    CDNService item,
    BaseItem videoItem,
  ) async {
    try {
      final cdnUrl = VideoUtils.getCdnUrl(
        videoItem.playUrls,
        defaultCDNService: item,
      );
      return await _measureDownloadSpeed(cdnUrl, item.index);
    } catch (e) {
      _handleSpeedTestError(e, item.index);
      rethrow;
    }
  }

  late final Dio _dio;

  Future<RouteProbeSample> _measureDownloadSpeed(String url, int index) async {
    const maxSize = 8 * 1024 * 1024;
    int downloaded = 0;
    int? firstProgress;
    RouteProbeSample? completedSample;

    final cancelToken = _tokens[index];
    final start = DateTime.now().microsecondsSinceEpoch;

    void onClose() {
      cancelToken?.cancel();
      _tokens[index] = null;
    }

    RouteProbeSample finish(int duration) {
      final sample = RouteProbeSample(
        bytes: downloaded,
        ttfb: Duration(microseconds: (firstProgress ?? start) - start),
        elapsed: Duration(microseconds: duration),
      );
      _updateSpeedResult(index, downloaded, duration);
      completedSample = sample;
      return sample;
    }

    try {
      await _dio.get(
        url,
        cancelToken: cancelToken,
        onReceiveProgress: (count, total) {
          if (!mounted) return;

          final now = DateTime.now().microsecondsSinceEpoch;
          firstProgress ??= now;
          final duration = now - start;
          downloaded = count;

          if (duration > 15000000) {
            onClose();
            if (downloaded > 0) {
              finish(duration);
            } else {
              throw TimeoutException('测速超时');
            }
          } else if (downloaded >= maxSize) {
            finish(duration);
            onClose();
          }
        },
      );
    } on DioException catch (error) {
      if (completedSample == null || !CancelToken.isCancel(error)) rethrow;
    }
    if (completedSample case final sample?) return sample;
    if (downloaded <= 0) throw TimeoutException('测速未返回数据');
    return finish(DateTime.now().microsecondsSinceEpoch - start);
  }

  void _updateSpeedResult(int index, int downloaded, int duration) {
    final speed = (downloaded / duration).toStringAsPrecision(3);
    _cdnResList[index].value = '${speed}MB/s';
  }

  void _handleSpeedTestError(dynamic error, int index) {
    _tokens
      ..[index]?.cancel()
      ..[index] = null;
    final item = _cdnResList[index];
    if (item.value != null) return;

    if (kDebugMode) debugPrint('CDN speed test error: $error');
    if (!mounted) return;
    String message;
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null && 400 <= statusCode && statusCode < 500) {
        message = '此视频可能无法替换为该CDN';
      } else {
        message = error.toString();
      }
    } else {
      message = error.toString();
    }
    if (message.isEmpty) {
      message = '测速失败';
    }
    item.value = message;
  }

  @override
  Widget build(BuildContext context) {
    return SelectDialog<CDNService>(
      title: 'CDN 设置',
      header: widget.header,
      values: CDNService.values.map((i) => (i, i.desc)).toList(),
      value: widget.selectedService ?? VideoUtils.cdnService,
      subtitleBuilder: _cdnSpeedTest
          ? (context, index) {
              final item = _cdnResList[index];
              return ValueListenableBuilder(
                valueListenable: item,
                builder: (context, value, _) {
                  return Text(
                    value ?? '---',
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              );
            }
          : null,
    );
  }
}
