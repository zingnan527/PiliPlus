import 'package:PiliPlus/models/common/enum_with_label.dart';

/// Controls how the player responds when a CDN stall is detected.
///
/// The value is deliberately separate from the legacy boolean
/// `cdnStallRecovery` setting.  That setting could only express whether
/// recovery was enabled; this enum also lets the player wait for confirmation
/// or recover silently.
enum CdnSwitchMode implements EnumWithLabel {
  off('关闭', '只检测，不切换 CDN'),
  manual('手动确认', '检测到更合适的线路后，等待你确认'),
  automatic('自动切换', '检测到更合适的线路后，自动恢复并尽量保留进度'),
  ;

  @override
  final String label;
  final String description;

  const CdnSwitchMode(this.label, this.description);

  /// Converts the current and legacy persisted values to a safe mode.
  ///
  /// New versions persist [name] under the mode key.  Older versions stored
  /// only a boolean: `false` means [off], while `true` means [manual].  An
  /// absent or malformed value intentionally falls back to [manual], which
  /// preserves the old enabled-by-default behaviour without silently enabling
  /// automatic switching.
  static CdnSwitchMode fromStorage(
    Object? value, {
    Object? legacyValue,
  }) {
    if (value case final String name) {
      for (final mode in values) {
        if (mode.name == name) return mode;
      }
    }

    if (legacyValue case final bool enabled) {
      return enabled ? .manual : .off;
    }
    return .manual;
  }
}
