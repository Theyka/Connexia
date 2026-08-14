import 'package:drift/drift.dart' as drift;

import '../db/database.dart';

/// Trust-on-first-use store for SSH host keys.
class HostKeyStore {
  final AppDatabase _db;

  HostKeyStore(this._db);

  static String normalizeHostKey(String address, int port) => '$address:$port';

  /// Returns null if the host is unknown. Throws [HostKeyMismatchError] if the
  /// host is known but the presented key differs.
  Future<bool> isTrusted({
    required String address,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    final key = normalizeHostKey(address, port);
    final known = await _db.findKnownHost(key);
    if (known == null) return false;
    if (known.keyType != keyType || known.fingerprint != fingerprint) {
      throw HostKeyMismatchError(
        address: address,
        port: port,
        expectedType: known.keyType,
        expectedFingerprint: known.fingerprint,
        actualType: keyType,
        actualFingerprint: fingerprint,
      );
    }
    return true;
  }

  Future<void> trust({
    required String address,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    final key = normalizeHostKey(address, port);
    await _db.upsertKnownHost(
      KnownHostsCompanion.insert(
        hostKey: key,
        keyType: keyType,
        fingerprint: fingerprint,
        lastSeen: drift.Value(DateTime.now()),
      ),
    );
  }
}

class HostKeyMismatchError implements Exception {
  final String address;
  final int port;
  final String expectedType;
  final String expectedFingerprint;
  final String actualType;
  final String actualFingerprint;

  HostKeyMismatchError({
    required this.address,
    required this.port,
    required this.expectedType,
    required this.expectedFingerprint,
    required this.actualType,
    required this.actualFingerprint,
  });

  @override
  String toString() =>
      'Host key for $address:$port changed!\n'
      'Expected: $expectedType $expectedFingerprint\n'
      'Received: $actualType $actualFingerprint';
}
