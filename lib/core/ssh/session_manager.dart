import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../crypto/vault.dart';
import '../db/database.dart';
import '../debug_log.dart';
import 'host_key_store.dart';
import 'ssh_service.dart';

enum SessionStatus {
  connecting,
  verifyingHostKey,
  connected,
  disconnected,
  error,
}

/// Everything needed to open a connection to a host.
class HostConnectionRequest {
  final String displayName;
  final String address;
  final int port;
  final String username;
  final String? password;
  final String? identityId;
  final String? keyPassphrase;

  HostConnectionRequest({
    required this.displayName,
    required this.address,
    required this.port,
    required this.username,
    this.password,
    this.identityId,
    this.keyPassphrase,
  });
}

class TerminalSession extends ChangeNotifier {
  final String id;
  final HostConnectionRequest request;

  /// The name shown on the session tab. Starts as the request's display name
  /// (with a `(n)` suffix for duplicate connections) and can be renamed.
  String label;

  final Terminal terminal;
  final TerminalController controller;

  SessionStatus status = SessionStatus.connecting;
  String? error;
  String? acceptedKeyType;
  String? acceptedFingerprint;
  DateTime? connectedAt;

  Completer<bool>? pendingVerification;
  SSHClient? client;
  SSHSession? shell;

  bool _closed = false;
  bool get isClosed => _closed;
  bool get isConnected => status == SessionStatus.connected;

  /// Auto-reconnect state: when the session ends unexpectedly, the manager
  /// retries every few seconds until it succeeds or the user stops it.
  bool autoRetry = false;
  DateTime? nextRetryAt;
  Timer? retryTimer;

  /// Stops the auto-reconnect loop and dismisses the retry banner.
  void stopAutoRetry() {
    retryTimer?.cancel();
    retryTimer = null;
    autoRetry = false;
    nextRetryAt = null;
    notifyListeners();
  }

  /// Sticky modifier locks armed from the mobile key toolbar. While locked,
  /// every character typed (soft keyboard or toolbar) is emitted as if the
  /// modifier were held down on a PC keyboard.
  bool ctrlLocked = false;
  bool altLocked = false;

  /// One-shot modifiers: applied to the next emitted input, then cleared.
  bool ctrlOneShot = false;
  bool altOneShot = false;

  String? logId;

  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  TerminalSession({
    required this.id,
    required this.request,
    required this.terminal,
    required this.controller,
  }) : label = request.displayName;

  void disposeSession() {
    _closed = true;
    retryTimer?.cancel();
    retryTimer = null;
    autoRetry = false;
    nextRetryAt = null;
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    client?.close();
    controller.dispose();
    super.dispose();
  }
}

class SessionManager extends ChangeNotifier {
  final AppDatabase _db;
  final Vault _vault;
  final SshService _ssh;
  final HostKeyStore _hostKeyStore;

  final List<TerminalSession> _sessions = [];
  List<TerminalSession> get sessions => List.unmodifiable(_sessions);

  /// Monotonic counter so sessions opened back-to-back never share an id.
  int _sessionCounter = 0;

  /// Bounds how many SSH connections may be opening at the same time. The
  /// key exchange does some CPU-heavy crypto on the UI thread, so an
  /// unlimited fan-out would cause visible jank. Configurable via settings
  /// (defaults to 4); changes take effect on the next connect cycle.
  int _maxConcurrentConnects = 4;

  int get maxConcurrentConnects => _maxConcurrentConnects;

  set maxConcurrentConnects(int value) {
    _maxConcurrentConnects = value.clamp(1, 100);
  }

  final List<Completer<void>> _connectQueue = [];
  int _connectingCount = 0;

  /// Pending PTY resize timers by session id. Window/pinch resizes fire
  /// many resizes in quick succession; coalescing them into a single
  /// trailing write per session avoids flooding the SSH channel with
  /// window-change requests (and racing them against stdin writes).
  final Map<String, Timer> _ptyResizeTimers = {};

  Future<void> _throttledConnect(TerminalSession session) async {
    final gate = Completer<void>();
    _connectQueue.add(gate);
    _pumpConnectQueue();
    await gate.future;
    try {
      await _connect(session);
    } finally {
      _connectingCount--;
      _pumpConnectQueue();
    }
  }

  void _pumpConnectQueue() {
    while (_connectingCount < _maxConcurrentConnects &&
        _connectQueue.isNotEmpty) {
      _connectingCount++;
      _connectQueue.removeAt(0).complete();
    }
  }

