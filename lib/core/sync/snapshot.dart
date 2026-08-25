import 'dart:convert';

import 'package:drift/drift.dart' as drift;

import '../db/database.dart';

/// Keys that must never leave the device through a snapshot.
const excludedSettingKeys = {
  'windowSize',
  'windowPosition',
  // Sync metadata (server url, last revision, etc.) is device-local.
  'syncServerUrl',
  'syncEmail',
  'syncUserId',
  'syncRevision',
  'syncLastPulledAt',
  'syncLastLocalWriteAt',
  'syncDirty',
  'syncLastPayloadHash',
};

/// A full, portable dump of every syncable table. Secrets (host passwords,
/// SSH keys) stay in their vault-encrypted form; the whole document is
/// encrypted again before upload.
class SyncSnapshotData {
  final List<Map<String, dynamic>> hosts;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> identities;
  final List<Map<String, dynamic>> knownHosts;
  final List<Map<String, dynamic>> snippets;
  final List<Map<String, dynamic>> sessionLogs;
  final List<Map<String, dynamic>> themes;
  final Map<String, String> settings;

  const SyncSnapshotData({
    required this.hosts,
    required this.groups,
    required this.identities,
    required this.knownHosts,
    required this.snippets,
    required this.sessionLogs,
    required this.themes,
    required this.settings,
  });

  bool get isEmpty =>
      hosts.isEmpty &&
      groups.isEmpty &&
      identities.isEmpty &&
      knownHosts.isEmpty &&
      snippets.isEmpty &&
      sessionLogs.isEmpty &&
      themes.isEmpty &&
      settings.isEmpty;

