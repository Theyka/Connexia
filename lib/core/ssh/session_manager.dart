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
import '../host_protocol.dart';
import '../telnet/telnet_connection.dart';
import 'host_key_store.dart';
import 'ssh_service.dart';

enum SessionStatus {
  connecting,
  verifyingHostKey,
  connected,
  disconnected,
  error,
}

class HostConnectionRequest {
  final String displayName;
  final String address;
  final int port;
  final String username;
  final String? password;
  final String? identityId;
  final String? keyPassphrase;

  final String? os;
  final String protocol;
  final String? domain;

  HostConnectionRequest({
    required this.displayName,
    required this.address,
    required this.port,
    required this.username,
    this.password,
    this.identityId,
    this.keyPassphrase,
    this.os,
    this.protocol = 'ssh',
    this.domain,
  });
}

class TerminalSession extends ChangeNotifier {
  final String id;
  final HostConnectionRequest request;

  String label;

  final Terminal terminal;
  final TerminalController controller;

  SessionStatus status = SessionStatus.connecting;
  String? error;
  String? acceptedKeyType;
  String? acceptedFingerprint;
  bool hostKeyMismatch = false;
  String? mismatchExpectedType;
  String? mismatchExpectedFingerprint;
  bool hostKeyRejected = false;
  DateTime? connectedAt;

  Completer<bool>? pendingVerification;
  SSHClient? client;
  SSHSession? shell;
  TelnetConnection? telnet;

  bool _closed = false;
  bool get isClosed => _closed;
  bool get isConnected => status == SessionStatus.connected;

  bool autoRetry = false;
  DateTime? nextRetryAt;
  Timer? retryTimer;

  bool hasUnseenOutput = false;

  String? os;

  DateTime? lastPtyResizeAt;

  void stopAutoRetry() {
    retryTimer?.cancel();
    retryTimer = null;
    autoRetry = false;
    nextRetryAt = null;
    notifyListeners();
  }

  bool ctrlLocked = false;
  bool altLocked = false;

  bool ctrlOneShot = false;
  bool altOneShot = false;

  String? logId;

  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;

  final List<int> outputBuffer = [];
  final List<int> errorBuffer = [];
  Timer? outputFlushTimer;
  bool outputFlushScheduled = false;
  Utf8StreamDecoder? stdoutDecoder;
  Utf8StreamDecoder? stderrDecoder;

  void clearOutputBuffers() {
    outputFlushTimer?.cancel();
    outputFlushTimer = null;
    outputFlushScheduled = false;
    outputBuffer.clear();
    errorBuffer.clear();
  }

  TerminalSession({
    required this.id,
    required this.request,
    required this.terminal,
    required this.controller,
  }) : label = request.displayName,
       os = request.os;

