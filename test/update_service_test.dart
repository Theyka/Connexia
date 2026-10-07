import 'dart:convert';
import 'dart:io';

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

  group('UpdateService.fetchLatest', () {
    test('requests the endpoint exactly once and parses the payload', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requested = <String>[];

      server.listen((request) async {
        requested.add(request.uri.path);
        if (request.uri.path == '/api/version') {
          request.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'version': '9.9.9',
                'tag': 'v9.9.9',
                'url': 'https://example/release',
                'notes': 'notes',
                'assets': {'macos': 'https://example/app.dmg'},
              }),
            );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final service = UpdateService();
      final endpoints = service.versionEndpoints(
        configuredServer: 'http://127.0.0.1:${server.port}/',
        fallbackServer: 'https://sync.connexia.run/',
      );
      // The configured server is reachable, so only it is queried.
      expect(endpoints.first, 'http://127.0.0.1:${server.port}/api/version');

      final release = await service.fetchLatest(endpoints.first);

      expect(release.version, '9.9.9');
      expect(release.assetFor('macos'), 'https://example/app.dmg');
      // Regression: the path must not be doubled to /api/version/api/version.
      expect(requested, ['/api/version']);
    });

    test('surfaces a non-200 response as an UpdateException', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      final service = UpdateService();
      await expectLater(
        service.fetchLatest('http://127.0.0.1:${server.port}/api/version'),
        throwsA(isA<UpdateException>()),
      );
    });
  });
}
