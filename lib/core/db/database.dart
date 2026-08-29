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
  /// Null = personal scope; otherwise the owning workspace id (team sync).
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
  /// Null = personal scope; otherwise the owning workspace id (team sync).
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
  /// Null = personal scope; otherwise the owning workspace id (team sync).
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
  // Nullable because SQLite cannot ALTER TABLE ADD COLUMN with a
  // non-constant default; the app always writes updatedAt explicitly.
  DateTimeColumn get updatedAt => dateTime().nullable()();
  /// Null = personal scope; otherwise the owning workspace id (team sync).
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

/// User-defined UI color AppThemes. The palette is stored as a JSON object;
/// selecting a theme is persisted in the settings table under `appTheme`.
class AppThemes extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get paletteJson => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// SSH tunnel configurations: local (-L), dynamic SOCKS (-D) and remote
/// (-R) port forwards. A tunnel can either reference an existing host (the
/// common case — reuse its credentials) or carry inline credentials for
/// ad-hoc use.
class Tunnels extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  /// Null = use the linked host's credentials; otherwise inline override.
  TextColumn get hostId => text().nullable()();
  /// 'local' | 'dynamic' | 'remote'.
  TextColumn get type => text()();

  // Connection overrides (used when hostId is null).
  TextColumn get address => text().nullable()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get username => text().nullable()();
  /// 'password' | 'key'. Only consulted when hostId is null.
  TextColumn get authType => text().nullable()();
  TextColumn get keyId => text().nullable()();
  TextColumn get encryptedPassword => text().nullable()();

  // Forward rule fields.
  TextColumn get bindAddress =>
      text().withDefault(const Constant('127.0.0.1'))();
  /// Null means "let the OS pick" (only valid for local/dynamic binds).
  IntColumn get bindPort => integer().nullable()();
  /// Local forward only: target host:port on the remote side.
  TextColumn get targetHost => text().nullable()();
  IntColumn get targetPort => integer().nullable()();

  BoolColumn get autoStart =>
      boolean().withDefault(const Constant(false))();
  IntColumn get color => integer().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
  /// Null = personal scope; otherwise the owning workspace id (team sync).
  TextColumn get workspaceId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Device-local diagnostic events for SSH tunnels (start/stop/errors).
/// Never leaves the machine — deliberately not part of the sync snapshot.
class TunnelLogs extends Table {
  TextColumn get id => text()();
  TextColumn get tunnelId => text()();
  TextColumn get tunnelName => text()();
  /// 'local' | 'dynamic' | 'remote'.
  TextColumn get tunnelType => text()();
  /// 'info' | 'error'.
  TextColumn get level => text()();
  TextColumn get message => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(driftDatabase(name: 'connexia'));