  void disposeSession() {
    _closed = true;
    retryTimer?.cancel();
    retryTimer = null;
    autoRetry = false;
    nextRetryAt = null;
    clearOutputBuffers();
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    client?.close();
    telnet?.close();
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

  int _sessionCounter = 0;

  int _maxConcurrentConnects = 4;

  int get maxConcurrentConnects => _maxConcurrentConnects;

  set maxConcurrentConnects(int value) {
    _maxConcurrentConnects = value.clamp(1, 100);
  }

  int _scrollbackLines = 5000;

  int get scrollbackLines => _scrollbackLines;

  set scrollbackLines(int value) {
    _scrollbackLines = value.clamp(100, 100000);
  }

  final List<Completer<void>> _connectQueue = [];
  int _connectingCount = 0;

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
      if (session.isClosed) return;
      final telnet = session.telnet;
      if (telnet != null) {
        try {
          telnet.resize(width, height);
          session.lastPtyResizeAt = DateTime.now();
        } catch (_) {}
        return;
      }
      if (session.shell == null) return;
      try {
        session.shell!.resizeTerminal(width, height, pixelWidth, pixelHeight);

        session.lastPtyResizeAt = DateTime.now();
      } catch (_) {}
    });
  }

  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;
  set activeSessionId(String? id) {
    if (_activeSessionId == id) return;
    _activeSessionId = id;

    for (final s in _sessions) {
      if (s.id == id && s.hasUnseenOutput) {
        s.hasUnseenOutput = false;
      }
    }
    notifyListeners();
  }

  bool _terminalsVisible = true;
  bool _workspaceOpen = false;
  Set<String> _workspaceIds = const {};

  void updateVisibleSessions({
    required bool terminalsVisible,
    required bool workspaceOpen,
    required Set<String> workspaceIds,
  }) {
    if (_terminalsVisible == terminalsVisible &&
        _workspaceOpen == workspaceOpen &&
        _workspaceIds.length == workspaceIds.length &&
        _workspaceIds.containsAll(workspaceIds)) {
      return;
    }
    _terminalsVisible = terminalsVisible;
    _workspaceOpen = workspaceOpen;
    _workspaceIds = workspaceIds;

    var cleared = false;
    for (final s in _sessions) {
      if (s.hasUnseenOutput && _isOnScreen(s)) {
        s.hasUnseenOutput = false;
        cleared = true;
      }
    }
    if (cleared) notifyListeners();
  }

  bool _isOnScreen(TerminalSession session) {
    if (!_terminalsVisible) return false;
    if (session.id == _activeSessionId) return true;
    return _workspaceOpen && _workspaceIds.contains(session.id);
  }

  void Function(TerminalSession session)? onHostKeyVerification;

  SessionManager({
    required this._db,
    required this._vault,
    required this._ssh,
    required this._hostKeyStore,
  });

  TerminalSession openSession(HostConnectionRequest request) {
    final controller = TerminalController();
    final terminal = Terminal(maxLines: _scrollbackLines);
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

    terminal.onOutput = (data) => _writeToSession(session, data);

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
    session.hostKeyMismatch = false;
    session.mismatchExpectedType = null;
    session.mismatchExpectedFingerprint = null;
    session.hostKeyRejected = false;
    notifyListeners();
    final startedAt = DateTime.now();
    writeDebugLog(
      'connect start ${session.request.address} '
      '${session.request.port}',
    );

    if (HostProtocol.fromId(session.request.protocol) == HostProtocol.telnet) {
      await _connectTelnet(session, startedAt);
      return;
    }

    try {
      final keyMaterial = await _loadKeyMaterial(session);
      writeDebugLog(
        'connect keyMaterial ${session.request.address} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
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
            const Duration(seconds: 120),
            onTimeout: () => throw TimeoutException('Connection timed out'),
          );
      writeDebugLog(
        'connect ready ${session.request.address} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );

      if (session.isClosed) {
        conn.client.close();
        return;
      }

      session.client = conn.client;
      session.shell = conn.shell;

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

      session.autoRetry = false;
      session.nextRetryAt = null;
      writeDebugLog(
        'connect done ${session.request.address} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
      await _logConnect(session);
      _bumpLastConnected(session);
      _wire(session);
      notifyListeners();
      unawaited(_detectOs(session));
    } catch (e) {
      if (session.isClosed) return;
      writeDebugLog(
        'connect failed ${session.request.address} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms: $e',
      );
      if (session.hostKeyRejected) {
        // The handshake was aborted because the user rejected the host key.
        // dartssh2 reports this as "connection closed before authentication",
        // so keep the precise host-key message already set on the session.
        session.status = SessionStatus.error;
        notifyListeners();
        if (session.autoRetry) _scheduleAutoRetry(session);
        return;
      }
      session.error = _friendlyError(e);
      session.status = SessionStatus.error;
      notifyListeners();

      if (session.autoRetry) _scheduleAutoRetry(session);
    }
  }

  Future<void> _connectTelnet(
    TerminalSession session,
    DateTime startedAt,
  ) async {
    final request = session.request;
    try {
      final conn =
          await TelnetConnection.connect(
            request.address,
            request.port,
            cols: session.terminal.viewWidth,
            rows: session.terminal.viewHeight,
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('Connection timed out'),
          );

      if (session.isClosed) {
        conn.close();
        return;
      }

      session.telnet = conn;
      session.connectedAt = DateTime.now();
      session.status = SessionStatus.connected;
      session.autoRetry = false;
      session.nextRetryAt = null;
      writeDebugLog(
        'telnet connected ${request.address} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms',
      );
      await _logConnect(session);
      _bumpLastConnected(session);
      _wireTelnet(session);
      notifyListeners();
    } catch (e) {
      if (session.isClosed) return;
      writeDebugLog('telnet failed ${request.address}: $e');
      session.error = _friendlyError(e);
      session.status = SessionStatus.error;
      notifyListeners();
      if (session.autoRetry) _scheduleAutoRetry(session);
    }
  }

  void _wireTelnet(TerminalSession session) {
    final conn = session.telnet!;

    session.clearOutputBuffers();
    session.stdoutDecoder = Utf8StreamDecoder();
    session.stderrDecoder = Utf8StreamDecoder();

    session._stdoutSub?.cancel();
    session._stderrSub?.cancel();
    session._stdoutSub = conn.output.listen((bytes) {
      if (session.isClosed) return;
      session.outputBuffer.addAll(bytes);
      _scheduleOutputFlush(session);
    });

    conn.done.then((_) {
      if (session.isClosed || !identical(session.telnet, conn)) return;
      session.telnet = null;
      session.status = SessionStatus.disconnected;
      _logDisconnect(session);
      notifyListeners();
      _scheduleAutoRetry(session);
    });
  }

  void _writeToSession(TerminalSession session, String data) {
    if (session.isClosed) return;
    final bytes = utf8.encode(_applyModifierLocks(session, data));
    final telnet = session.telnet;
    if (telnet != null) {
      telnet.write(bytes);
    } else if (session.shell != null) {
      session.shell!.write(bytes);
    } else {
      return;
    }
    session.ctrlOneShot = false;
    session.altOneShot = false;
  }

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
    var mismatch = false;
    try {
      final trusted = await _hostKeyStore.isTrusted(
        address: session.request.address,
        port: session.request.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      if (trusted) return true;
    } on HostKeyMismatchError catch (e) {
      // The host we know differs from the one being presented. Never
      // auto-accept a changed key: always surface it to the user.
      mismatch = true;
      session.hostKeyMismatch = true;
      session.mismatchExpectedType = e.expectedType;
      session.mismatchExpectedFingerprint = e.expectedFingerprint;
    }

    if (!mismatch) {
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
    } else {
      session.hostKeyRejected = true;
    }
    return accepted;
  }

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

  void closeAllSessionLogs() {
    for (final session in _sessions) {
      if (session.logId != null) {
        _logDisconnect(session);
      }
    }
  }

  void _wire(TerminalSession session) {
    final shell = session.shell!;

    session.clearOutputBuffers();
    session.stdoutDecoder = Utf8StreamDecoder();
    session.stderrDecoder = Utf8StreamDecoder();

    session._stdoutSub?.cancel();
    session._stderrSub?.cancel();
    session._stdoutSub = shell.stdout.listen((bytes) {
      if (session.isClosed) return;
      session.outputBuffer.addAll(bytes);
      _scheduleOutputFlush(session);
    });

    session._stderrSub = shell.stderr.listen((bytes) {
      if (session.isClosed) return;
      session.errorBuffer.addAll(bytes);
      _scheduleOutputFlush(session);
    });

    shell.done.then((_) {
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

  static const int _maxOutputFlushBytes = 32 * 1024;
  static const Duration _outputFlushDelay = Duration(milliseconds: 8);

  void _scheduleOutputFlush(TerminalSession session) {
    if (session.outputFlushScheduled) return;
    session.outputFlushScheduled = true;
    session.outputFlushTimer = Timer(_outputFlushDelay, () {
      _flushOutput(session);
    });
  }

  void _flushOutput(TerminalSession session) {
    session.outputFlushScheduled = false;
    session.outputFlushTimer = null;
    if (session.isClosed) {
      session.clearOutputBuffers();
      return;
    }
    var wrote = false;
    final out = _takeOutputBytes(session.outputBuffer);
    if (out != null) {
      final text = session.stdoutDecoder!.add(out);
      if (text.isNotEmpty) {
        session.terminal.write(text);
        wrote = true;
      }
    }
    final err = _takeOutputBytes(session.errorBuffer);
    if (err != null) {
      final text = session.stderrDecoder!.add(err);
      if (text.isNotEmpty) {
        session.terminal.write(text);
        wrote = true;
      }
    }
    if (wrote) _markUnseenOutput(session);
    if (session.outputBuffer.isNotEmpty || session.errorBuffer.isNotEmpty) {
      _scheduleOutputFlush(session);
    }
  }

  List<int>? _takeOutputBytes(List<int> buffer) {
    if (buffer.isEmpty) return null;
    if (buffer.length <= _maxOutputFlushBytes) {
      final all = List<int>.of(buffer);
      buffer.clear();
      return all;
    }
    final part = buffer.sublist(0, _maxOutputFlushBytes);
    buffer.removeRange(0, _maxOutputFlushBytes);
    return part;
  }

  void _markUnseenOutput(TerminalSession session) {
    if (session.hasUnseenOutput) return;
    if (_isOnScreen(session)) return;
    final resizedAt = session.lastPtyResizeAt;
    if (resizedAt != null &&
        DateTime.now().difference(resizedAt) < const Duration(seconds: 2)) {
      return;
    }
    session.hasUnseenOutput = true;
    notifyListeners();
  }

  void _scheduleAutoRetry(TerminalSession session) {
    if (session.isClosed) return;
    if (session.retryTimer != null) return;
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

  void stopAutoRetry(TerminalSession session) => session.stopAutoRetry();

  Future<void> _detectOs(TerminalSession session) async {
    final client = session.client;
    if (client == null || session.isClosed) return;
    final os = await detectOs(
      client,
      session.request.address,
      session.request.port,
    );
    if (os != null && !session.isClosed && session.os != os) {
      session.os = os;
      notifyListeners();
    }
  }

  Future<String?> detectOs(SSHClient client, String address, int port) async {
    try {
      var output = await _runDetectCommand(
        client,
        'uname -s; uname -m; cat /etc/os-release 2>/dev/null',
      );
      if (output.trim().isEmpty) {
        output = await _runDetectCommand(client, 'ver');
      }
      final os = _parseOs(output);
      if (os == null) return null;
      await _db.updateHostOsByAddress(address, port, os);
      return os;
    } catch (_) {
      // ignore
      return null;
    }
  }

  Future<String> _runDetectCommand(SSHClient client, String command) async {
    final exec = await client.execute(command);
    final chunks = await exec.stdout.toList();
    exec.close();
    final output = Uint8List.fromList([for (final chunk in chunks) ...chunk]);
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
      final id = RegExp(
        r'^ID="?([a-z]+)"?',
        multiLine: true,
      ).firstMatch(output);
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

  void renameSession(TerminalSession session, String newLabel) {
    final trimmed = newLabel.trim();
    if (trimmed.isEmpty || trimmed == session.label) return;
    session.label = trimmed;
    notifyListeners();
  }

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

  bool pasteToActiveSession(String content) {
    final target = _activeTarget();
    if (target == null) return false;
    target.terminal.paste(normalizePaste(content));
    return true;
  }

  bool runInActiveSession(String content) {
    final target = _activeTarget();
    if (target == null) return false;
    target.terminal.paste(normalizePaste(content));
    _sendEnter(target);
    return true;
  }

  void _sendEnter(TerminalSession session) {
    final telnet = session.telnet;
    if (telnet != null) {
      try {
        telnet.write(utf8.encode('\r'));
      } catch (_) {
        session.terminal.paste('\r');
      }
      return;
    }
    final shell = session.shell;
    if (shell != null) {
      try {
        shell.write(utf8.encode('\r'));
      } catch (_) {
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
    final terminal = Terminal(maxLines: _scrollbackLines);
    final fresh = TerminalSession(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      request: request,
      terminal: terminal,
      controller: controller,
    );

    terminal.onOutput = (data) => _writeToSession(fresh, data);
    terminal.onResize = (width, height, pixelWidth, pixelHeight) =>
        _schedulePtyResize(fresh, width, height, pixelWidth, pixelHeight);

    _sessions.insert(index, fresh);
    activeSessionId = fresh.id;
    notifyListeners();
    _throttledConnect(fresh);
  }

  TerminalSession duplicateSession(TerminalSession session) {
    return openSession(session.request);
  }

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

  static String normalizePaste(String content) =>
      content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

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
    if (e is SSHAuthAbortError) {
      if (e.reason is SSHHostkeyError) {
        return 'Host key verification failed.';
      }
      return 'The server closed the connection before authentication '
          'completed.';
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

class Utf8StreamDecoder {
  final List<int> _carry = [];

  String add(List<int> bytes) {
    final combined = <int>[..._carry, ...bytes];
    _carry.clear();

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
