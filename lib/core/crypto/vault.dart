import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'secret_storage.dart';

/// Encrypts secrets at rest using AES-256-GCM. A random 256-bit master key is
/// generated on first use and held in the platform secret storage. Each
/// ciphertext is stored as base64(nonce || ciphertext || mac).
class Vault {
  static const String _masterKeyKey = 'connexia_master_key_v1';

  final SecretStorage _storage;
  Uint8List? _masterKey;

  Vault(this._storage);

  Future<Uint8List> _ensureMasterKey() async {
    final cached = _masterKey;
    if (cached != null) return cached;

    final stored = await _storage.read(_masterKeyKey);
    if (stored != null) {
      _masterKey = base64Decode(stored);
      return _masterKey!;
    }

    final random = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await _storage.write(_masterKeyKey, base64Encode(key));
    _masterKey = key;
    return key;
  }

  /// Base64-encoded master key currently in use, or null when no key has
  /// been generated on this device yet.
  Future<String?> exportKey() async {
    final stored = await _storage.read(_masterKeyKey);
    if (stored == null) return null;
    _masterKey = base64Decode(stored);
    return stored;
  }

  /// Replaces the master key with one generated on another device. Used by
  /// cloud sync so vault-encrypted secrets stay readable across devices
  /// sharing an account.
  Future<void> adoptKey(String base64Key) async {
    final key = base64Decode(base64Key);
    if (key.length != 32) {
      throw ArgumentError('Vault master key must be 32 bytes');
    }
    _masterKey = key;
    await _storage.write(_masterKeyKey, base64Key);
  }

  Future<String> encrypt(String plaintext) async {
    final key = SecretKey(await _ensureMasterKey());
    final secretBox = await AesGcm.with256bits().encrypt(
      utf8.encode(plaintext),
      secretKey: key,
    );
    return base64Encode(secretBox.concatenation());
  }

  Future<String> decrypt(String ciphertext) async {
    final key = SecretKey(await _ensureMasterKey());
    final secretBox = SecretBox.fromConcatenation(
      base64Decode(ciphertext),
      nonceLength: AesGcm.defaultNonceLength,
      macLength: AesGcm.aesGcmMac.macLength,
    );
    final clearText = await AesGcm.with256bits().decrypt(
      secretBox,
      secretKey: key,
    );
    return utf8.decode(clearText);
  }
}
