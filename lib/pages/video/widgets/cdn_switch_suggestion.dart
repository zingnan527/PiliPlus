import 'dart:async';
import 'dart:math' show min;

import 'package:material_ui/material_ui.dart';

class CdnSwitchSuggestion extends StatefulWidget {
  final String currentHost;
  final String targetHost;
  final double targetBytesPerSecond;
  final Duration targetTtfb;
  final int? improvementPercent;
  final Duration countdown;
  final VoidCallback onSwitch;
  final VoidCallback onDismiss;

  const CdnSwitchSuggestion({
    super.key,
    required this.currentHost,
    required this.targetHost,
    required this.targetBytesPerSecond,
    required this.targetTtfb,
    required this.improvementPercent,
    this.countdown = const Duration(seconds: 10),
    required this.onSwitch,
    required this.onDismiss,
  });

  @override
  State<CdnSwitchSuggestion> createState() => _CdnSwitchSuggestionState();
}

class _CdnSwitchSuggestionState extends State<CdnSwitchSuggestion> {
  Timer? _timer;
  late int _secondsLeft;
  bool _finished = false;

  String _shortHost(String host) => host
      .replaceFirst(RegExp(r'\.bilivideo\.com$'), '')
      .replaceFirst(RegExp(r'^upos-(?:sz|tf)-'), '');

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.countdown.inSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft <= 1) {
        _finish(widget.onDismiss);
      } else if (mounted) {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  void _finish(VoidCallback callback) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    callback();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = min(MediaQuery.sizeOf(context).width - 24, 380.0);
    final speedMbps = widget.targetBytesPerSecond * 8 / 1000000;
    final comparison = switch (widget.improvementPercent) {
      final percent? when percent > 0 => '快约 $percent%',
      _ => '当前线路测速失败',
    };
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 64),
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.speed, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '播放卡顿 · 候选线路$comparison',
                        style: theme.textTheme.labelMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_shortHost(widget.currentHost)} → ${_shortHost(widget.targetHost)} · '
                        '${speedMbps.toStringAsFixed(1)} Mbps · '
                        '${widget.targetTtfb.inMilliseconds} ms',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => _finish(widget.onSwitch),
                  child: Text('切换 ${_secondsLeft}s'),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => _finish(widget.onDismiss),
                  icon: const Icon(Icons.close, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
