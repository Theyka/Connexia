/// The running app's version.
///
/// Flutter populates `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER` from
/// `pubspec.yaml` at build time, so these constants always match the shipped
/// version without needing a plugin.
abstract final class AppVersion {
  static const String name = String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: 'dev',
  );

  static const String build = String.fromEnvironment(
    'FLUTTER_BUILD_NUMBER',
    defaultValue: '',
  );

  static String get label =>
      build.isEmpty ? 'Version $name' : 'Version $name ($build)';

  /// Parses `v1.2.3`, `1.2.3` or `1.2.3-rc1` into comparable numeric segments.
  /// Returns `null` when the value is not a dotted numeric version.
  static List<int>? parse(String value) {
    var text = value.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    // Drop pre-release / build metadata: 1.2.3-rc1+build -> 1.2.3.
    final cut = text.indexOf(RegExp(r'[-+]'));
    if (cut >= 0) text = text.substring(0, cut);
    if (text.isEmpty) return null;
    final segments = <int>[];
    for (final part in text.split('.')) {
      final n = int.tryParse(part);
      if (n == null) return null;
      segments.add(n);
    }
    return segments;
  }

  /// True when [latest] is strictly newer than [current]. Unparseable values
  /// (such as the `dev` fallback) never count as an update.
  static bool isNewer(String latest, String current) {
    final a = parse(latest);
    final b = parse(current);
    if (a == null || b == null) return false;
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final next = i < a.length ? a[i] : 0;
      final now = i < b.length ? b[i] : 0;
      if (next != now) return next > now;
    }
    return false;
  }
}
