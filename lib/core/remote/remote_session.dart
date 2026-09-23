import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../ui/state/rust_engine.dart';
import '../host_protocol.dart';
import 'framebuffer.dart';
import 'key_mapping.dart';
import 'rfb_client.dart';

enum RemoteStatus { connecting, connected, disconnected, error }

/// Protocol-agnostic input sink for a graphical session.
abstract class RemoteClient {
  void sendKey(RemoteKeyEvent event, bool down);
  void sendPointer(int buttons, int x, int y);
  void sendWheel(int buttons, int x, int y, int delta) {}
  void sendClipboard(String text);

  /// Whether this session is currently on screen. Background sessions may
  /// suppress framebuffer delivery to avoid saturating the UI isolate.
  void setVisible(bool visible) {}
  void close();
}

class RemoteSession extends ChangeNotifier {
  RemoteSession({
    required this.id,
    required this.title,
    required this.protocol,
    required int width,
    required int height,
  }) : framebuffer = Framebuffer(width, height),
       desktopWidth = width,
       desktopHeight = height;

  final String id;
  final String title;
  final HostProtocol protocol;
  final Framebuffer framebuffer;

  int desktopWidth;
  int desktopHeight;
  RemoteStatus status = RemoteStatus.connecting;
  String? error;

  String address = '';
  int port = 0;
  String? username;
  String? password;
  String? domain;
  int requestedWidth = 1280;
  int requestedHeight = 800;

  /// Latest clipboard text received from the remote host.
  String? remoteClipboard;

  RemoteClient? _client;

  void setRemoteClipboard(String text) {
    if (text == remoteClipboard) return;
    remoteClipboard = text;
    notifyListeners();
  }

  void attachClient(RemoteClient client) {
    _client = client;
  }

  void markConnected() {
    status = RemoteStatus.connected;
    error = null;
    notifyListeners();
  }

  void markDisconnected(String? reason) {
    if (status == RemoteStatus.disconnected || status == RemoteStatus.error) {
      return;
    }
    status = RemoteStatus.disconnected;
    error = reason;
    notifyListeners();
  }

  void markError(String message) {
    status = RemoteStatus.error;
    error = message;
    notifyListeners();
  }

  void updateDesktopSize(int width, int height) {
    desktopWidth = width;
    desktopHeight = height;
    framebuffer.resize(width, height);
    notifyListeners();
  }

  /// Marks whether this session is the one currently on screen. Hidden
  /// sessions keep running but stop forwarding pixel data to the UI.
  void setVisible(bool visible) {
    framebuffer.setVisible(visible);
    _client?.setVisible(visible);
  }

  void sendKey(RemoteKeyEvent event, bool down) {
    if (event.isEmpty) return;
    _client?.sendKey(event, down);
  }

  void sendPointer(int buttons, int x, int y) {
    _client?.sendPointer(buttons, x, y);
  }

  void sendWheel(int buttons, int x, int y, int delta) {
    _client?.sendWheel(buttons, x, y, delta);
  }

  void sendClipboard(String text) {
    _client?.sendClipboard(text);
  }

  void typeText(String text) {
    final client = _client;
    if (client == null) return;
    for (final rune in text.runes) {
      if (rune == 0x0A) {
        client.sendKey(
          const RemoteKeyEvent(
            keysym: 0xFF0D,
            scancode: 0x1C,
            extended: false,
            unicode: null,
          ),
          true,
        );
        client.sendKey(
          const RemoteKeyEvent(
            keysym: 0xFF0D,
            scancode: 0x1C,
            extended: false,
            unicode: null,
          ),
          false,
        );
        continue;
      }
      client.sendKey(
        RemoteKeyEvent(
          keysym: rune >= 0x20 && rune <= 0x7E ? rune : 0x01000000 | rune,
          scancode: null,
          extended: false,
          unicode: rune,
        ),
        true,
      );
      client.sendKey(
        RemoteKeyEvent(
          keysym: rune >= 0x20 && rune <= 0x7E ? rune : 0x01000000 | rune,
          scancode: null,
          extended: false,
          unicode: rune,
        ),
        false,
      );
    }
  }

  void closeClient() {
    _client?.close();
    _client = null;
  }

  void close() {
    closeClient();
    framebuffer.dispose();
  }
}

class RemoteSessionManager extends ChangeNotifier {
  final List<RemoteSession> _sessions = [];
  String? _activeId;

  List<RemoteSession> get sessions => List.unmodifiable(_sessions);
  bool get hasSessions => _sessions.isNotEmpty;

  String? get activeId => _activeId;

  RemoteSession? get active {
    if (_sessions.isEmpty) return null;
    for (final session in _sessions) {
      if (session.id == _activeId) return session;
    }
    return _sessions.last;
  }

