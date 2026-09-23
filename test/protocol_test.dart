import 'package:connexia/core/db/database.dart';
import 'package:connexia/core/host_protocol.dart';
import 'package:connexia/core/sync/snapshot.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HostProtocol', () {
    test('parses known ids and falls back to ssh', () {
      expect(HostProtocol.fromId('ssh'), HostProtocol.ssh);
      expect(HostProtocol.fromId('telnet'), HostProtocol.telnet);
      expect(HostProtocol.fromId('rdp'), HostProtocol.rdp);
      expect(HostProtocol.fromId('vnc'), HostProtocol.vnc);
      expect(HostProtocol.fromId('bogus'), HostProtocol.ssh);
      expect(HostProtocol.fromId(null), HostProtocol.ssh);
    });

    test('default ports and categories', () {
      expect(HostProtocol.ssh.defaultPort, 22);
      expect(HostProtocol.telnet.defaultPort, 23);
      expect(HostProtocol.rdp.defaultPort, 3389);
      expect(HostProtocol.vnc.defaultPort, 5900);

      expect(HostProtocol.ssh.isText, isTrue);
      expect(HostProtocol.telnet.isText, isTrue);
      expect(HostProtocol.rdp.isGraphical, isTrue);
      expect(HostProtocol.vnc.isGraphical, isTrue);
      expect(HostProtocol.ssh.isEncrypted, isTrue);
      expect(HostProtocol.telnet.isEncrypted, isFalse);
    });
  });

  group('snapshot protocol round-trip', () {
    Future<void> importHost(Map<String, dynamic> host) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await importSnapshot(
        db,
        SyncSnapshotData.fromJson({
          'hosts': [host],
        }),
      );
      final stored = await db.findHostById(host['id'] as String);
      expect(stored, isNotNull);
      expect(stored!.protocol, host['protocol'] ?? 'ssh');
      expect(stored.domain, host['domain']);
    }

    test('preserves protocol and domain', () async {
      await importHost({
        'id': 'h1',
        'name': 'Windows box',
        'address': '10.0.0.5',
        'port': 3389,
        'username': 'admin',
        'protocol': 'rdp',
        'domain': 'CORP',
      });
    });

    test('older payloads without protocol default to ssh', () async {
      final snap = SyncSnapshotData.fromJson({
        'hosts': [
          {
            'id': 'h2',
            'name': 'Legacy',
            'address': '10.0.0.6',
            'username': 'root',
          },
        ],
      });
      expect(snap.formatVersion, 1);
      await importHost(snap.hosts.first);
    });
  });

  test('importing a newer snapshot format is refused', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final futureSnap = SyncSnapshotData.fromJson({
      'formatVersion': currentSyncFormatVersion + 1,
      'hosts': const [],
    });
    expect(() => importSnapshot(db, futureSnap), throwsStateError);
  });
}
