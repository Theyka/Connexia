import 'package:connexia/core/db/database.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Tunnels table', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('insert and fetch round-trip preserves all fields', () async {
      final id = 't-1';
      await db.upsertTunnel(
        TunnelsCompanion(
          id: drift.Value(id),
          name: const drift.Value('Web tunnel'),
          hostId: const drift.Value('h-1'),
          type: const drift.Value('local'),
          bindAddress: const drift.Value('127.0.0.1'),
          bindPort: const drift.Value(8080),
          targetHost: const drift.Value('localhost'),
          targetPort: const drift.Value(80),
          autoStart: const drift.Value(true),
          color: const drift.Value(0xFF00AAFF),
          notes: const drift.Value('web dev proxy'),
          createdAt: drift.Value(DateTime.utc(2026, 8, 28, 12)),
        ),
      );

      final fetched = await db.findTunnelById(id);
      expect(fetched, isNotNull);
      expect(fetched!.name, 'Web tunnel');
      expect(fetched.type, 'local');
      expect(fetched.bindAddress, '127.0.0.1');
      expect(fetched.bindPort, 8080);
      expect(fetched.targetHost, 'localhost');
      expect(fetched.targetPort, 80);
      expect(fetched.autoStart, isTrue);
      expect(fetched.color, 0xFF00AAFF);
      expect(fetched.notes, 'web dev proxy');
      expect(fetched.workspaceId, isNull);
    });

    test('allTunnelsInScope filters by workspace id', () async {
      await db.upsertTunnel(
        TunnelsCompanion.insert(
          id: 'p',
          name: 'personal',
          type: 'dynamic',
          bindAddress: const drift.Value('127.0.0.1'),
          autoStart: const drift.Value(false),
          notes: const drift.Value(''),
          createdAt: drift.Value(DateTime.now()),
        ),
      );
      await db.upsertTunnel(
        TunnelsCompanion.insert(
          id: 'w',
          name: 'team',
          type: 'remote',
          bindAddress: const drift.Value('0.0.0.0'),
          autoStart: const drift.Value(false),
          notes: const drift.Value(''),
          createdAt: drift.Value(DateTime.now()),
          workspaceId: const drift.Value('ws-1'),
        ),
      );

      final personal = await db.allTunnelsInScope(null);
      final team = await db.allTunnelsInScope('ws-1');

      expect(personal.map((t) => t.id), contains('p'));
      expect(personal.map((t) => t.id), isNot(contains('w')));
      expect(team.map((t) => t.id), contains('w'));
      expect(team.map((t) => t.id), isNot(contains('p')));
    });

    test('deleteTunnel removes only the targeted row', () async {
      await db.upsertTunnel(
        TunnelsCompanion.insert(
          id: 'a',
          name: 'A',
          type: 'local',
          bindAddress: const drift.Value('127.0.0.1'),
          autoStart: const drift.Value(false),
          notes: const drift.Value(''),
          createdAt: drift.Value(DateTime.now()),
        ),
      );
      await db.upsertTunnel(
        TunnelsCompanion.insert(
          id: 'b',
          name: 'B',
          type: 'dynamic',
          bindAddress: const drift.Value('127.0.0.1'),
          autoStart: const drift.Value(false),
          notes: const drift.Value(''),
          createdAt: drift.Value(DateTime.now()),
        ),
      );

      await db.deleteTunnel('a');

      expect(await db.findTunnelById('a'), isNull);
      expect(await db.findTunnelById('b'), isNotNull);
    });
  });

  group('TunnelLogs table', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    TunnelLogsCompanion entry(String id, {String level = 'info'}) =>
        TunnelLogsCompanion.insert(
          id: id,
          tunnelId: 't-1',
          tunnelName: 'Web tunnel',
          tunnelType: 'local',
          level: level,
          message:
              level == 'error' ? 'SocketException: connection refused' : 'ok',
          createdAt: drift.Value(
            id == 'e1'
                ? DateTime(2026, 8, 29, 10)
                : DateTime(2026, 8, 29, 11),
          ),
        );

    test('insert, watch and clear round-trip', () async {
      await db.insertTunnelLog(entry('e1'));
      await db.insertTunnelLog(entry('e2', level: 'error'));

      final logs = await db.watchTunnelLogs().first;
      expect(logs, hasLength(2));
      // Newest first.
      expect(logs.first.id, 'e2');
      expect(logs.first.level, 'error');
      expect(logs.any((l) => l.level == 'error'), isTrue);

      await db.clearTunnelLogs();
      expect(await db.watchTunnelLogs().first, isEmpty);
    });

    test('table is pruned to the newest 500 entries', () async {
      for (var i = 0; i < 505; i++) {
        await db.insertTunnelLog(
          TunnelLogsCompanion.insert(
            id: 'e$i',
            tunnelId: 't-1',
            tunnelName: 'n',
            tunnelType: 'local',
            level: 'info',
            message: 'm$i',
            createdAt: drift.Value(DateTime(2026, 8, 29, 0, 0, i)),
          ),
        );
      }
      final logs = await db.watchTunnelLogs(limit: 1000).first;
      expect(logs.length, 500);
      // The oldest entries were pruned away.
      expect(logs.any((l) => l.id == 'e0'), isFalse);
      expect(logs.any((l) => l.id == 'e504'), isTrue);
    });
  });
}