  RemoteSession open({
    required String title,
    required HostProtocol protocol,
    required String address,
    required int port,
    String? username,
    String? password,
    String? domain,
    int width = 1280,
    int height = 800,
  }) {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final session = RemoteSession(
      id: id,
      title: title,
      protocol: protocol,
      width: protocol == HostProtocol.vnc ? 1024 : width,
      height: protocol == HostProtocol.vnc ? 768 : height,
    );
    session
      ..address = address
      ..port = port
      ..username = username
      ..password = password
      ..domain = domain
      ..requestedWidth = width
      ..requestedHeight = height;

    _sessions.add(session);
    _activeId = id;
    _start(session, protocol);
    // Run after the client is attached so the freshly started (or background)
    // session gets the correct visibility state.
    _syncVisibility();
    notifyListeners();
    return session;
  }

  /// Adds an already-constructed session without starting a connection.
  /// Intended for tests only.
  @visibleForTesting
  void addSessionForTesting(RemoteSession session) {
    _sessions.add(session);
    _activeId = session.id;
    notifyListeners();
  }

  /// Only the active session is rendered, so background sessions must not
  /// decode their framebuffers. Without this, each additional open remote
  /// session decodes full frames on the UI isolate and the app freezes.
  void _syncVisibility() {
    final current = active;
    for (final session in _sessions) {
      session.setVisible(identical(session, current));
    }
  }

  void _start(RemoteSession session, HostProtocol protocol) {
    if (protocol == HostProtocol.rdp) {
      if (!RustEngine.available) {
        session.markError('RDP support is not available on this device.');
        return;
      }
      session.status = RemoteStatus.connecting;
      session.error = null;
      final adapter = RdpClientAdapter(session);
      session.attachClient(adapter);
      adapter.start(
        RdpConnectOptions(
          host: session.address,
          port: session.port,
          username: session.username ?? '',
          password: session.password ?? '',
          domain: session.domain,
          width: session.requestedWidth,
          height: session.requestedHeight,
          acceptInvalidCertificates: true,
        ),
      );
    } else if (protocol == HostProtocol.vnc) {
      session.status = RemoteStatus.connecting;
      session.error = null;
      final adapter = RfbClientAdapter(session);
      session.attachClient(adapter);
      adapter.start(session.address, session.port, session.password ?? '');
    }
  }

  void reconnect(String id) {
    final index = _sessions.indexWhere((session) => session.id == id);
    if (index < 0) return;
    final session = _sessions[index];
    session.closeClient();
    _start(session, session.protocol);
    _syncVisibility();
    notifyListeners();
  }

  /// Reconnects an RDP session at a new desktop size. The server negotiates
  /// the desktop dimensions during connection, so a resize is a reconnect.
  void resize(String id, int width, int height) {
    if (width <= 0 || height <= 0) return;
    final index = _sessions.indexWhere((session) => session.id == id);
    if (index < 0) return;
    final session = _sessions[index];
    if (session.protocol != HostProtocol.rdp) return;
    if (session.requestedWidth == width && session.requestedHeight == height) {
      return;
    }
    session.requestedWidth = width;
    session.requestedHeight = height;
    session.closeClient();
    _start(session, session.protocol);
    _syncVisibility();
    notifyListeners();
  }

  void setActive(String id) {
    if (_activeId == id) return;
    _activeId = id;
    _syncVisibility();
    notifyListeners();
  }

  void close(String id) {
    final index = _sessions.indexWhere((session) => session.id == id);
    if (index < 0) return;
    final session = _sessions.removeAt(index);
    session.close();
    session.dispose();
    if (_activeId == id) {
      _activeId = _sessions.isEmpty ? null : _sessions.last.id;
    }
    _syncVisibility();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in List.of(_sessions)) {
      session.close();
      session.dispose();
    }
    _sessions.clear();
    super.dispose();
  }
}

/// Drives an RDP session through the Rust engine.
class RdpClientAdapter implements RemoteClient {
  /// Each connection attempt gets a unique Rust session id. Reusing the
  /// session id on reconnect/resize races with the old engine thread's cleanup,
  /// which removes the registry entry keyed by that id and would cancel input
  /// (including pointer updates) for the new connection.
  RdpClientAdapter(RemoteSession session)
    : _session = session,
      _sessionId = '${session.id}:${DateTime.now().microsecondsSinceEpoch}';

  final RemoteSession _session;
  final String _sessionId;
  StreamSubscription<RdpEvent>? _subscription;

