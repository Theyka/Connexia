import 'package:connexia/core/crypto/secret_storage.dart';
import 'package:connexia/core/crypto/vault.dart';
import 'package:connexia/core/db/database.dart';
import 'package:connexia/core/ssh/host_key_store.dart';
import 'package:connexia/core/ssh/session_manager.dart';
import 'package:connexia/core/ssh/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _oldFingerprint = 'SHA256:OLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOL';
const _newFingerprint = 'SHA256:NEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNEWNE';

/// Emulates dartssh2: the host-key callback runs during the handshake and,
/// when it rejects the key, dartssh2 closes the transport and the client
/// surfaces the rejection as an [SSHAuthAbortError].
class _FakeSshService extends SshService {
  @override
  Future<SshConnection> connect({
    required String host,
    required int port,
    required String username,
    String? password,
    List<String> privateKeys = const [],
    String? passphrase,
    required Future<bool> Function(String keyType, String fingerprint)
    onVerifyHostKey,
    int terminalWidth = 80,
    int terminalHeight = 24,
  }) async {
    final accepted = await onVerifyHostKey('ssh-ed25519', _newFingerprint);
    if (!accepted) {
      throw SSHAuthAbortError(
        'Connection closed before authentication',
        SSHHostkeyError('Hostkey verification failed'),
      );
    }
    throw SSHAuthFailError('stop after verification');
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late AppDatabase db;
  late Vault vault;
  late HostKeyStore store;
  late SessionManager manager;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    vault = Vault(InMemorySecretStorage());
    store = HostKeyStore(db);
    manager = SessionManager(
      db: db,
      vault: vault,
      ssh: _FakeSshService(),
      hostKeyStore: store,
    );
  });

  tearDown(() async {
    await db.close();
  });

  TerminalSession connect() => manager.openSession(
    HostConnectionRequest(
      displayName: 'host',
      address: '1.2.3.4',
      port: 22,
      username: 'root',
    ),
  );

  test(
    'a changed host key is reported as a change, not an auth abort',
    () async {
      await store.trust(
        address: '1.2.3.4',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _oldFingerprint,
      );

      final session = connect();
      await _waitFor(() => session.status == SessionStatus.verifyingHostKey);

      expect(session.hostKeyMismatch, isTrue);
      expect(session.mismatchExpectedType, 'ssh-ed25519');
      expect(session.mismatchExpectedFingerprint, _oldFingerprint);
      expect(session.acceptedFingerprint, _newFingerprint);

      manager.resolveHostKey(session, accept: false);
      await _waitFor(() => session.status == SessionStatus.error);

      expect(session.error, 'Connection cancelled: host key not trusted.');
      expect(session.error, isNot(contains('closed before authentication')));
    },
  );

  test('accepting a changed host key replaces the stored key', () async {
    await store.trust(
      address: '1.2.3.4',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: _oldFingerprint,
    );

    final session = connect();
    await _waitFor(() => session.hostKeyMismatch);

    manager.resolveHostKey(session, accept: true);
    await _waitFor(() => session.status == SessionStatus.error);

    expect(
      await store.isTrusted(
        address: '1.2.3.4',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _newFingerprint,
      ),
      isTrue,
    );
  });

  test('an unknown host key is still prompted and can be trusted', () async {
    final session = connect();
    await _waitFor(() => session.status == SessionStatus.verifyingHostKey);

    expect(session.hostKeyMismatch, isFalse);
    expect(session.mismatchExpectedFingerprint, isNull);

    manager.resolveHostKey(session, accept: true);
    await _waitFor(() => session.status == SessionStatus.error);

    expect(
      await store.isTrusted(
        address: '1.2.3.4',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _newFingerprint,
      ),
      isTrue,
    );
  });

  test('autoAcceptHostKeys trusts an unknown key without prompting', () async {
    await db.setSetting('autoAcceptHostKeys', 'true');

    final session = connect();
    await _waitFor(() => session.status == SessionStatus.error);

    expect(session.status, isNot(SessionStatus.verifyingHostKey));
    expect(
      await store.isTrusted(
        address: '1.2.3.4',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _newFingerprint,
      ),
      isTrue,
    );
  });

  test('autoAcceptHostKeys never silently replaces a changed key', () async {
    await db.setSetting('autoAcceptHostKeys', 'true');
    await store.trust(
      address: '1.2.3.4',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: _oldFingerprint,
    );

    final session = connect();
    await _waitFor(() => session.status == SessionStatus.verifyingHostKey);

    expect(session.hostKeyMismatch, isTrue);
    expect(
      await store.isTrusted(
        address: '1.2.3.4',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _oldFingerprint,
      ),
      isTrue,
    );
  });
}
