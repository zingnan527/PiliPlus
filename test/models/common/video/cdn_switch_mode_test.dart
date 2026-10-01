import 'package:PiliPlus/models/common/video/cdn_switch_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CdnSwitchMode.fromStorage', () {
    test('uses a persisted mode when it is valid', () {
      expect(
        CdnSwitchMode.fromStorage('automatic'),
        CdnSwitchMode.automatic,
      );
      expect(CdnSwitchMode.fromStorage('manual'), CdnSwitchMode.manual);
      expect(CdnSwitchMode.fromStorage('off'), CdnSwitchMode.off);
    });

    test('migrates the legacy boolean without enabling automation', () {
      expect(
        CdnSwitchMode.fromStorage(null, legacyValue: true),
        CdnSwitchMode.manual,
      );
      expect(
        CdnSwitchMode.fromStorage(null, legacyValue: false),
        CdnSwitchMode.off,
      );
    });

    test('defaults to manual for missing or malformed values', () {
      expect(CdnSwitchMode.fromStorage(null), CdnSwitchMode.manual);
      expect(
        CdnSwitchMode.fromStorage('unknown', legacyValue: 'true'),
        CdnSwitchMode.manual,
      );
    });
  });
}
