import 'package:PiliPlus/pages/video/widgets/cdn_switch_suggestion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('requires a tap to switch and dismisses after ten seconds', (
    tester,
  ) async {
    var switched = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CdnSwitchSuggestion(
          currentHost: 'slow.example',
          targetHost: 'fast.example',
          targetBytesPerSecond: 2.5 * 1000 * 1000,
          targetTtfb: const Duration(milliseconds: 45),
          improvementPercent: 80,
          onSwitch: () => switched += 1,
          onDismiss: () => dismissed += 1,
        ),
      ),
    );

    expect(find.textContaining('fast.example'), findsOneWidget);
    expect(find.textContaining('快约 80%'), findsOneWidget);
    expect(find.text('切换 10s'), findsOneWidget);
    expect(switched, 0);

    await tester.pump(const Duration(seconds: 10));
    expect(switched, 0);
    expect(dismissed, 1);
  });

  testWidgets('switches only after the user taps the button', (tester) async {
    var switched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CdnSwitchSuggestion(
          currentHost: 'slow.example',
          targetHost: 'fast.example',
          targetBytesPerSecond: 2.5 * 1000 * 1000,
          targetTtfb: const Duration(milliseconds: 45),
          improvementPercent: null,
          onSwitch: () => switched += 1,
          onDismiss: () {},
        ),
      ),
    );

    await tester.tap(find.text('切换 10s'));
    expect(switched, 1);
  });
}