  /// Test-only constructor so tests can run against an in-memory database.
  @visibleForTesting
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 10;

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
            // A v1 database already created `snippets` with the current
            // schema inside the `from < 2` step, so only migrate when the
            // old column names are still present.
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
            // DBs created between v2 and v4 never received `updated_at`
            // because the v4 step only added it when the pre-v2 column
            // names were present. Add it whenever it is missing so saving
            // a snippet stops failing with "no column named updated_at".
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
            // Team sync: scope the four syncable entity tables to either the
            // personal scope (NULL) or a workspace id.
            await _addColumnIfMissing(m, hosts, hosts.workspaceId);
            await _addColumnIfMissing(m, groups, groups.workspaceId);
            await _addColumnIfMissing(m, identities, identities.workspaceId);
            await _addColumnIfMissing(m, snippets, snippets.workspaceId);
          }
          if (from < 9) {
            // SSH tunnels table.
            await m.createTable(tunnels);
          }
          if (from < 10) {
            // Device-local tunnel diagnostic events.
            await m.createTable(tunnelLogs);
          }
        },
      );

  /// Adds [column] to [table] only when it is not already present.
  ///
  /// Databases created by intermediate dev builds can carry columns whose
  /// addition postdates their stored `user_version`; a plain
  /// [Migrator.addColumn] would then fail with "duplicate column name".
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

  /// Hosts are listed most-recently-connected first; hosts that have never
  /// been connected to stay at the bottom in insertion order.
  Future<List<Host>> allHosts() => (select(hosts)
        ..orderBy([(t) => OrderingTerm.desc(t.lastConnected)]))
      .get();
  Stream<List<Host>> watchHosts() => (select(hosts)
        ..orderBy([(t) => OrderingTerm.desc(t.lastConnected)]))
      .watch();

  /// Scoped variants for team sync. Pass [workspaceId] = null for personal
  /// scope, or a workspace id for team-scoped queries.
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
      (update(hosts)..where((t) => t.id.equals(id)))
          .write(HostsCompanion(lastConnected: Value(time)));

  /// Records [time] on the saved host matching [address]:[port]. Used when a
  /// session connects without knowing the host id (e.g. after a reconnect).
  Future<void> updateHostLastConnectedByAddress(
    String address,
    int port,
    DateTime time,
  ) async {
    final matches = await (select(hosts)
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
    final matches = await (select(hosts)
          ..where((t) => t.address.equals(address) & t.port.equals(port))
          ..limit(1))
        .get();
    if (matches.isEmpty) return;
    await (update(hosts)..where((t) => t.id.equals(matches.first.id)))
        .write(HostsCompanion(os: Value(os)));
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
  Future<KnownHost?> findKnownHost(String hostKey) =>
      (select(knownHosts)..where((t) => t.hostKey.equals(hostKey))).getSingleOrNull();
  Stream<List<KnownHost>> watchKnownHosts() => select(knownHosts).watch();
  Future<List<KnownHost>> allKnownHosts() => select(knownHosts).get();
  Future<void> deleteKnownHost(String hostKey) =>
      (delete(knownHosts)..where((t) => t.hostKey.equals(hostKey))).go();

  Future<String?> getSetting(String key) async {
    final row = await (select(settingsTable)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
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
      final row = await customSelect('SELECT COUNT(*) AS c FROM "$name"')
          .getSingle();
      counts[name] = row.data['c'] as int;
    }
    return counts;
  }

  Future<void> setSetting(String key, String value) =>
      into(settingsTable).insertOnConflictUpdate(
        SettingsTableCompanion.insert(key: key, value: value),
      );

  Future<List<SettingsTableData>> allSettings() => select(settingsTable).get();

  /// Every session log row, oldest first (used by cloud sync export).
  Future<List<SessionLog>> getSessionLogsUnbounded() =>
      (select(sessionLogs)..orderBy([(t) => OrderingTerm.asc(t.connectedAt)]))
          .get();

  /// Empties every personal-scope row (workspaceId IS NULL) of the scoped
  /// tables plus all rows of the unscoped tables, so a personal snapshot can
  /// be imported atomically without touching workspace data.
  Future<void> clearPersonalForSync() async {
    await delete(sessionLogs).go();
    await (delete(snippets)..where((t) => t.workspaceId.isNull())).go();
    await delete(knownHosts).go();
    await (delete(identities)..where((t) => t.workspaceId.isNull())).go();
    await (delete(hosts)..where((t) => t.workspaceId.isNull())).go();
    await (delete(groups)..where((t) => t.workspaceId.isNull())).go();
    await (delete(tunnels)..where((t) => t.workspaceId.isNull())).go();
    await delete(appThemes).go();
    await delete(settingsTable).go();
  }

  /// Empties every row belonging to a workspace scope (the five scoped
  /// tables only; unscoped tables are shared and untouched).
  Future<void> clearWorkspaceForSync(String workspaceId) async {
    await (delete(snippets)..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(identities)..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(hosts)..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(groups)..where((t) => t.workspaceId.equals(workspaceId))).go();
    await (delete(tunnels)..where((t) => t.workspaceId.equals(workspaceId))).go();
  }

  Future<List<Snippet>> allSnippets() => select(snippets).get();
  Stream<List<Snippet>> watchSnippets() => select(snippets).watch();
  Future<void> upsertSnippet(SnippetsCompanion entry) =>
      into(snippets).insertOnConflictUpdate(entry);
  Future<void> deleteSnippet(String id) =>
      (delete(snippets)..where((t) => t.id.equals(id))).go();

  Stream<List<SessionLog>> watchSessionLogs() => select(sessionLogs).watch();
  Future<List<SessionLog>> getSessionLogs({
    int limit = 50,
    int offset = 0,
  }) =>
      (select(sessionLogs)
            ..orderBy([(t) => OrderingTerm.desc(t.connectedAt)])
            ..limit(limit, offset: offset))
          .get();
  Future<int> countSessionLogs() => sessionLogs.count().getSingle();
  Future<void> clearSessionLogs() => delete(sessionLogs).go();
  Future<void> insertSessionLog(SessionLogsCompanion entry) =>
      into(sessionLogs).insert(entry);
  Future<void> endSessionLog(String id, DateTime endedAt) =>
      (update(sessionLogs)..where((t) => t.id.equals(id)))
          .write(SessionLogsCompanion(disconnectedAt: Value(endedAt)));

  /// Closes every log that never got a disconnect timestamp. Called on app
  /// startup: a fresh process cannot have live sessions, so any still-active
  /// entry is stale (the previous run ended without logging, e.g. crash or
  /// force quit).
  Future<void> endStaleSessionLogs() async {
    await (update(sessionLogs)..where((t) => t.disconnectedAt.isNull()))
        .write(SessionLogsCompanion(disconnectedAt: Value(DateTime.now())));
  }

  Stream<List<AppTheme>> watchThemes() => select(appThemes).watch();
  Future<List<AppTheme>> allThemes() => select(appThemes).get();
  Future<AppTheme?> findThemeById(String id) =>
      (select(appThemes)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> upsertTheme(AppThemesCompanion entry) =>
      into(appThemes).insertOnConflictUpdate(entry);
  Future<void> deleteTheme(String id) =>
      (delete(appThemes)..where((t) => t.id.equals(id))).go();

  // ---------- Tunnels ----------

  Stream<List<Tunnel>> watchTunnels() => select(tunnels).watch();
  Future<List<Tunnel>> allTunnels() => select(tunnels).get();
  Future<Tunnel?> findTunnelById(String id) =>
      (select(tunnels)..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> upsertTunnel(TunnelsCompanion entry) =>
      into(tunnels).insertOnConflictUpdate(entry);
  Future<void> deleteTunnel(String id) =>
      (delete(tunnels)..where((t) => t.id.equals(id))).go();

  /// Scoped variants for team sync.
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

  // ---------- Tunnel logs (device-local diagnostics) ----------

  /// Inserts an event and prunes the table to the newest [keep] entries so
  /// it can never grow unbounded.
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
}
