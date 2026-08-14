import 'package:connexia/core/ssh/host_key_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HostKeyStore', () {
    test('normalizeHostKey combines address and port', () {
      expect(HostKeyStore.normalizeHostKey('example.com', 22), 'example.com:22');
      expect(HostKeyStore.normalizeHostKey('10.0.0.1', 2222), '10.0.0.1:2222');
    });

    test('HostKeyMismatchError formats a readable message', () {
      final error = HostKeyMismatchError(
        address: 'example.com',
        port: 22,
        expectedType: 'ssh-ed25519',
        expectedFingerprint: 'SHA256:AAAA',
        actualType: 'ssh-rsa',
        actualFingerprint: 'SHA256:BBBB',
      );
      final message = error.toString();
      expect(message, contains('example.com:22'));
      expect(message, contains('SHA256:AAAA'));
      expect(message, contains('SHA256:BBBB'));
    });
  });
}