  /// Latest change timestamp across all rows, used for conflict resolution.
  DateTime get modifiedAt {
    DateTime? latest;
    void consider(Object? value) {
      if (value is String) {
        final parsed = DateTime.tryParse(value);
        if (parsed != null && (latest == null || parsed.isAfter(latest!))) {
          latest = parsed;
        }
      }
    }

    for (final host in hosts) {
      consider(host['lastConnected']);
    }
    for (final identity in identities) {
      consider(identity['createdAt']);
    }
    for (final knownHost in knownHosts) {
      consider(knownHost['firstSeen']);
      consider(knownHost['lastSeen']);
    }
    for (final snippet in snippets) {
      consider(snippet['createdAt']);
      consider(snippet['updatedAt']);
    }
    for (final sessionLog in sessionLogs) {
      consider(sessionLog['connectedAt']);
      consider(sessionLog['disconnectedAt']);
    }
    for (final theme in themes) {
      consider(theme['createdAt']);
    }
    return latest ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, dynamic> toJson() => {
        'hosts': hosts,
        'groups': groups,
        'identities': identities,
        'knownHosts': knownHosts,
        'snippets': snippets,
        'sessionLogs': sessionLogs,
        'themes': themes,
        'settings': settings,
      };

  static SyncSnapshotData fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> list(String key) =>
        (json[key] as List<dynamic>? ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    return SyncSnapshotData(
      hosts: list('hosts'),
      groups: list('groups'),
      identities: list('identities'),
      knownHosts: list('knownHosts'),
      snippets: list('snippets'),
      sessionLogs: list('sessionLogs'),
      themes: list('themes'),
      settings: Map<String, String>.from(json['settings'] as Map? ?? const {}),
    );
  }
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

int _int(Object? value, int fallback) =>
    value is int ? value : (value is num ? value.toInt() : fallback);

bool _bool(Object? value, bool fallback) =>
    value is bool ? value : fallback;

/// Serializes the personal scope (workspaceId IS NULL) of every syncable
/// table into a [SyncSnapshotData].
Future<SyncSnapshotData> exportSnapshot(AppDatabase db) async {
  final settings = await db.allSettings();
  return SyncSnapshotData(
    hosts: (await db.allHostsInScope(null)).map((h) => h.toJson()).toList(),
    groups: (await db.allGroupsInScope(null)).map((g) => g.toJson()).toList(),
    identities:
        (await db.allIdentitiesInScope(null)).map((i) => i.toJson()).toList(),
    knownHosts: (await db.allKnownHosts()).map((k) => k.toJson()).toList(),
    snippets: (await db.allSnippetsInScope(null)).map((s) => s.toJson()).toList(),
    sessionLogs: (await db.getSessionLogsUnbounded()).map((l) => l.toJson()).toList(),
    themes: (await db.allThemes()).map((t) => t.toJson()).toList(),
    settings: {
      for (final entry in settings)
        if (!excludedSettingKeys.contains(entry.key))
          entry.key: entry.value,
    },
  );
}

/// Serializes a single workspace scope. Only the four team-scoped tables are
/// included (hosts, groups, identities, snippets); the unscoped tables stay
/// empty and never travel in a workspace snapshot.
Future<SyncSnapshotData> exportWorkspaceSnapshot(
  AppDatabase db,
  String workspaceId,
) async {
  return SyncSnapshotData(
    hosts:
        (await db.allHostsInScope(workspaceId)).map((h) => h.toJson()).toList(),
    groups:
        (await db.allGroupsInScope(workspaceId)).map((g) => g.toJson()).toList(),
    identities: (await db.allIdentitiesInScope(workspaceId))
        .map((i) => i.toJson())
        .toList(),
    knownHosts: const [],
    snippets: (await db.allSnippetsInScope(workspaceId))
        .map((s) => s.toJson())
        .toList(),
    sessionLogs: const [],
    themes: const [],
    settings: const {},
  );
}

/// Replaces the personal scope with the snapshot, atomically.
///
/// Device-local settings ([excludedSettingKeys]) are preserved: they must
/// survive an import, otherwise the sync session (server url, account
/// email/user id) is silently lost and the next launch signs out.
Future<void> importSnapshot(AppDatabase db, SyncSnapshotData snapshot) async {
  final preserved = await db.allSettings();
  await db.transaction(() async {
    await db.clearPersonalForSync();
    await db.batch((batch) {
      _insertScoped(batch, db, snapshot, workspaceId: null);
      _insertUnscoped(batch, db, snapshot);
      for (final entry in preserved) {
        if (excludedSettingKeys.contains(entry.key)) {
          batch.insert(
            db.settingsTable,
            SettingsTableCompanion(
              key: drift.Value(entry.key),
              value: drift.Value(entry.value),
            ),
            mode: drift.InsertMode.insertOrReplace,
          );
        }
      }
    });
  });
}

/// Replaces one workspace scope with the snapshot, atomically. Unscoped
/// tables and other workspaces are untouched.
Future<void> importWorkspaceSnapshot(
  AppDatabase db,
  String workspaceId,
  SyncSnapshotData snapshot,
) async {
  await db.transaction(() async {
    await db.clearWorkspaceForSync(workspaceId);
    await db.batch((batch) {
      _insertScoped(batch, db, snapshot, workspaceId: workspaceId);
    });
  });
}

void _insertScoped(
  drift.Batch batch,
  AppDatabase db,
  SyncSnapshotData snapshot, {
  required String? workspaceId,
}) {
  for (final json in snapshot.hosts) {
    batch.insert(
      db.hosts,
      HostsCompanion(
        id: drift.Value(json['id'] as String),
        name: drift.Value((json['name'] ?? '') as String),
        address: drift.Value((json['address'] ?? '') as String),
        port: drift.Value(_int(json['port'], 22)),
        username: drift.Value((json['username'] ?? '') as String),
        authType: drift.Value((json['authType'] ?? 'password') as String),
        keyId: drift.Value(json['keyId'] as String?),
        encryptedPassword: drift.Value(json['encryptedPassword'] as String?),
        groupId: drift.Value(json['groupId'] as String?),
        tags: drift.Value((json['tags'] ?? '') as String),
        color: drift.Value(json['color'] as int?),
        notes: drift.Value((json['notes'] ?? '') as String),
        favorite: drift.Value(_bool(json['favorite'], false)),
        lastConnected: drift.Value(_date(json['lastConnected'])),
        os: drift.Value(json['os'] as String?),
        workspaceId: drift.Value(workspaceId),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
  for (final json in snapshot.groups) {
    batch.insert(
      db.groups,
      GroupsCompanion(
        id: drift.Value(json['id'] as String),
        name: drift.Value((json['name'] ?? '') as String),
        parentId: drift.Value(json['parentId'] as String?),
        color: drift.Value(json['color'] as int?),
        sortOrder: drift.Value(_int(json['sortOrder'], 0)),
        username: drift.Value(json['username'] as String?),
        authType: drift.Value(json['authType'] as String?),
        keyId: drift.Value(json['keyId'] as String?),
        encryptedPassword: drift.Value(json['encryptedPassword'] as String?),
        workspaceId: drift.Value(workspaceId),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
  for (final json in snapshot.identities) {
    batch.insert(
      db.identities,
      IdentitiesCompanion(
        id: drift.Value(json['id'] as String),
        name: drift.Value((json['name'] ?? '') as String),
        encryptedKeyPem: drift.Value(
          (json['encryptedKeyPem'] ?? '') as String,
        ),
        encryptedPassphrase: drift.Value(
          json['encryptedPassphrase'] as String?,
        ),
        comment: drift.Value((json['comment'] ?? '') as String),
        publicKey: drift.Value((json['publicKey'] ?? '') as String),
        certificate: drift.Value((json['certificate'] ?? '') as String),
        createdAt: drift.Value(_date(json['createdAt']) ?? DateTime.now()),
        workspaceId: drift.Value(workspaceId),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
  for (final json in snapshot.snippets) {
    batch.insert(
      db.snippets,
      SnippetsCompanion(
        id: drift.Value(json['id'] as String),
        title: drift.Value((json['title'] ?? '') as String),
        command: drift.Value((json['command'] ?? '') as String),
        createdAt: drift.Value(_date(json['createdAt']) ?? DateTime.now()),
        updatedAt: drift.Value(_date(json['updatedAt'])),
        workspaceId: drift.Value(workspaceId),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
}

void _insertUnscoped(
  drift.Batch batch,
  AppDatabase db,
  SyncSnapshotData snapshot,
) {
  for (final json in snapshot.knownHosts) {
    batch.insert(
      db.knownHosts,
      KnownHostsCompanion(
        hostKey: drift.Value(json['hostKey'] as String),
        keyType: drift.Value((json['keyType'] ?? '') as String),
        fingerprint: drift.Value((json['fingerprint'] ?? '') as String),
        firstSeen: drift.Value(_date(json['firstSeen']) ?? DateTime.now()),
        lastSeen: drift.Value(_date(json['lastSeen']) ?? DateTime.now()),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
  for (final json in snapshot.sessionLogs) {
    batch.insert(
      db.sessionLogs,
      SessionLogsCompanion(
        id: drift.Value(json['id'] as String),
        address: drift.Value((json['address'] ?? '') as String),
        username: drift.Value((json['username'] ?? '') as String),
        connectedAt: drift.Value(_date(json['connectedAt']) ?? DateTime.now()),
        disconnectedAt: drift.Value(_date(json['disconnectedAt'])),
        status: drift.Value((json['status'] ?? '') as String),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
  for (final json in snapshot.themes) {
    batch.insert(
      db.appThemes,
      AppThemesCompanion(
        id: drift.Value(json['id'] as String),
        name: drift.Value((json['name'] ?? '') as String),
        paletteJson: drift.Value((json['paletteJson'] ?? '{}') as String),
        createdAt: drift.Value(_date(json['createdAt']) ?? DateTime.now()),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
  for (final entry in snapshot.settings.entries) {
    batch.insert(
      db.settingsTable,
      SettingsTableCompanion(
        key: drift.Value(entry.key),
        value: drift.Value(entry.value),
      ),
      mode: drift.InsertMode.insertOrReplace,
    );
  }
}

/// The complete encrypted payload uploaded to the server.
class SyncPayload {
  final String format;
  final int version;
  final DateTime modifiedAt;
  final SyncSnapshotData data;

  const SyncPayload({
    required this.format,
    required this.version,
    required this.modifiedAt,
    required this.data,
  });

  String encode() => jsonEncode({
        'format': format,
        'version': version,
        'modifiedAt': modifiedAt.toIso8601String(),
        'data': data.toJson(),
      });

  static SyncPayload decode(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return SyncPayload(
      format: map['format'] as String,
      version: (map['version'] as num).toInt(),
      modifiedAt: DateTime.tryParse(map['modifiedAt'] as String? ?? '') ??
          DateTime.now(),
      data: SyncSnapshotData.fromJson(
        Map<String, dynamic>.from(map['data'] as Map),
      ),
    );
  }
}

SyncPayload buildPayload(SyncSnapshotData data, {DateTime? modifiedAt}) =>
    SyncPayload(
      format: 'connexia-sync',
      version: 1,
      modifiedAt: modifiedAt ?? data.modifiedAt,
      data: data,
    );
