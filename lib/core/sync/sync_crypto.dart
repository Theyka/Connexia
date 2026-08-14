import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Key derivation + envelope encryption for cloud sync.
///
/// The snapshot is encrypted with AES-256-GCM under a key derived from the
/// user's password (PBKDF2-HMAC-SHA256). The server only ever sees the
/// ciphertext and can never recover the plaintext.
class SyncCrypto {
  static const int _iterations = 100000;

  /// Derives the 256-bit data key from the account password. The user id
  /// is used as salt so two different accounts never share a key.
  static Future<SecretKey> deriveKey(String password, String userId) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: utf8.encode('connexia-sync-v1:$userId'),
    );
  }

  /// Encrypts a UTF-8 snapshot into base64(nonce || ciphertext || mac).
  static Future<String> encryptString(String plaintext, SecretKey key) async {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plaintext),
      secretKey: key,
    );
    return base64Encode(box.concatenation());
  }

  /// Decrypts base64(nonce || ciphertext || mac). Throws on wrong key.
  static Future<String> decryptString(String ciphertext, SecretKey key) async {
    final box = SecretBox.fromConcatenation(
      base64Decode(ciphertext),
      nonceLength: AesGcm.defaultNonceLength,
      macLength: AesGcm.aesGcmMac.macLength,
    );
    final clear = await AesGcm.with256bits().decrypt(box, secretKey: key);
    return utf8.decode(clear);
  }
}
