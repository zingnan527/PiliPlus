import 'package:PiliPlus/models/common/video/cdn_switch_mode.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/services/playback_acceleration/loopback_range_proxy.dart';
import 'package:material_ui/material_ui.dart';

/// Compact player-bar entry for the current video CDN and Range acceleration.
class CdnControlButton extends StatelessWidget {
  const CdnControlButton({
    required this.stream,
    required this.initialSnapshot,
    required this.currentCdn,
    required this.accelerationStatus,
    required this.selectedService,
    required this.maxConcurrency,
    required this.switchMode,
    required this.onCdnSelected,
    required this.onConcurrencyLimitChanged,
    required this.onSwitchModeChanged,
    this.sample,
    this.speedTest = true,
    super.key,
  });

  final Stream<RangeConcurrencySnapshot> stream;
  final RangeConcurrencySnapshot initialSnapshot;
  final String Function() currentCdn;
  final String Function() accelerationStatus;
  final CDNService Function() selectedService;
  final int Function() maxConcurrency;
  final CdnSwitchMode Function() switchMode;
  final BaseItem? sample;
  final bool speedTest;
  final void Function(CDNService) onCdnSelected;
  final Future<void> Function(int) onConcurrencyLimitChanged;
  final Future<void> Function(CdnSwitchMode) onSwitchModeChanged;

  Future<void> _open(
    BuildContext context,
    RangeConcurrencySnapshot currentSnapshot,
  ) async {
    final result = await showDialog<CDNService>(
      context: context,
      builder: (context) => CdnSelectDialog(
        sample: sample,
        speedTest: speedTest,
        selectedService: selectedService(),
        header: _CdnControlHeader(
          stream: stream,
          initialSnapshot: currentSnapshot,
          currentCdn: currentCdn,
          accelerationStatus: accelerationStatus,
          selectedService: selectedService(),
          maxConcurrency: maxConcurrency(),
          switchMode: switchMode(),
          onConcurrencyLimitChanged: onConcurrencyLimitChanged,
          onSwitchModeChanged: onSwitchModeChanged,
          speedTest: speedTest,
        ),
      ),
    );
    if (result != null) onCdnSelected(result);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RangeConcurrencySnapshot>(
      stream: stream,
      initialData: initialSnapshot,
      builder: (context, snapshot) {
        final requests = snapshot.data?.activeRequests ?? 0;
        return Tooltip(
          message: 'CDN 控制',
          child: InkWell(
            onTap: () => _open(context, snapshot.data ?? initialSnapshot),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.cloud_outlined,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '$requests',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CdnControlHeader extends StatefulWidget {
  const _CdnControlHeader({
    required this.stream,
    required this.initialSnapshot,
    required this.currentCdn,
    required this.accelerationStatus,
    required this.selectedService,
    required this.maxConcurrency,
    required this.switchMode,
    required this.onConcurrencyLimitChanged,
    required this.onSwitchModeChanged,
    required this.speedTest,
  });

  final Stream<RangeConcurrencySnapshot> stream;
  final RangeConcurrencySnapshot initialSnapshot;
  final String Function() currentCdn;
  final String Function() accelerationStatus;
  final CDNService selectedService;
  final int maxConcurrency;
  final CdnSwitchMode switchMode;
  final Future<void> Function(int) onConcurrencyLimitChanged;
  final Future<void> Function(CdnSwitchMode) onSwitchModeChanged;
  final bool speedTest;

  @override
  State<_CdnControlHeader> createState() => _CdnControlHeaderState();
}

class _CdnControlHeaderState extends State<_CdnControlHeader> {
  late int limit = widget.maxConcurrency;
  late CdnSwitchMode mode = widget.switchMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前 CDN：${widget.currentCdn()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text('默认 CDN：${widget.selectedService.desc}'),
          StreamBuilder<RangeConcurrencySnapshot>(
            stream: widget.stream,
            initialData: widget.initialSnapshot,
            builder: (context, snapshot) {
              final value = snapshot.data ?? widget.initialSnapshot;
              return Text(
                '当前并发：${value.activeRequests}/${value.maxConcurrency} 路 · ${widget.accelerationStatus()}',
              );
            },
          ),
          const SizedBox(height: 6),
          Text('并发上限：$limit 路（下次加载生效）'),
          Slider(
            value: limit.toDouble(),
            min: 1,
            max: 128,
            divisions: 127,
            label: '$limit',
            onChanged: (value) => setState(() => limit = value.round()),
            onChangeEnd: (value) =>
                widget.onConcurrencyLimitChanged(value.round()),
          ),
          Row(
            children: [
              const Expanded(child: Text('卡顿时切换 CDN')),
              DropdownButton<CdnSwitchMode>(
                value: mode,
                isDense: true,
                items: CdnSwitchMode.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => mode = value);
                  widget.onSwitchModeChanged(value);
                },
              ),
            ],
          ),
          const Divider(height: 12),
          Text(widget.speedTest ? '测速与手动选择线路（测速会消耗流量）' : '手动选择线路（测速已关闭）'),
        ],
      ),
    );
  }
}
