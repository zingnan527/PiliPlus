import 'dart:async';

import 'package:PiliPlus/models/common/video/cdn_switch_mode.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/pages/video/widgets/cdn_control_button.dart';
import 'package:PiliPlus/services/playback_acceleration/loopback_range_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('shows the live request count before opening CDN controls', (
    tester,
  ) async {
    final updates = StreamController<RangeConcurrencySnapshot>.broadcast();
    final selections = <CDNService>[];
    addTearDown(updates.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CdnControlButton(
            stream: updates.stream,
            initialSnapshot: const RangeConcurrencySnapshot(2, 64),
            currentCdn: () => '当前线路.example',
            accelerationStatus: () => '正在下载',
            selectedService: () => CDNService.baseUrl,
            maxConcurrency: () => 64,
            switchMode: () => CdnSwitchMode.manual,
            speedTest: false,
            onCdnSelected: selections.add,
            onConcurrencyLimitChanged: (_) async {},
            onSwitchModeChanged: (_) async {},
          ),
        ),
      ),
    );

    expect(find.text('2'), findsOneWidget);
    expect(find.text('CDN'), findsNothing);

    updates.add(const RangeConcurrencySnapshot(7, 64));
    await tester.pump();
    expect(find.text('7'), findsOneWidget);

    await tester.tap(find.byTooltip('CDN 控制'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前线路.example'), findsOneWidget);
    expect(find.textContaining('7/64'), findsOneWidget);
    expect(find.textContaining('并发上限'), findsOneWidget);
    expect(find.textContaining('卡顿时切换'), findsOneWidget);
    expect(find.textContaining('默认 CDN：基础URL'), findsOneWidget);

    await tester.tap(find.text('备用URL'));
    await tester.pumpAndSettle();
    expect(selections, [CDNService.backupUrl]);
  });

  testWidgets('changing the limit and mode saves through the controls', (
    tester,
  ) async {
    final limits = <int>[];
    final modes = <CdnSwitchMode>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CdnControlButton(
            stream: const Stream<RangeConcurrencySnapshot>.empty(),
            initialSnapshot: const RangeConcurrencySnapshot(4, 64),
            currentCdn: () => 'cdn.example',
            accelerationStatus: () => '正在下载',
            selectedService: () => CDNService.baseUrl,
            maxConcurrency: () => 64,
            switchMode: () => CdnSwitchMode.manual,
            speedTest: false,
            onCdnSelected: (_) {},
            onConcurrencyLimitChanged: (value) async => limits.add(value),
            onSwitchModeChanged: (mode) async => modes.add(mode),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('CDN 控制'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(limits, isNotEmpty);
    expect(limits.last, greaterThan(64));

    await tester.tap(find.text('手动确认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动切换').last);
    await tester.pumpAndSettle();
    expect(modes, [CdnSwitchMode.automatic]);
  });

  testWidgets('reads settings changed in another entry when opened', (
    tester,
  ) async {
    var selectedService = CDNService.baseUrl;
    var switchMode = CdnSwitchMode.manual;
    var limit = 64;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CdnControlButton(
            stream: const Stream<RangeConcurrencySnapshot>.empty(),
            initialSnapshot: const RangeConcurrencySnapshot(0, 64),
            currentCdn: () => 'actual.example',
            accelerationStatus: () => '暂无分片请求',
            selectedService: () => selectedService,
            maxConcurrency: () => limit,
            switchMode: () => switchMode,
            speedTest: false,
            onCdnSelected: (_) {},
            onConcurrencyLimitChanged: (_) async {},
            onSwitchModeChanged: (_) async {},
          ),
        ),
      ),
    );

    selectedService = CDNService.backupUrl;
    switchMode = CdnSwitchMode.automatic;
    limit = 32;

    await tester.tap(find.byTooltip('CDN 控制'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前 CDN：actual.example'), findsOneWidget);
    expect(find.textContaining('暂无分片请求'), findsOneWidget);
    expect(find.textContaining('默认 CDN：备用URL'), findsOneWidget);
    expect(find.textContaining('并发上限：32 路'), findsOneWidget);
    expect(
      tester
          .widget<RadioGroup<CDNService>>(find.byType(RadioGroup<CDNService>))
          .groupValue,
      CDNService.backupUrl,
    );
    expect(
      tester
          .widget<DropdownButton<CdnSwitchMode>>(
            find.byType(DropdownButton<CdnSwitchMode>),
          )
          .value,
      CdnSwitchMode.automatic,
    );
  });
}
