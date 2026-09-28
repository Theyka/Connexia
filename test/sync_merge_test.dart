import 'package:connexia/core/db/database.dart';
import 'package:connexia/core/sync/snapshot.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _host(String id, {String name = 'Host'}) => {
  'id': id,
  'name': name,
  'address': '192.168.1.5',
  'port': 22,
  'username': 'tester',
  'authType': 'password',
  'keyId': null,
  'encryptedPassword': null,
  'groupId': null,
  'tags': '',
  'color': null,
  'notes': '',
  'favorite': false,
  'lastConnected': null,
  'os': null,
  'protocol': 'ssh',
  'domain': null,
};

SyncSnapshotData _snapshot({
  List<Map<String, dynamic>> hosts = const [],
  Map<String, String> settings = const {},
}) => SyncSnapshotData(
  hosts: hosts,
  groups: const [],
  identities: const [],
  knownHosts: const [],
  snippets: const [],
  sessionLogs: const [],
  themes: const [],
  tunnels: const [],
  metrics: const [],
  settings: settings,
);

String _ids(SyncSnapshotData s) =>
    (s.hosts.map((h) => h['id'] as String).toList()..sort()).join(',');

void main() {
  group('mergeSnapshots', () {
    test('preserves additions made independently on both devices', () {
      final base = _snapshot();
      final local = _snapshot(hosts: [_host('a')]);
      final remote = _snapshot(hosts: [_host('b')]);
      final merged = mergeSnapshots(
        base: base,
        local: local,
        remote: remote,
      ).merged;
      expect(_ids(merged), 'a,b');
    });

    test('keeps a local edit when the remote did not change the row', () {
      final base = _snapshot(hosts: [_host('a', name: 'Old')]);
      final local = _snapshot(hosts: [_host('a', name: 'Local')]);
      final remote = base;
      final merged = mergeSnapshots(
        base: base,
        local: local,
        remote: remote,
      ).merged;
      expect(merged.hosts.single['name'], 'Local');
    });

    test('keeps a remote edit when the local did not change the row', () {
      final base = _snapshot(hosts: [_host('a', name: 'Old')]);
      final local = base;
      final remote = _snapshot(hosts: [_host('a', name: 'Remote')]);
      final merged = mergeSnapshots(
        base: base,
        local: local,
        remote: remote,
      ).merged;
      expect(merged.hosts.single['name'], 'Remote');
    });

    test('resolves competing edits deterministically (remote wins)', () {
      final base = _snapshot(hosts: [_host('a', name: 'Old')]);
      final local = _snapshot(hosts: [_host('a', name: 'Local')]);
      final remote = _snapshot(hosts: [_host('a', name: 'Remote')]);
      final merged = mergeSnapshots(
        base: base,
        local: local,
        remote: remote,
      ).merged;
      expect(merged.hosts.single['name'], 'Remote');
    });

    test('propagates a deletion made by the remote', () {
      final base = _snapshot(hosts: [_host('a'), _host('b')]);
      final local = base;
      final remote = _snapshot(hosts: [_host('a')]); // remote deleted b
      final result = mergeSnapshots(base: base, local: local, remote: remote);
      expect(_ids(result.merged), 'a');
      expect(result.deletions['hosts'], contains('b'));
    });

    test('keeps a locally deleted row deleted when remote is unchanged', () {
      final base = _snapshot(hosts: [_host('a')]);
      final local = _snapshot();
      final remote = base;
      final result = mergeSnapshots(base: base, local: local, remote: remote);
      expect(result.merged.hosts, isEmpty);
    });

    test('does not resurrect a row deleted on both sides', () {
      final base = _snapshot(hosts: [_host('a')]);
      final local = _snapshot();
      final remote = _snapshot();
      final result = mergeSnapshots(base: base, local: local, remote: remote);
      expect(result.merged.hosts, isEmpty);
      expect(result.deletions['hosts'], isNull);
    });

    test('merges independent settings changes', () {
      final base = _snapshot(settings: {'a': '1', 'b': '1'});
      final local = _snapshot(settings: {'a': '2', 'b': '1'});
      final remote = _snapshot(settings: {'a': '1', 'b': '2'});
      final merged = mergeSnapshots(
        base: base,
        local: local,
        remote: remote,
      ).merged;
      expect(merged.settings['a'], '2');
      expect(merged.settings['b'], '2');
    });

    test('treats an empty base as a union', () {
      final local = _snapshot(
        hosts: [_host('a')],
        settings: {'x': '1'},
      );
      final remote = _snapshot(
        hosts: [_host('b')],
        settings: {'y': '2'},
      );
      final merged = mergeSnapshots(
        base: SyncSnapshotData.empty(),
        local: local,
        remote: remote,
      ).merged;
      expect(_ids(merged), 'a,b');
      expect(merged.settings['x'], '1');
      expect(merged.settings['y'], '2');
    });
  });

  group('snapshotsEqual', () {
    test('is order-insensitive', () {
      final a = _snapshot(hosts: [_host('a'), _host('b')]);
      final b = _snapshot(hosts: [_host('b'), _host('a')]);
      expect(snapshotsEqual(a, b), isTrue);
    });

    test('detects differing rows', () {
      final a = _snapshot(hosts: [_host('a', name: 'One')]);
      final b = _snapshot(hosts: [_host('a', name: 'Two')]);
      expect(snapshotsEqual(a, b), isFalse);
    });
  });

  group('applyMergedSnapshot', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('upserts merged rows and applies deletions', () async {
      await db.upsertHost(
        HostsCompanion.insert(
          id: 'a',
          name: 'A',
          address: '10.0.0.1',
          username: 'u',
        ),
      );
      await db.upsertHost(
        HostsCompanion.insert(
          id: 'b',
          name: 'B',
          address: '10.0.0.2',
          username: 'u',
        ),
      );

      final merged = _snapshot(
        hosts: [_host('a', name: 'A-merged'), _host('c')],
      );
      await applyMergedSnapshot(
        db,
        merged,
        deletions: {
          'hosts': {'b'},
        },
      );

      final hosts = await db.allHostsInScope(null);
      final ids = hosts.map((h) => h.id).toList()..sort();
      expect(ids, ['a', 'c']);
      expect(hosts.firstWhere((h) => h.id == 'a').name, 'A-merged');
    });
  });
}