  void start(RdpConnectOptions options) {
    _subscription = RustEngine.startRdp(sessionId: _sessionId, options: options)
        .listen(
          _onEvent,
          onError: (Object error) => _session.markError('$error'),
          onDone: () {
            if (_session.status == RemoteStatus.connected ||
                _session.status == RemoteStatus.connecting) {
              _session.markDisconnected('Session ended');
            }
          },
        );
  }

  void _onEvent(RdpEvent event) {
    switch (event) {
      case RdpEvent_Connected(:final width, :final height):
        _session.updateDesktopSize(width, height);
        _session.markConnected();
      case RdpEvent_FrameUpdate(
        :final x,
        :final y,
        :final width,
        :final height,
        :final pixels,
      ):
        _session.framebuffer.apply(x, y, width, height, pixels);
        _session.framebuffer.flush();
      case RdpEvent_Clipboard(:final text):
        _session.setRemoteClipboard(text);
      case RdpEvent_Disconnected(:final reason):
        _session.markDisconnected(reason);
      case RdpEvent_Error(:final message):
        _session.markError(message);
    }
  }

  @override
  void sendKey(RemoteKeyEvent event, bool down) {
    final scancode = event.scancode;
    if (scancode != null) {
      RustEngine.sendKey(
        sessionId: _sessionId,
        scancode: scancode,
        pressed: down,
        extended: event.extended,
      );
    } else if (event.unicode != null) {
      RustEngine.sendUnicode(
        sessionId: _sessionId,
        codepoint: event.unicode!,
        pressed: down,
      );
    }
  }

  @override
  void sendPointer(int buttons, int x, int y) {
    RustEngine.sendPointer(
      sessionId: _sessionId,
      x: x,
      y: y,
      buttons: buttons,
      wheel: 0,
    );
  }

  @override
  void sendWheel(int buttons, int x, int y, int delta) {
    // RDP expresses wheel motion in WHEEL_DELTA units (120 per notch).
    RustEngine.sendPointer(
      sessionId: _sessionId,
      x: x,
      y: y,
      buttons: buttons,
      wheel: delta * 120,
    );
  }

  @override
  void sendClipboard(String text) {
    // RDP clipboard (CLIPRDR) is not wired up yet.
  }

  @override
  void setVisible(bool visible) {
    RustEngine.setVisible(sessionId: _sessionId, visible: visible);
  }

  @override
  void close() {
    _subscription?.cancel();
    _subscription = null;
    RustEngine.closeRdp(sessionId: _sessionId);
  }
}

/// Drives a VNC session using the pure-Dart RFB client.
class RfbClientAdapter implements RemoteClient {
  RfbClientAdapter(this._session);

  final RemoteSession _session;
  RfbClient? _client;

  void start(String host, int port, String password) {
    final client = RfbClient(
      onFramebufferUpdate: (x, y, w, h, pixels) {
        _session.framebuffer.apply(x, y, w, h, pixels);
        _session.framebuffer.flush();
      },
      onDesktopResize: (width, height) =>
          _session.updateDesktopSize(width, height),
      onClipboard: (text) => _session.setRemoteClipboard(text),
      onClosed: () => _session.markDisconnected('Connection closed'),
      onError: (message) => _session.markError(message),
      readRegion: (x, y, w, h) => _session.framebuffer.copyRegion(x, y, w, h),
    );
    _client = client;
    client
        .connect(host, port, password)
        .then((_) {
          _session.markConnected();
        })
        .catchError((Object error) {
          _session.markError('$error');
        });
  }

  @override
  void sendKey(RemoteKeyEvent event, bool down) {
    final keysym = event.keysym;
    if (keysym != null) _client?.sendKey(keysym, down);
  }

  @override
  void sendPointer(int buttons, int x, int y) {
    // RemoteClient uses 1=left, 2=right, 4=middle; RFB uses 1=left,
    // 2=middle, 4=right. Remap so secondary clicks land on the right button.
    var rfb = 0;
    if (buttons & 1 != 0) rfb |= 1;
    if (buttons & 2 != 0) rfb |= 4;
    if (buttons & 4 != 0) rfb |= 2;
    _client?.sendPointer(rfb, x, y);
  }

  @override
  void sendWheel(int buttons, int x, int y, int delta) {
    final client = _client;
    if (client == null) return;
    // RFB exposes scrolling through the classic mouse buttons 4 (up) / 5
    // (down): press then release while the pointer stays put.
    final button = delta > 0 ? 4 : 5;
    client.sendPointer(button, x, y);
    client.sendPointer(0, x, y);
  }

  @override
  void sendClipboard(String text) {
    _client?.sendClipboard(text);
  }

  @override
  void setVisible(bool visible) {
    // Framebuffer decode is already gated per-session, which is enough for the
    // pure-Dart RFB path.
  }

  @override
  void close() {
    _client?.close();
    _client = null;
  }
}
