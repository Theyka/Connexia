import 'package:connexia/core/db/database.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _insertHost(AppDatabase db, String id, String address) {
  return db.upsertHost(
    HostsCompanion.insert(
      id: id,
      name: 'Host $id',
      address: address,
      username: 'root',
      port: drift.Value(22),
    ),
  );
}

void main() {
  group('hosts ordering', () {
    test('hosts are listed most-recently-connected first', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _insertHost(db, 'a', '10.0.0.1');
      await _insertHost(db, 'b', '10.0.0.2');
      await _insertHost(db, 'c', '10.0.0.3');

      await db.updateHostLastConnected('b', DateTime(2026, 8, 1, 10));
      await db.updateHostLastConnected('c', DateTime(2026, 8, 2, 10));

      final hosts = await db.allHosts();
      expect(hosts.map((h) => h.id).toList(), ['c', 'b', 'a'],
          reason: 'most recently connected hosts must come first, '
              'never-connected hosts last');
    });

    test('a fresh connection moves the host to the first place', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _insertHost(db, 'a', '10.0.0.1');
      await _insertHost(db, 'b', '10.0.0.2');
      await db.updateHostLastConnected('b', DateTime(2026, 8, 1, 10));

      // Host A connects now -> must jump above B.
      await db.updateHostLastConnected('a', DateTime(2026, 8, 10, 10));

      final hosts = await db.allHosts();
      expect(hosts.map((h) => h.id).toList(), ['a', 'b']);
    });

    test('updateHostLastConnectedByAddress matches by address and port',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await _insertHost(db, 'a', '10.0.0.1');
      await db.upsertHost(
        HostsCompanion.insert(
          id: 'b',
          name: 'Host b',
          address: '10.0.0.1',
          username: 'root',
          port: drift.Value(2222),
        ),
      );

      await db.updateHostLastConnectedByAddress(
        '10.0.0.1',
        22,
        DateTime(2026, 8, 10, 10),
      );

      final hosts = await db.allHosts();
      expect(hosts.first.id, 'a',
          reason: 'only the host with the matching port gets bumped');
      expect(hosts.first.lastConnected, isNotNull);
      expect(hosts.last.lastConnected, isNull);
    });
  });
}