  /// Coalesces a burst of terminal resizes into one trailing PTY
  /// window-change per session.
  void _schedulePtyResize(
    TerminalSession session,
    int width,
    int height,
    int pixelWidth,
    int pixelHeight,
  ) {
    _ptyResizeTimers[session.id]?.cancel();
    _ptyResizeTimers[session.id] = Timer(const Duration(milliseconds: 60), () {
      _ptyResizeTimers.remove(session.id);
      if (session.isClosed || session.shell == null) return;
      try {
        session.shell!.resizeTerminal(
          width,
          height,
          pixelWidth,
          pixelHeight,
        );
      } catch (_) {
        // A failed resize request must never break terminal rendering.
      }
    });
  }

  /// The session shown in the terminals section. The UI sets this when the
  /// user switches tabs; used by snippet insertion. Setting it notifies
  /// listeners so the tab bar and terminal pane can react.
  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;
  set activeSessionId(String? id) {
    if (_activeSessionId == id) return;
    _activeSessionId = id;
    notifyListeners();
  }

  /// Called when a session transitions to [SessionStatus.verifyingHostKey].
  /// The UI shows the fingerprint dialog and calls [resolveHostKey].
  void Function(TerminalSession session)? onHostKeyVerification;

  SessionManager({
    required this._db,
    required this._vault,
    required this._ssh,
    required this._hostKeyStore,
  });

  TerminalSession openSession(HostConnectionRequest request) {
    final controller = TerminalController();
    final terminal = Terminal(maxLines: 1000);
    final session = TerminalSession(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_sessionCounter++}',
      request: request,
      terminal: terminal,
      controller: controller,
    );

    var duplicates = 0;
    for (final s in _sessions) {
      if (s.request.address == request.address &&
          s.request.port == request.port) {
        duplicates++;
      }
    }
    if (duplicates > 0) {
      session.label = '${request.displayName} (${duplicates + 1})';
    }

    terminal.onOutput = (data) {
      if (!session.isClosed && session.shell != null) {
        session.shell!.write(utf8.encode(_applyModifierLocks(session, data)));
        session.ctrlOneShot = false;
        session.altOneShot = false;
      }
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      _schedulePtyResize(session, width, height, pixelWidth, pixelHeight);
    };

