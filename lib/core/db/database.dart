import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

class Groups extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()();
  IntColumn get color => integer().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get username => text().nullable()();
  TextColumn get authType => text().nullable()();
  TextColumn get keyId => text().nullable()();
  TextColumn get encryptedPassword => text().nullable()();

  TextColumn get workspaceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Hosts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get address => text()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get username => text()();
  TextColumn get authType => text().withDefault(const Constant('password'))();
  TextColumn get keyId => text().nullable()();
  TextColumn get encryptedPassword => text().nullable()();
  TextColumn get groupId => text().nullable()();
  TextColumn get tags => text().withDefault(const Constant(''))();
  IntColumn get color => integer().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastConnected => dateTime().nullable()();
  TextColumn get os => text().nullable()();

  TextColumn get workspaceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Identities extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get encryptedKeyPem => text()();
  TextColumn get encryptedPassphrase => text().nullable()();
  TextColumn get comment => text().withDefault(const Constant(''))();
  TextColumn get publicKey => text().withDefault(const Constant(''))();
  TextColumn get certificate => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  TextColumn get workspaceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class KnownHosts extends Table {
  TextColumn get hostKey => text()();
  TextColumn get keyType => text()();
  TextColumn get fingerprint => text()();
  DateTimeColumn get firstSeen => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastSeen => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {hostKey};
}

