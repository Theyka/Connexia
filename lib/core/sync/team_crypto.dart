import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'sync_crypto.dart';

/// Per-account X25519 keypair used to wrap the workspace data key for each
/// member of a team workspace.
///
/// The server stores only the public key (and the private key wrapped under
/// the user's password-derived sync key). To wrap a workspace key for a
/// member, the inviter derives a shared secret with the member's public key
/// and uses it to AES-GCM-encrypt the workspace key. The member unwraps by
/// deriving the same shared secret with their own private key and the
/// inviter's public key. This avoids any plaintext key ever leaving the
/// client, keeping the zero-knowledge property of the sync server intact.
class TeamCrypto {
  /// Generates a fresh X25519 keypair. Returns the base64-encoded public key
  /// and the base64-encoded private key (raw bytes).
  static Future<({String publicKey, String privateKey})> generateKeypair() async {
    final x = X25519();
    final kp = await x.newKeyPair();
    final pk = await kp.extractPublicKey();
    final sk = await kp.extractPrivateKeyBytes();
    return (
      publicKey: base64Encode(pk.bytes),
      privateKey: base64Encode(sk),
    );
  }

  /// Wraps the private key bytes with the user's password-derived sync key
  /// (AES-256-GCM via [SyncCrypto.encryptString]) so the server can store
  /// it without ever seeing the plaintext.
  static Future<String> wrapPrivateKeyForStorage(
    String privateKeyB64,
    SecretKey syncKey,
  ) async {
    return SyncCrypto.encryptString(privateKeyB64, syncKey);
  }

  /// Unwraps the stored private key using the password-derived sync key.
  static Future<String> unwrapPrivateKeyFromStorage(
    String wrappedPrivateKey,
    SecretKey syncKey,
  ) async {
    return SyncCrypto.decryptString(wrappedPrivateKey, syncKey);
  }

  /// Derives a 256-bit shared secret between [keyPair] and [remotePublicKeyB64].
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

  /// Wraps the workspace data key (base64) under a shared secret.
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

  /// Unwraps a workspace key (base64) using a shared secret.
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

  /// Generates a fresh 256-bit workspace data key (base64).
  static String generateWorkspaceKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Encode(bytes);
  }
}
