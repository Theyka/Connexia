import 'package:connexia/core/crypto/secret_storage.dart';
import 'package:connexia/core/crypto/vault.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Vault', () {
    test('encrypts and decrypts round-trip', () async {
      final vault = Vault(InMemorySecretStorage());
      final plaintext = 'hunter2-secret-password';

      final ciphertext = await vault.encrypt(plaintext);
      expect(ciphertext, isNot(contains('hunter2')));

      final decrypted = await vault.decrypt(ciphertext);
      expect(decrypted, plaintext);
    });

    test('ciphertexts are unique per call (random nonce)', () async {
      final vault = Vault(InMemorySecretStorage());
      final a = await vault.encrypt('same-value');
      final b = await vault.encrypt('same-value');
      expect(a, isNot(b));
    });

    test('master key persists across instances', () async {
      final storage = InMemorySecretStorage();
      final vault1 = Vault(storage);
      final ciphertext = await vault1.encrypt('persisted-secret');

      final vault2 = Vault(storage);
      expect(await vault2.decrypt(ciphertext), 'persisted-secret');
    });

    test('throws on tampered ciphertext', () async {
      final vault = Vault(InMemorySecretStorage());
      final ciphertext = await vault.encrypt('data');
      final tampered = ciphertext.substring(0, ciphertext.length - 2) +
          (ciphertext.endsWith('AA') ? 'BB' : 'AA');

      expect(() => vault.decrypt(tampered), throwsA(anything));
    });

    test('decrypt of garbage throws', () async {
      final vault = Vault(InMemorySecretStorage());
      expect(() => vault.decrypt('not-base64!!'), throwsA(anything));
    });

    test('ciphertext from another device fails until key is adopted', () async {
      final pc = Vault(InMemorySecretStorage());
      final phone = Vault(InMemorySecretStorage());
      final ciphertext = await pc.encrypt('cross-device-secret');

      await expectLater(
        phone.decrypt(ciphertext),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      final pcKey = await pc.exportKey();
      expect(pcKey, isNotNull);
      await phone.adoptKey(pcKey!);
      expect(await phone.decrypt(ciphertext), 'cross-device-secret');
    });

    test('adoptKey persists across vault instances', () async {
      final phoneStorage = InMemorySecretStorage();
      final phone = Vault(phoneStorage);
      final other = Vault(InMemorySecretStorage());
      await other.encrypt('generate-a-key');
      final otherKey = await other.exportKey();
      expect(otherKey, isNotNull);
      await phone.adoptKey(otherKey!);

      final restarted = Vault(phoneStorage);
      expect(await restarted.exportKey(), otherKey);
    });

    test('adoptKey rejects malformed keys', () async {
      final vault = Vault(InMemorySecretStorage());
      await expectLater(vault.adoptKey('dG9vc2hvcnQ='), throwsA(anything));
      await expectLater(vault.adoptKey('not-base64!!'), throwsA(anything));
    });
  });
}
