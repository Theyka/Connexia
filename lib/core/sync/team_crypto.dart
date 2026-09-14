import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'sync_crypto.dart';

class TeamCrypto {
  static Future<({String publicKey, String privateKey})>
  generateKeypair() async {
    final x = X25519();
    final kp = await x.newKeyPair();
    final pk = await kp.extractPublicKey();
    final sk = await kp.extractPrivateKeyBytes();
    return (publicKey: base64Encode(pk.bytes), privateKey: base64Encode(sk));
  }

  static Future<String> wrapPrivateKeyForStorage(
    String privateKeyB64,
    SecretKey syncKey,
  ) async {
    return SyncCrypto.encryptString(privateKeyB64, syncKey);
  }

  static Future<String> unwrapPrivateKeyFromStorage(
    String wrappedPrivateKey,
    SecretKey syncKey,
  ) async {
    return SyncCrypto.decryptString(wrappedPrivateKey, syncKey);
  }

  static Future<SecretKey> sharedSecret({
    required SimpleKeyPair keyPair,
    required String remotePublicKeyB64,
  }) async {
    final x = X25519();
    final remotePublic = SimplePublicKey(
      base64Decode(remotePublicKeyB64),
      type: KeyPairType.x25519,
    );
    return x.sharedSecretKey(keyPair: keyPair, remotePublicKey: remotePublic);
  }

  static Future<String> wrapWorkspaceKey({
    required String workspaceKeyB64,
    required SecretKey shared,
  }) async {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(workspaceKeyB64),
      secretKey: shared,
    );
    return base64Encode(box.concatenation());
  }

  static Future<String> unwrapWorkspaceKey({
    required String wrappedWorkspaceKey,
    required SecretKey shared,
  }) async {
    final box = SecretBox.fromConcatenation(
      base64Decode(wrappedWorkspaceKey),
      nonceLength: AesGcm.defaultNonceLength,
      macLength: AesGcm.aesGcmMac.macLength,
    );
    final clear = await AesGcm.with256bits().decrypt(box, secretKey: shared);
    return utf8.decode(clear);
  }

  static String generateWorkspaceKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Encode(bytes);
  }
}
