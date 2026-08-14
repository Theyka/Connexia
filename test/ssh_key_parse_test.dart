import 'package:connexia/core/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const encryptedKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABB140+tav
7aDeJx5g2l/evkAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIFIVJJokuot3FuIk
85D0kj0nfXaVys2JImFvi20+iGypAAAAkAaaNoxcxTw7IhFENkJG8hOYcrpFs19NkZ2B2v
BQvQhESx6rmOgUOe68V0vJYbAQhnCX9OeINdgoxbIGC+Li3X5YwnxZTy/EiZZBJaa5tUBU
/SAeJD6DLQh/sL1rNSRmzuHb/+DVZNcZTBETDEVBsld/ZJu41JvUV4XyeHOnc2z3pVQ9L8
nHKKkCRklSWqHmpw==
-----END OPENSSH PRIVATE KEY-----''';

void main() {
  test('encrypted key round-trips through the isolate path', () async {
    final unlocked = unlockKeyPems([[encryptedKey], 'test-passphrase']);
    expect(unlocked, hasLength(1));
    expect(SSHKeyPair.isEncryptedPem(unlocked.single), isFalse);

    // This is exactly what the main thread does after the isolate: parsing
    // an unencrypted PEM with a null passphrase must not throw.
    final pairs = SSHKeyPair.fromPem(unlocked.single, null);
    expect(pairs, hasLength(1));
  });

  test('unencrypted keys parse with a null passphrase', () async {
    final pem = unlockKeyPems([[encryptedKey], 'test-passphrase']).single;
    final pairs = SSHKeyPair.fromPem(pem, null);
    expect(pairs.single.toPem(), contains('OPENSSH PRIVATE KEY'));
  });

  test('encrypted key without passphrase fails clearly', () {
    expect(
      () => unlockKeyPems([[encryptedKey], '']),
      throwsA(anything),
    );
  });
}
