import 'package:connexia/core/db/database.dart';
import 'package:connexia/core/sync/snapshot.dart';
import 'package:connexia/core/sync/sync_crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncCrypto', () {
    test('derives the same key from the same password and user', () async {
      final a = await SyncCrypto.deriveKey('hunter2secret', 'user-1');
      final b = await SyncCrypto.deriveKey('hunter2secret', 'user-1');
      expect(await a.extractBytes(), await b.extractBytes());
    });

    test('derives different keys for different passwords/users', () async {
      final a = await SyncCrypto.deriveKey('hunter2secret', 'user-1');
      final b = await SyncCrypto.deriveKey('hunter2secret', 'user-2');
      final c = await SyncCrypto.deriveKey('different-password', 'user-1');
      expect(await a.extractBytes(), isNot(await b.extractBytes()));
      expect(await a.extractBytes(), isNot(await c.extractBytes()));
    });

    test('encrypt/decrypt round trip hides the plaintext', () async {
      final key = await SyncCrypto.deriveKey('hunter2secret', 'user-1');
      final plaintext = '{"hosts":[{"id":"h1"}]}';
      final cipher = await SyncCrypto.encryptString(plaintext, key);
      expect(cipher, isNot(contains('h1')));
      expect(await SyncCrypto.decryptString(cipher, key), plaintext);
    });

    test('decrypting with the wrong key fails', () async {
      final key = await SyncCrypto.deriveKey('hunter2secret', 'user-1');
      final wrong = await SyncCrypto.deriveKey('wrong-password', 'user-1');
      final cipher = await SyncCrypto.encryptString('secret data', key);
      expect(() => SyncCrypto.decryptString(cipher, wrong), throwsA(anything));
    });
  });

  group('SyncSnapshot', () {
    test('payload encodes and decodes losslessly', () {
      final data = SyncSnapshotData(
        hosts: [
          {
            'id': 'h1',
            'name': 'Server',
            'address': '192.168.1.5',
            'port': 22,
            'username': 'tester',
            'authType': 'password',
            'keyId': null,
            'encryptedPassword': 'abc==',
            'groupId': null,
            'tags': '',
            'color': null,
            'notes': '',
            'favorite': false,
            'lastConnected': '2026-08-01T10:00:00.000',
            'os': 'linux',
          },
        ],
        groups: const [],
        identities: const [],
        knownHosts: const [],
        snippets: const [],
        sessionLogs: const [],
        themes: const [],
        tunnels: const [],
        metrics: const [],
        settings: const {'terminalTheme': 'Default'},
      );
      final payload = buildPayload(data);
      final roundTrip = SyncPayload.decode(payload.encode());
      expect(roundTrip.format, 'connexia-sync');
      expect(roundTrip.data.hosts.length, 1);
      expect(roundTrip.data.hosts.first['name'], 'Server');
      expect(roundTrip.data.settings['terminalTheme'], 'Default');
      expect(roundTrip.data.modifiedAt, DateTime(2026, 8, 1, 10));
    });

    test('modifiedAt reflects the newest row timestamp', () {
      final data = SyncSnapshotData(
        hosts: const [],
        groups: const [],
        identities: [
          {'id': 'i1', 'createdAt': '2026-07-01T00:00:00.000'},
        ],
        knownHosts: const [
          {
            'hostKey': 'k',
            'firstSeen': '2026-07-02T00:00:00.000',
            'lastSeen': '2026-08-05T00:00:00.000',
          },
        ],
        snippets: const [],
        sessionLogs: const [],
        themes: const [],
        tunnels: const [],
        metrics: const [],
        settings: const {},
      );
      expect(data.modifiedAt, DateTime(2026, 8, 5));
      expect(data.isEmpty, isFalse);
    });

    test('setting exclusion list never leaks device-local keys', () {
      expect(excludedSettingKeys, contains('windowSize'));
      expect(excludedSettingKeys, contains('windowPosition'));
      expect(excludedSettingKeys, contains('syncServerUrl'));
      expect(excludedSettingKeys, contains('syncEmail'));
      expect(excludedSettingKeys, contains('syncUserId'));
      expect(excludedSettingKeys, contains('syncRevision'));
      expect(excludedSettingKeys, contains('syncDirty'));
      expect(excludedSettingKeys, contains('syncLastPayloadHash'));
    });
  });

  group('importSnapshot', () {
    test(
      'preserves device-local settings while replacing syncable ones',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await db.setSetting('syncServerUrl', 'http://192.168.1.35:8047');
        await db.setSetting('syncEmail', 'mail@example.com');
        await db.setSetting('terminalTheme', 'OldTheme');

        final snapshot = SyncSnapshotData(
          hosts: const [],
          groups: const [],
          identities: const [],
          knownHosts: const [],
          snippets: const [],
          sessionLogs: const [],
          themes: const [],
          tunnels: const [],
          metrics: const [],
          settings: const {
            'terminalTheme': 'NewTheme',
            'autoAcceptHostKeys': 'ask',
          },
        );

        await importSnapshot(db, snapshot);

        expect(
          await db.getSetting('syncServerUrl'),
          'http://192.168.1.35:8047',
        );
        expect(await db.getSetting('syncEmail'), 'mail@example.com');
        expect(await db.getSetting('terminalTheme'), 'NewTheme');
        expect(await db.getSetting('autoAcceptHostKeys'), 'ask');
      },
    );

    test(
      'metric rows merge by host and timestamp without losing data',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await db.insertHostMetric(
          HostMetricsCompanion.insert(
            hostId: 'h1',
            ts: DateTime.utc(2026, 9, 1, 10),
            memPct: 10.0,
          ),
        );

        final snapshot = SyncSnapshotData(
          hosts: const [],
          groups: const [],
          identities: const [],
          knownHosts: const [],
          snippets: const [],
          sessionLogs: const [],
          themes: const [],
          tunnels: const [],
          metrics: [
            {'hostId': 'h1', 'ts': '2026-09-01T10:00:00.000Z', 'memPct': 42.0},
            {'hostId': 'h1', 'ts': '2026-09-01T10:05:00.000Z', 'memPct': 55.0},
          ],
          settings: const {},
        );

        await importSnapshot(db, snapshot);

        final history = await db.hostMetricsHistory('h1');
        expect(history.length, 2);
        final kept = history.firstWhere(
          (r) =>
              r.ts
                  .difference(DateTime.utc(2026, 9, 1, 10))
                  .inMilliseconds
                  .abs() <=
              1,
        );
        expect(kept.memPct, 10.0);
        final added = history.firstWhere(
          (r) => r.memPct == 55.0,
          orElse: () => throw StateError('missing imported row'),
        );
        expect(
          added.ts.isAtSameMomentAs(DateTime.utc(2026, 9, 1, 10, 5)),
          isTrue,
        );
      },
    );

    test('export keeps only rows inside the 3-day retention window', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      final now = DateTime.now();
      final oldTs = now.subtract(const Duration(days: 4));
      final recentTs = now.subtract(const Duration(hours: 1));

      await db.insertHostMetric(
        HostMetricsCompanion.insert(hostId: 'h1', ts: oldTs, memPct: 1.0),
      );
      await db.insertHostMetric(
        HostMetricsCompanion.insert(hostId: 'h1', ts: recentTs, memPct: 2.0),
      );
      await db.insertSessionLog(
        SessionLogsCompanion.insert(
          id: 'old',
          address: 'a',
          username: 'tester',
          connectedAt: oldTs,
        ),
      );
      await db.insertSessionLog(
        SessionLogsCompanion.insert(
          id: 'new',
          address: 'a',
          username: 'tester',
          connectedAt: recentTs,
        ),
      );

      final snap = await exportSnapshot(db);
      expect(snap.metrics.length, 1);
      expect(snap.metrics.first['ts'] != null, isTrue);
      expect(
        (snap.metrics.first['ts'] as String).contains(
          recentTs.toIso8601String().substring(0, 16),
        ),
        isTrue,
      );
      expect(snap.sessionLogs.length, 1);
      expect(snap.sessionLogs.first['id'], 'new');
    });

    test(
      'import preserves logs older than 3 days, replaces newer ones',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        final now = DateTime.now();
        final oldTs = now.subtract(const Duration(days: 4));
        await db.insertSessionLog(
          SessionLogsCompanion.insert(
            id: 'old',
            address: 'a',
            username: 'tester',
            connectedAt: oldTs,
          ),
        );
        await db.insertSessionLog(
          SessionLogsCompanion.insert(
            id: 'pending',
            address: 'a',
            username: 'tester',
            connectedAt: now.subtract(const Duration(hours: 1)),
          ),
        );

        final snapshot = SyncSnapshotData(
          hosts: const [],
          groups: const [],
          identities: const [],
          knownHosts: const [],
          snippets: const [],
          sessionLogs: [
            {
              'id': 'remote',
              'address': 'b',
              'username': 'tester',
              'connectedAt': now
                  .subtract(const Duration(hours: 2))
                  .toIso8601String(),
            },
          ],
          themes: const [],
          tunnels: const [],
          metrics: const [],
          settings: const {},
        );
        await importSnapshot(db, snapshot);

        final all = await db.getSessionLogsUnbounded();
        final ids = all.map((l) => l.id).toSet();
        expect(ids.contains('old'), isTrue);
        expect(ids.contains('remote'), isTrue);
        expect(ids.contains('pending'), isFalse);
      },
    );
  });
}
