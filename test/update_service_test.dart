import 'package:connexia/core/update/app_version.dart';
import 'package:connexia/core/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppVersion.parse', () {
    test('parses plain and v-prefixed versions', () {
      expect(AppVersion.parse('1.2.3'), [1, 2, 3]);
      expect(AppVersion.parse('v0.4.3'), [0, 4, 3]);
      expect(AppVersion.parse('1.0'), [1, 0]);
    });

    test('drops pre-release and build metadata', () {
      expect(AppVersion.parse('1.2.3-rc1'), [1, 2, 3]);
      expect(AppVersion.parse('1.2.3+build.7'), [1, 2, 3]);
      expect(AppVersion.parse('v1.2.3-rc1+build.7'), [1, 2, 3]);
    });

    test('rejects non-numeric versions', () {
      expect(AppVersion.parse('dev'), isNull);
      expect(AppVersion.parse(''), isNull);
      expect(AppVersion.parse('v'), isNull);
      expect(AppVersion.parse('1.x.3'), isNull);
    });
  });

  group('AppVersion.isNewer', () {
    test('detects newer patch, minor and major versions', () {
      expect(AppVersion.isNewer('0.4.3', '0.4.2'), isTrue);
      expect(AppVersion.isNewer('0.5.0', '0.4.9'), isTrue);
      expect(AppVersion.isNewer('1.0.0', '0.9.9'), isTrue);
    });

    test('is false for equal or older versions', () {
      expect(AppVersion.isNewer('0.4.3', '0.4.3'), isFalse);
      expect(AppVersion.isNewer('0.4.2', '0.4.3'), isFalse);
      expect(AppVersion.isNewer('1.0.0', '1.0'), isFalse);
    });

    test('treats missing trailing segments as zero', () {
      expect(AppVersion.isNewer('1.0.1', '1.0'), isTrue);
      expect(AppVersion.isNewer('1.0', '1.0.0'), isFalse);
    });

    test('never counts an unparseable version as an update', () {
      expect(AppVersion.isNewer('dev', '0.4.3'), isFalse);
      expect(AppVersion.isNewer('0.4.3', 'dev'), isFalse);
    });
  });

  group('ReleaseInfo', () {
    test('parses the server payload', () {
      final release = ReleaseInfo.fromJson({
        'version': '0.4.3',
        'tag': 'v0.4.3',
        'url': 'https://example/release',
        'notes': 'hello',
        'assets': {
          'windows': 'https://example/setup.exe',
          'macos': 'https://example/app.dmg',
          'bogus': 42,
        },
      });

      expect(release.version, '0.4.3');
      expect(release.assetFor('windows'), 'https://example/setup.exe');
      expect(release.assetFor('linux'), isNull);
      // Non-string values are ignored rather than crashing.
      expect(release.assets.containsKey('bogus'), isFalse);
    });

    test('tolerates missing fields', () {
      final release = ReleaseInfo.fromJson(const {});
      expect(release.version, '');
      expect(release.notes, '');
      expect(release.assets, isEmpty);
    });
  });

  group('UpdateService.versionEndpoints', () {
    test('prefers the configured server and falls back to the default', () {
      final service = UpdateService();
      final urls = service.versionEndpoints(
        configuredServer: 'https://my.server/',
        fallbackServer: 'https://sync.connexia.run/',
      );
      expect(urls, [
        'https://my.server/api/version',
        'https://sync.connexia.run/api/version',
      ]);
    });

    test('de-duplicates when the configured server is the default', () {
      final service = UpdateService();
      final urls = service.versionEndpoints(
        configuredServer: 'https://sync.connexia.run',
        fallbackServer: 'https://sync.connexia.run/',
      );
      expect(urls, ['https://sync.connexia.run/api/version']);
    });

    test('skips an empty configured server', () {
      final service = UpdateService();
      final urls = service.versionEndpoints(
        configuredServer: '',
        fallbackServer: 'https://sync.connexia.run/',
      );
      expect(urls, ['https://sync.connexia.run/api/version']);
    });
  });
}
