import 'dart:io';

import 'package:connexia/core/db/database.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Simulates a database created by an intermediate dev build whose table
/// classes were ahead of its schemaVersion: a fresh file is created with
/// every table in its *current* shape (workspace_id already present) but
/// `user_version` is stamped at [pinnedVersion].
class _PinnedVersionDb extends AppDatabase {
  final int pinnedVersion;

  _PinnedVersionDb(super.executor, this.pinnedVersion)
      : super.forTesting();

  @override
  int get schemaVersion => pinnedVersion;

  @override
  drift.MigrationStrategy get migration =>
      drift.MigrationStrategy(onCreate: (m) => m.createAll());
}

void main() {
  for (final from in [2, 4, 6, 7, 8]) {
    test('upgrade from v$from with current-shaped tables succeeds', () async {
      final dir = await Directory.systemTemp.createTemp('connexia_mig');
      addTearDown(() => dir.delete(recursive: true));
      final path =
          '${dir.path}${Platform.pathSeparator}migration_test.sqlite';

      // Seed: create all tables in their current shape, stamped at `from`.
      final seed = _PinnedVersionDb(NativeDatabase(File(path)), from);
      await seed.select(seed.appThemes).get();
      await seed.close();

      // Reopen with the real schemaVersion; this runs the full onUpgrade
      // chain. Before the idempotency guard this threw
      // "duplicate column name: workspace_id" (and friends).
      final db = AppDatabase.forTesting(NativeDatabase(File(path)));
      addTearDown(db.close);

      await db.into(db.hosts).insert(
            HostsCompanion.insert(
              id: 'h1',
              name: 'Host',
              address: 'example.com',
              username: 'root',
            ),
          );
      expect(await db.allHosts(), hasLength(1));

      await db.into(db.tunnels).insert(
            TunnelsCompanion.insert(
              id: 't1',
              name: 'Tunnel',
              type: 'local',
              bindAddress: const drift.Value('127.0.0.1'),
              autoStart: const drift.Value(false),
              notes: const drift.Value(''),
              createdAt: drift.Value(DateTime.now()),
            ),
          );
      expect(await db.allTunnels(), hasLength(1));
    });
  }
}