class SettingsTable extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class Snippets extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get command => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get updatedAt => dateTime().nullable()();

  TextColumn get workspaceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SessionLogs extends Table {
  TextColumn get id => text()();
  TextColumn get address => text()();
  TextColumn get username => text()();
  DateTimeColumn get connectedAt => dateTime()();
  DateTimeColumn get disconnectedAt => dateTime().nullable()();
  TextColumn get status => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

class AppThemes extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get paletteJson => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

class Tunnels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  TextColumn get hostId => text().nullable()();

  TextColumn get type => text()();

  TextColumn get address => text().nullable()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get username => text().nullable()();

  TextColumn get authType => text().nullable()();
  TextColumn get keyId => text().nullable()();
  TextColumn get encryptedPassword => text().nullable()();

  TextColumn get bindAddress =>
      text().withDefault(const Constant('127.0.0.1'))();

  IntColumn get bindPort => integer().nullable()();

  TextColumn get targetHost => text().nullable()();
  IntColumn get targetPort => integer().nullable()();

  BoolColumn get autoStart => boolean().withDefault(const Constant(false))();
  IntColumn get color => integer().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  TextColumn get workspaceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class TunnelLogs extends Table {
  TextColumn get id => text()();
  TextColumn get tunnelId => text()();
  TextColumn get tunnelName => text()();

  TextColumn get tunnelType => text()();

  TextColumn get level => text()();
  TextColumn get message => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

class HostMetrics extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hostId => text()();
  DateTimeColumn get ts => dateTime()();

  RealColumn get cpuPct => real().nullable()();
  RealColumn get memPct => real()();

  RealColumn get memUsedMb => real().nullable()();
  RealColumn get memTotalMb => real().nullable()();

  RealColumn get diskPct => real().nullable()();
  RealColumn get diskUsedGb => real().nullable()();
  RealColumn get diskTotalGb => real().nullable()();

  RealColumn get netRx => real().nullable()();
  RealColumn get netTx => real().nullable()();

  RealColumn get netRxCum => real().nullable()();
  RealColumn get netTxCum => real().nullable()();
  RealColumn get load1 => real().nullable()();
  RealColumn get load5 => real().nullable()();
  RealColumn get load15 => real().nullable()();

  RealColumn get temp => real().nullable()();
  IntColumn get procCount => integer().nullable()();
  IntColumn get uptimeSec => integer().nullable()();

  TextColumn get sysInfo => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Groups,
    Hosts,
    Identities,
    KnownHosts,
    SettingsTable,
    Snippets,
    SessionLogs,
    AppThemes,
    Tunnels,
    TunnelLogs,
    HostMetrics,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'connexia'));

  @visibleForTesting
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await _addColumnIfMissing(m, groups, groups.username);
        await _addColumnIfMissing(m, groups, groups.authType);
        await _addColumnIfMissing(m, groups, groups.keyId);
        await _addColumnIfMissing(m, groups, groups.encryptedPassword);
        await m.createTable(snippets);
        await m.createTable(sessionLogs);
      }
      if (from < 3) {
        await _addColumnIfMissing(m, identities, identities.publicKey);
        await _addColumnIfMissing(m, identities, identities.certificate);
      }
      if (from < 4) {
        final hasOldSchema = await customSelect(
          "SELECT 1 FROM pragma_table_info('snippets') "
          "WHERE name = 'name'",
        ).getSingleOrNull();
        if (hasOldSchema != null) {
          await m.renameColumn(snippets, 'name', snippets.title);
          await m.renameColumn(snippets, 'content', snippets.command);
        }
      }
      if (from < 5) {
        final hasUpdatedAt = await customSelect(
          "SELECT 1 FROM pragma_table_info('snippets') "
          "WHERE name = 'updated_at'",
        ).getSingleOrNull();
        if (hasUpdatedAt == null) {
          await m.addColumn(snippets, snippets.updatedAt);
        }
      }
      if (from < 6) {
        await _addColumnIfMissing(m, hosts, hosts.os);
      }
      if (from < 7) {
        await m.createTable(appThemes);
      }
      if (from < 8) {
        await _addColumnIfMissing(m, hosts, hosts.workspaceId);
        await _addColumnIfMissing(m, groups, groups.workspaceId);
        await _addColumnIfMissing(m, identities, identities.workspaceId);
        await _addColumnIfMissing(m, snippets, snippets.workspaceId);
      }
      if (from < 9) {
        await m.createTable(tunnels);
      }
      if (from < 10) {
        await m.createTable(tunnelLogs);
      }
      if (from < 11) {
        await m.createTable(hostMetrics);
      }
    },
  );

  Future<void> _addColumnIfMissing(
    Migrator m,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    final present = await customSelect(
      "SELECT 1 FROM pragma_table_info('${table.actualTableName}') "
      "WHERE name = '${column.name}'",
    ).getSingleOrNull();
    if (present == null) {
      await m.addColumn(table, column);
    }
  }

  Future<List<Host>> allHosts() => (select(
    hosts,
  )..orderBy([(t) => OrderingTerm.desc(t.lastConnected)])).get();
  Stream<List<Host>> watchHosts() => (select(
    hosts,
  )..orderBy([(t) => OrderingTerm.desc(t.lastConnected)])).watch();

  Future<List<Host>> allHostsInScope(String? workspaceId) async {
    final q = select(hosts)
      ..orderBy([(t) => OrderingTerm.desc(t.lastConnected)]);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.get();
  }

  Stream<List<Host>> watchHostsInScope(String? workspaceId) {
    final q = select(hosts)
      ..orderBy([(t) => OrderingTerm.desc(t.lastConnected)]);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.watch();
  }

  Future<List<Group>> allGroupsInScope(String? workspaceId) async {
    final q = select(groups);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.get();
  }

  Stream<List<Group>> watchGroupsInScope(String? workspaceId) {
    final q = select(groups);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.watch();
  }

  Future<List<Identity>> allIdentitiesInScope(String? workspaceId) async {
    final q = select(identities);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.get();
  }

  Stream<List<Identity>> watchIdentitiesInScope(String? workspaceId) {
    final q = select(identities);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.watch();
  }

  Future<List<Snippet>> allSnippetsInScope(String? workspaceId) async {
    final q = select(snippets);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.get();
  }

  Stream<List<Snippet>> watchSnippetsInScope(String? workspaceId) {
    final q = select(snippets);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.watch();
  }

  Future<List<Group>> allGroups() => select(groups).get();
  Stream<List<Group>> watchGroups() => select(groups).watch();
  Future<List<Identity>> allIdentities() => select(identities).get();
  Stream<List<Identity>> watchIdentities() => select(identities).watch();

  Future<void> upsertHost(HostsCompanion entry) =>
      into(hosts).insertOnConflictUpdate(entry);
  Future<void> deleteHost(String id) =>
      (delete(hosts)..where((t) => t.id.equals(id))).go();
  Future<void> updateHostLastConnected(String id, DateTime time) =>
      (update(hosts)..where((t) => t.id.equals(id))).write(
        HostsCompanion(lastConnected: Value(time)),
      );

  Future<void> updateHostLastConnectedByAddress(
    String address,
    int port,
    DateTime time,
  ) async {
    final matches =
        await (select(hosts)
              ..where((t) => t.address.equals(address) & t.port.equals(port))
              ..limit(1))
            .get();
    if (matches.isEmpty) return;
    await updateHostLastConnected(matches.first.id, time);
  }

  Future<void> updateHostOsByAddress(
    String address,
    int port,
    String os,
  ) async {
    final matches =
        await (select(hosts)
              ..where((t) => t.address.equals(address) & t.port.equals(port))
              ..limit(1))
            .get();
    if (matches.isEmpty) return;
    await (update(hosts)..where((t) => t.id.equals(matches.first.id))).write(
      HostsCompanion(os: Value(os)),
    );
  }

  Future<void> upsertGroup(GroupsCompanion entry) =>
      into(groups).insertOnConflictUpdate(entry);
  Future<void> deleteGroup(String id) =>
      (delete(groups)..where((t) => t.id.equals(id))).go();
  Future<void> deleteHostsInGroup(String groupId) =>
      (delete(hosts)..where((t) => t.groupId.equals(groupId))).go();

  Future<void> upsertIdentity(IdentitiesCompanion entry) =>
      into(identities).insertOnConflictUpdate(entry);
  Future<void> deleteIdentity(String id) =>
      (delete(identities)..where((t) => t.id.equals(id))).go();
  Future<Identity?> findIdentityById(String id) =>
      (select(identities)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<Host?> findHostById(String id) =>
      (select(hosts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertKnownHost(KnownHostsCompanion entry) =>
      into(knownHosts).insertOnConflictUpdate(entry);
  Future<KnownHost?> findKnownHost(String hostKey) => (select(
    knownHosts,
  )..where((t) => t.hostKey.equals(hostKey))).getSingleOrNull();
  Stream<List<KnownHost>> watchKnownHosts() => select(knownHosts).watch();
  Future<List<KnownHost>> allKnownHosts() => select(knownHosts).get();
  Future<void> deleteKnownHost(String hostKey) =>
      (delete(knownHosts)..where((t) => t.hostKey.equals(hostKey))).go();

  Future<String?> getSetting(String key) async {
    final row = await (select(
      settingsTable,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<String> databaseFilePath() async {
    final rows = await customSelect('PRAGMA database_list').get();
    for (final row in rows) {
      if (row.data['name'] == 'main') {
        return row.data['file'] as String;
      }
    }
    throw StateError('No main database file found');
  }

  Future<Map<String, int>> tableRowCounts() async {
    final tables = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ).get();
    final counts = <String, int>{};
    for (final table in tables) {
      final name = table.data['name'] as String;
      final row = await customSelect(
        'SELECT COUNT(*) AS c FROM "$name"',
      ).getSingle();
      counts[name] = row.data['c'] as int;
    }
    return counts;
  }

  Future<void> setSetting(String key, String value) =>
      into(settingsTable).insertOnConflictUpdate(
        SettingsTableCompanion.insert(key: key, value: value),
      );

  Future<List<SettingsTableData>> allSettings() => select(settingsTable).get();

  Future<List<SessionLog>> getSessionLogsUnbounded() => (select(
    sessionLogs,
  )..orderBy([(t) => OrderingTerm.asc(t.connectedAt)])).get();

  Future<void> clearPersonalForSync({DateTime? sessionLogCutoff}) async {
    if (sessionLogCutoff != null) {
      await (delete(
        sessionLogs,
      )..where((t) => t.connectedAt.isBiggerThanValue(sessionLogCutoff))).go();
    } else {
      await delete(sessionLogs).go();
    }
    await (delete(snippets)..where((t) => t.workspaceId.isNull())).go();
    await delete(knownHosts).go();
    await (delete(identities)..where((t) => t.workspaceId.isNull())).go();
    await (delete(hosts)..where((t) => t.workspaceId.isNull())).go();
    await (delete(groups)..where((t) => t.workspaceId.isNull())).go();
    await (delete(tunnels)..where((t) => t.workspaceId.isNull())).go();
    await delete(appThemes).go();
    await delete(settingsTable).go();
  }

  Future<void> clearWorkspaceForSync(String workspaceId) async {
    await (delete(
      snippets,
    )..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(
      identities,
    )..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(hosts)..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(
      groups,
    )..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(
      tunnels,
    )..where((t) => t.workspaceId.equals(workspaceId))).go();
  }

  Future<List<Snippet>> allSnippets() => select(snippets).get();
  Stream<List<Snippet>> watchSnippets() => select(snippets).watch();
  Future<void> upsertSnippet(SnippetsCompanion entry) =>
      into(snippets).insertOnConflictUpdate(entry);
  Future<void> deleteSnippet(String id) =>
      (delete(snippets)..where((t) => t.id.equals(id))).go();

  Stream<List<SessionLog>> watchSessionLogs() => select(sessionLogs).watch();
  Future<List<SessionLog>> getSessionLogs({int limit = 50, int offset = 0}) =>
      (select(sessionLogs)
            ..orderBy([(t) => OrderingTerm.desc(t.connectedAt)])
            ..limit(limit, offset: offset))
          .get();
  Future<int> countSessionLogs() => sessionLogs.count().getSingle();
  Future<void> clearSessionLogs() => delete(sessionLogs).go();
  Future<void> insertSessionLog(SessionLogsCompanion entry) =>
      into(sessionLogs).insert(entry);
  Future<void> endSessionLog(String id, DateTime endedAt) =>
      (update(sessionLogs)..where((t) => t.id.equals(id))).write(
        SessionLogsCompanion(disconnectedAt: Value(endedAt)),
      );

  Future<void> endStaleSessionLogs() async {
    await (update(sessionLogs)..where((t) => t.disconnectedAt.isNull())).write(
      SessionLogsCompanion(disconnectedAt: Value(DateTime.now())),
    );
  }

  Stream<List<AppTheme>> watchThemes() => select(appThemes).watch();
  Future<List<AppTheme>> allThemes() => select(appThemes).get();
  Future<AppTheme?> findThemeById(String id) =>
      (select(appThemes)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> upsertTheme(AppThemesCompanion entry) =>
      into(appThemes).insertOnConflictUpdate(entry);
  Future<void> deleteTheme(String id) =>
      (delete(appThemes)..where((t) => t.id.equals(id))).go();

  Stream<List<Tunnel>> watchTunnels() => select(tunnels).watch();
  Future<List<Tunnel>> allTunnels() => select(tunnels).get();
  Future<Tunnel?> findTunnelById(String id) =>
      (select(tunnels)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> upsertTunnel(TunnelsCompanion entry) =>
      into(tunnels).insertOnConflictUpdate(entry);
  Future<void> deleteTunnel(String id) =>
      (delete(tunnels)..where((t) => t.id.equals(id))).go();

  Future<List<Tunnel>> allTunnelsInScope(String? workspaceId) async {
    final q = select(tunnels);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.get();
  }

  Stream<List<Tunnel>> watchTunnelsInScope(String? workspaceId) {
    final q = select(tunnels);
    if (workspaceId == null) {
      q.where((t) => t.workspaceId.isNull());
    } else {
      q.where((t) => t.workspaceId.equals(workspaceId));
    }
    return q.watch();
  }

  Future<void> insertTunnelLog(
    TunnelLogsCompanion entry, {
    int keep = 500,
  }) async {
    await into(tunnelLogs).insert(entry, mode: InsertMode.insertOrReplace);
    await customStatement(
      'DELETE FROM tunnel_logs WHERE id IN (SELECT id FROM tunnel_logs '
      'ORDER BY created_at DESC LIMIT -1 OFFSET ?)',
      [keep],
    );
  }

  Stream<List<TunnelLog>> watchTunnelLogs({int limit = 300}) =>
      (select(tunnelLogs)
            ..orderBy([(u) => OrderingTerm.desc(u.createdAt)])
            ..limit(limit))
          .watch();

  Future<int> countTunnelLogs() async {
    final count = countAll();
    final query = selectOnly(tunnelLogs)..addColumns([count]);
    final row = await query.getSingleOrNull();
    return row?.read(count) ?? 0;
  }

  Future<void> clearTunnelLogs() => delete(tunnelLogs).go();

  Future<void> insertHostMetric(
    HostMetricsCompanion entry, {
    int keep = 6000,
  }) async {
    await into(hostMetrics).insert(entry);
    await pruneHostMetrics(entry.hostId.value, keep: keep);
  }

  Future<List<HostMetric>> hostMetricsHistory(
    String hostId, {
    int limit = 6000,
  }) =>
      (select(hostMetrics)
            ..where((t) => t.hostId.equals(hostId))
            ..orderBy([(t) => OrderingTerm.desc(t.ts)])
            ..limit(limit))
          .get();

  Future<void> clearHostMetrics(String hostId) =>
      (delete(hostMetrics)..where((t) => t.hostId.equals(hostId))).go();

  Future<List<HostMetric>> hostMetricsForSync({int limitPerHost = 600}) async {
    final rows = await customSelect(
      'SELECT DISTINCT host_id FROM host_metrics',
    ).get();
    final out = <HostMetric>[];
    for (final row in rows) {
      final hostId = row.data['host_id'] as String;
      out.addAll(await hostMetricsHistory(hostId, limit: limitPerHost));
    }
    return out;
  }

  Future<Map<String, int>> hostMetricIdsByHostTs(
    Iterable<String> hostIds,
  ) async {
    final list = hostIds.where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return const {};
    final rows = await (select(
      hostMetrics,
    )..where((t) => t.hostId.isIn(list))).get();
    return {
      for (final r in rows) '${r.hostId}|${r.ts.millisecondsSinceEpoch}': r.id,
    };
  }

  Future<void> pruneHostMetrics(String hostId, {int keep = 6000}) =>
      customStatement(
        'DELETE FROM host_metrics WHERE id IN (SELECT id FROM host_metrics '
        'WHERE host_id = ? ORDER BY ts DESC LIMIT -1 OFFSET ?)',
        [hostId, keep],
      );
}