    _sessions.add(session);
    activeSessionId = session.id;
    notifyListeners();
    _throttledConnect(session);
    return session;
  }

  Future<void> _connect(TerminalSession session) async {
    session.status = SessionStatus.connecting;
    session.error = null;
    notifyListeners();
    final startedAt = DateTime.now();
    writeDebugLog('connect start ${session.request.address} '
        '${session.request.port}');

    try {
      final keyMaterial = await _loadKeyMaterial(session);
      writeDebugLog('connect keyMaterial ${session.request.address} '
          '${DateTime.now().difference(startedAt).inMilliseconds}ms');
      final conn = await _ssh
          .connect(
            host: session.request.address,
            port: session.request.port,
            username: session.request.username,
            password: session.request.password,
            privateKeys: keyMaterial.$1,
            passphrase: keyMaterial.$2 ?? session.request.keyPassphrase,
            onVerifyHostKey: (type, fingerprint) =>
                _verifyHostKey(session, type, fingerprint),
            terminalWidth: session.terminal.viewWidth,
            terminalHeight: session.terminal.viewHeight,
          )
          .timeout(
            // A connect that never completes would leave the pane on a
            // gray "connecting" scrim forever; the host-key prompt can
            // legitimately wait for the user, so keep it generous.
            const Duration(seconds: 120),
            onTimeout: () =>
                throw TimeoutException('Connection timed out'),
          );
      writeDebugLog('connect ready ${session.request.address} '
          '${DateTime.now().difference(startedAt).inMilliseconds}ms');

      if (session.isClosed) {
        conn.client.close();
        return;
      }

      session.client = conn.client;
      session.shell = conn.shell;
      // Re-assert the terminal size on the fresh PTY. A resize that fired
      // while the shell was still connecting was dropped, and the shell may
      // have been created with a stale size; without this, full-screen TUI
      // apps (htop, btop, ...) leave a black band at the bottom.
      try {
        session.shell!.resizeTerminal(
          session.terminal.viewWidth,
          session.terminal.viewHeight,
        );
      } catch (_) {
        // ignore
      }
      session.connectedAt = DateTime.now();
      session.status = SessionStatus.connected;
      // The reconnect loop has served its purpose.
      session.autoRetry = false;
      session.nextRetryAt = null;
      writeDebugLog('connect done ${session.request.address} '
          '${DateTime.now().difference(startedAt).inMilliseconds}ms');
      await _logConnect(session);
      _bumpLastConnected(session);
      _wire(session);
      notifyListeners();
      unawaited(_detectOs(session));
    } catch (e) {
      if (session.isClosed) return;
      writeDebugLog('connect failed ${session.request.address} '
          '${DateTime.now().difference(startedAt).inMilliseconds}ms: $e');
      session.error = _friendlyError(e);
      session.status = SessionStatus.error;
      notifyListeners();
      // A failed retry attempt keeps the auto-reconnect loop running until
      // the user closes the banner.
      if (session.autoRetry) _scheduleAutoRetry(session);
    }
  }

  /// Brings the session's host to the top of the Hosts screen. Best-effort:
  /// quick-connect targets that are not saved hosts are silently ignored.
  Future<void> _bumpLastConnected(TerminalSession session) {
    return _db
        .updateHostLastConnectedByAddress(
          session.request.address,
          session.request.port,
          DateTime.now(),
        )
        .catchError((_) {});
  }

  Future<(List<String>, String?)> _loadKeyMaterial(
    TerminalSession session,
  ) async {
    final identityId = session.request.identityId;
    if (identityId == null) return (const <String>[], null);

    final identity = await _db.findIdentityById(identityId);
    if (identity == null) return (const <String>[], null);

    final pem = await _vault.decrypt(identity.encryptedKeyPem);
    String? passphrase;
    if (identity.encryptedPassphrase != null) {
      passphrase = await _vault.decrypt(identity.encryptedPassphrase!);
    }
    return ([pem], passphrase);
  }

  Future<bool> _verifyHostKey(
    TerminalSession session,
    String type,
    String fingerprint,
  ) async {
    try {
      final trusted = await _hostKeyStore.isTrusted(
        address: session.request.address,
        port: session.request.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      if (trusted) return true;
    } on HostKeyMismatchError catch (e) {
      session.error = e.toString();
      session.status = SessionStatus.error;
      notifyListeners();
      return false;
    }

    final autoAccept = await _db.getSetting('autoAcceptHostKeys') == 'true';
    if (autoAccept) {
      await _hostKeyStore.trust(
        address: session.request.address,
        port: session.request.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      return true;
    }

    session.acceptedKeyType = type;
    session.acceptedFingerprint = fingerprint;
    session.status = SessionStatus.verifyingHostKey;
    final completer = Completer<bool>();
    session.pendingVerification = completer;
    notifyListeners();
    onHostKeyVerification?.call(session);

    final accepted = await completer.future;
    if (accepted) {
      await _hostKeyStore.trust(
        address: session.request.address,
        port: session.request.port,
        keyType: type,
        fingerprint: fingerprint,
      );
    }
    return accepted;
  }

  /// Resolves a pending host-key verification dialog.
  void resolveHostKey(TerminalSession session, {required bool accept}) {
    final completer = session.pendingVerification;
    if (completer == null) return;
    session.pendingVerification = null;
    if (!accept) {
      session.error = 'Connection cancelled: host key not trusted.';
      session.status = SessionStatus.error;
      notifyListeners();
      completer.complete(false);
      return;
    }
    completer.complete(true);
  }

  Future<void> _logConnect(TerminalSession session) async {
    if (session.logId != null) return;
    final id = const Uuid().v4();
    session.logId = id;
    await _db.insertSessionLog(
      SessionLogsCompanion.insert(
        id: id,
        address: session.request.address,
        username: session.request.username,
        connectedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _logDisconnect(TerminalSession session) async {
    final logId = session.logId;
    if (logId == null) return;
    session.logId = null;
    await _db.endSessionLog(logId, DateTime.now());
  }

  /// Ends the session-log entry of every still-open session. Called when
  /// the app is shutting down (window closed) so no log stays marked as
  /// active after the process exits.
  void closeAllSessionLogs() {
    for (final session in _sessions) {
      if (session.logId != null) {
        _logDisconnect(session);
      }
    }
  }

  void _wire(TerminalSession session) {
    final shell = session.shell!;

    // Streaming UTF-8 decoding with carry-over: decoding each SSH chunk
    // independently turns a multi-byte character split across two chunks
    // into '�' garbage (full-screen TUI redraws arrive in many chunks),
    // while the dart:convert chunked sink API buffers everything until
    // close() — which would blank the terminal for the whole session.
    // (dart:convert's Converter.startChunkedConversion accumulates.)
    final stdoutDecoder = Utf8StreamDecoder();
    final stderrDecoder = Utf8StreamDecoder();

    session._stdoutSub?.cancel();
    session._stderrSub?.cancel();
    session._stdoutSub = shell.stdout.listen((bytes) {
      if (!session.isClosed) {
        session.terminal.write(stdoutDecoder.add(bytes));
      }
    });

    session._stderrSub = shell.stderr.listen((bytes) {
      if (!session.isClosed) {
        session.terminal.write(stderrDecoder.add(bytes));
      }
    });

    shell.done.then((_) {
      // Only the current shell may end the session. A shell that was
      // replaced by an auto-retry must be ignored.
      if (session.isClosed || !identical(session.shell, shell)) return;
      session.shell = null;
      session.client?.close();
      session.client = null;
      session.status = SessionStatus.disconnected;
      _logDisconnect(session);
      notifyListeners();
      _scheduleAutoRetry(session);
    });
  }

  /// Starts the auto-reconnect loop for [session]: a retry every
  /// [autoRetryInterval] seconds until it connects or the user stops it.
  /// Notifies listeners every second so the retry countdown banner can tick.
  void _scheduleAutoRetry(TerminalSession session) {
    if (session.isClosed) return;
    if (session.retryTimer != null) return; // Already ticking.
    session.autoRetry = true;
    session.nextRetryAt = DateTime.now().add(_retryInterval);
    session.retryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (session.isClosed) return;
      final next = session.nextRetryAt;
      if (next == null) return;
      if (!DateTime.now().isBefore(next)) {
        session.retryTimer?.cancel();
        session.retryTimer = null;
        session.nextRetryAt = null;
        notifyListeners();
        _connect(session);
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  static const Duration _retryInterval = Duration(seconds: 5);

  /// Stops the auto-reconnect loop for [session]. The session stays open
  /// (disconnected) so the user can reconnect manually if they want.
  void stopAutoRetry(TerminalSession session) => session.stopAutoRetry();

  // ---------------------------------------------------------------------
  // OS detection
  // ---------------------------------------------------------------------

  /// Identifies the remote OS after a successful connection and persists it
  /// on the matching saved host so the Hosts screen can show an OS icon.
  /// Best-effort: failures are swallowed and never affect the session.
  Future<void> _detectOs(TerminalSession session) {
    final client = session.client;
    if (client == null || session.isClosed) return Future.value();
    return detectOs(client, session.request.address, session.request.port);
  }

  /// Runs a best-effort remote OS identification on an already connected
  /// client and persists the result on the matching saved host.
  Future<void> detectOs(SSHClient client, String address, int port) async {
    try {
      var output = await _runDetectCommand(
        client,
        'uname -s; uname -m; cat /etc/os-release 2>/dev/null',
      );
      if (output.trim().isEmpty) {
        output = await _runDetectCommand(client, 'ver');
      }
      final os = _parseOs(output);
      if (os == null) return;
      await _db.updateHostOsByAddress(address, port, os);
    } catch (_) {
      // ignore
    }
  }

  Future<String> _runDetectCommand(SSHClient client, String command) async {
    final exec = await client.execute(command);
    final chunks = await exec.stdout.toList();
    exec.close();
    final output = Uint8List.fromList([
      for (final chunk in chunks) ...chunk,
    ]);
    return utf8.decode(output, allowMalformed: true);
  }

  String? _parseOs(String output) {
    final upper = output.toUpperCase();
    if (upper.contains('MINGW') ||
        upper.contains('CYGWIN') ||
        upper.contains('MSYS') ||
        upper.contains('MICROSOFT WINDOWS')) {
      return 'Windows';
    }
    if (upper.contains('DARWIN')) return 'macOS';
    if (upper.contains('FREEBSD')) return 'FreeBSD';
    if (upper.contains('OPENBSD')) return 'OpenBSD';
    if (upper.contains('NETBSD')) return 'NetBSD';
    if (upper.contains('SUNOS')) return 'Solaris';
    if (upper.contains('LINUX')) {
      final pretty = RegExp(r'PRETTY_NAME="?([^"\n]+)"?').firstMatch(output);
      if (pretty != null) return pretty.group(1)!;
      final id = RegExp(r'^ID="?([a-z]+)"?', multiLine: true).firstMatch(output);
      if (id != null) {
        final value = id.group(1)!;
        return value[0].toUpperCase() + value.substring(1);
      }
      return 'Linux';
    }
    return null;
  }

  void closeSession(TerminalSession session) {
    if (session.logId != null) {
      _logDisconnect(session);
    }
    final wasActive = activeSessionId == session.id;
    final closedIndex = _sessions.indexOf(session);
    _sessions.remove(session);
    _ptyResizeTimers.remove(session.id)?.cancel();
    // When the active session is closed and others remain, hand the
    // activation to a neighbor (browser-style) so the terminal view and
    // the highlighted tab stay in sync instead of falling back to
    // "first session" in one place and "no selection" in the other.
    if (wasActive) {
      if (_sessions.isEmpty) {
        activeSessionId = null;
      } else {
        final index = closedIndex < _sessions.length
            ? closedIndex
            : _sessions.length - 1;
        activeSessionId = _sessions[index].id;
      }
    }
    session.disposeSession();
    notifyListeners();
  }

  /// Renames the session tab shown in the title bar.
  void renameSession(TerminalSession session, String newLabel) {
    final trimmed = newLabel.trim();
    if (trimmed.isEmpty || trimmed == session.label) return;
    session.label = trimmed;
    notifyListeners();
  }

  /// Reorders by computing the insertion index from the pointer position
  /// over the tab strip. Used by the tab drag-and-drop reordering.
  void reorderToIndex(String draggedId, int targetIndex) {
    final oldIndex = _sessions.indexWhere((s) => s.id == draggedId);
    if (oldIndex < 0) return;
    final item = _sessions.removeAt(oldIndex);
    var insertAt = targetIndex < 0
        ? 0
        : (targetIndex > _sessions.length ? _sessions.length : targetIndex);
    if (insertAt > oldIndex) insertAt--;
    _sessions.insert(insertAt, item);
    notifyListeners();
  }

  /// Pastes [content] into the active terminal session. Returns false if
  /// there is no connected session to receive it.
  bool pasteToActiveSession(String content) {
    final target = _activeTarget();
    if (target == null) return false;
    target.terminal.paste(normalizePaste(content));
    return true;
  }

  /// Runs [content] in the active terminal session (paste followed by
  /// enter). The enter key is written straight to the shell instead of
  /// through the terminal's paste path so bracketed-paste mode cannot
  /// swallow it. Returns false if there is no connected session.
  bool runInActiveSession(String content) {
    final target = _activeTarget();
    if (target == null) return false;
    target.terminal.paste(normalizePaste(content));
    _sendEnter(target);
    return true;
  }

  void _sendEnter(TerminalSession session) {
    final shell = session.shell;
    if (shell != null) {
      try {
        shell.write(utf8.encode('\r'));
      } catch (_) {
        // Fall back to the terminal paste path if the shell is gone.
        session.terminal.paste('\r');
      }
    } else {
      session.terminal.paste('\r');
    }
  }

  TerminalSession? _activeTarget() {
    if (activeSessionId != null) {
      for (final session in _sessions) {
        if (session.id == activeSessionId) {
          return session.isConnected ? session : null;
        }
      }
    }
    for (final session in _sessions) {
      if (session.isConnected) return session;
    }
    return null;
  }

  @override
  void dispose() {
    for (final session in List.of(_sessions)) {
      closeSession(session);
    }
    super.dispose();
  }

  void reconnect(TerminalSession session) {
    final index = _sessions.indexWhere((s) => s.id == session.id);
    final request = session.request;
    _sessions.removeAt(index);
    session.disposeSession();

    final controller = TerminalController();
    final terminal = Terminal(maxLines: 1000);
    final fresh = TerminalSession(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      request: request,
      terminal: terminal,
      controller: controller,
    );

    terminal.onOutput = (data) {
      if (!fresh.isClosed && fresh.shell != null) {
        fresh.shell!.write(
          utf8.encode(_applyModifierLocks(fresh, data)),
        );
        fresh.ctrlOneShot = false;
        fresh.altOneShot = false;
      }
    };
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (!fresh.isClosed && fresh.shell != null) {
        try {
          fresh.shell!.resizeTerminal(
            width,
            height,
            pixelWidth,
            pixelHeight,
          );
        } catch (_) {
          // A failed resize request must never break terminal rendering.
        }
      }
    };

    _sessions.insert(index, fresh);
    activeSessionId = fresh.id;
    notifyListeners();
    _throttledConnect(fresh);
  }

  /// Opens a new session with the same connection request as [session].
  TerminalSession duplicateSession(TerminalSession session) {
    return openSession(session.request);
  }

  /// Pastes [content] into every connected session. Returns the number of
  /// sessions that received it.
  int pasteToAllConnected(String content) {
    var count = 0;
    for (final session in _sessions) {
      if (session.isConnected) {
        session.terminal.paste(normalizePaste(content));
        count++;
      }
    }
    return count;
  }

  /// Runs [content] in every connected session (paste followed by enter).
  /// Returns the number of sessions that received it.
  int runInAllConnected(String content) {
    var count = 0;
    for (final session in _sessions) {
      if (session.isConnected) {
        session.terminal.paste(normalizePaste(content));
        _sendEnter(session);
        count++;
      }
    }
    return count;
  }

  /// Windows and web clipboards carry CRLF line endings. A terminal paste
  /// must never include bare CR: the remote tty maps CR to newline, so
  /// `\r\n` arrives as two newlines and breaks `\`-continued multi-line
  /// scripts mid-line. Normalize every pasted newline to a single LF.
  static String normalizePaste(String content) =>
      content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// Applies the session's locked/one-shot modifiers to data headed to the
  /// PTY. A soft keyboard can't send modifier chords, so a locked Ctrl turns
  /// `c` into ^C, a locked Alt prefixes every character with ESC, and so on.
  /// One-shot modifiers are consumed after the first batch of output.
  String _applyModifierLocks(TerminalSession session, String data) {
    final ctrl = session.ctrlLocked || session.ctrlOneShot;
    final alt = session.altLocked || session.altOneShot;
    if (!ctrl && !alt) return data;
    final buffer = StringBuffer();
    for (final rune in data.runes) {
      var char = String.fromCharCode(rune);
      if (ctrl) {
        char = _ctrlTransform(char);
      }
      if (alt) {
        buffer.write('\u001b');
      }
      buffer.write(char);
    }
    return buffer.toString();
  }

  /// PC-style Ctrl mapping: letters collapse to control codes, plus the
  /// punctuation that hardware keyboards produce (Ctrl+[ = ESC, etc.).
  static String _ctrlTransform(String char) {
    final code = char.codeUnitAt(0);
    if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code - 96);
    if (code >= 0x41 && code <= 0x5a) return String.fromCharCode(code - 64);
    switch (char) {
      case '[':
      case '3':
        return '\u001b';
      case '\\':
      case '4':
        return '\u001c';
      case ']':
      case '5':
        return '\u001d';
      case '^':
      case '6':
        return '\u001e';
      case '_':
      case '/':
      case '7':
        return '\u001f';
      case '@':
      case ' ':
      case '2':
        return '\u0000';
      case '?':
        return '\u007f';
      default:
        return char;
    }
  }

  String _friendlyError(Object e) {
    if (e is SSHAuthFailError) {
      return 'Authentication failed. Check the username, password or key.';
    }
    if (e is SSHHandshakeError) {
      return 'SSH handshake failed: ${e.message}';
    }
    if (e is SSHHostkeyError) {
      return 'Host key verification failed.';
    }
    if (e is SSHSocketError) {
      return 'Connection error: ${e.error}';
    }
    if (e is SocketException) {
      return 'Cannot reach ${e.address?.host ?? 'host'}: ${e.osError?.message ?? e.message}';
    }
    if (e is TimeoutException) {
      return 'Connection timed out.';
    }
    return 'Connection failed: $e';
  }
}

/// Streaming UTF-8 decoder that decodes each chunk immediately while
/// carrying an incomplete multi-byte sequence across chunk boundaries.
/// `dart:convert`'s chunked sink API cannot be used here: the default
/// [Converter.startChunkedConversion] accumulates input and only emits
/// once the sink is closed, which would blank the terminal for the whole
/// session.
class Utf8StreamDecoder {
  final List<int> _carry = [];

  String add(List<int> bytes) {
    final combined = <int>[..._carry, ...bytes];
    _carry.clear();

    // Hold back a trailing suffix that may be an incomplete UTF-8
    // sequence (a lead byte, or continuation bytes without their lead)
    // until the next chunk arrives.
    var keep = 0;
    for (var i = combined.length - 1; i >= 0; i--) {
      final b = combined[i];
      if (b < 0x80) break;
      if (b >= 0xC0) {
        keep = combined.length - i;
        break;
      }
    }

    if (keep > 0) {
      _carry.addAll(combined.sublist(combined.length - keep));
      combined.removeRange(combined.length - keep, combined.length);
    }

    return utf8.decode(combined, allowMalformed: true);
  }
}
