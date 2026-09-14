import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class SyncCrypto {
  static const int _iterations = 100000;

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

  static Future<String> encryptString(String plaintext, SecretKey key) async {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plaintext),
      secretKey: key,
    );
    return base64Encode(box.concatenation());
  }

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
