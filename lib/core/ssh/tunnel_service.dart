import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// One running SSH forward rule attached to an [SSHClient] (no shell).
///
/// Owns the [ServerSocket] accept loop for local forwards and the
/// dynamic/remote forward handles returned by dartssh2. Closing this object
/// tears down every resource it owns.
class TunnelForward {
  final String id;
  final String type; // 'local' | 'dynamic' | 'remote'
  final String bindAddress;
  final int? requestedBindPort;

  /// For local forwards: the remote target host:port.
  final String? targetHost;
  final int? targetPort;

  ServerSocket? _serverSocket;
  SSHDynamicForward? _dynamicForward;
  SSHRemoteForward? _remoteForward;

  /// Per-rule connection count, updated as clients connect/disconnect.
  int activeConnections = 0;
  int totalConnections = 0;

  bool get isClosed => _closed;
  bool _closed = false;

  TunnelForward({
    required this.id,
    required this.type,
    required this.bindAddress,
    this.requestedBindPort,
    this.targetHost,
    this.targetPort,
  }) {
    if (type == 'local') {
      assert(targetHost != null && targetPort != null);
    }
  }

  /// Binds the local listener socket for `-L`. The accept loop calls
  /// [openChannel] per accepted client to obtain an SSHForwardChannel.
  Future<int> bindLocal(
    Future<SSHForwardChannel> Function(Socket client) openChannel, {
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    final socket = await ServerSocket.bind(
      bindAddress,
      requestedBindPort ?? 0,
    );
    _serverSocket = socket;
    socket.listen(
      (client) => _handleLocalClient(client, openChannel, onError),
      onError: (e, st) => onError?.call(e, st),
      cancelOnError: false,
    );
    return socket.port;
  }

  Future<void> _handleLocalClient(
    Socket client,
    Future<SSHForwardChannel> Function(Socket) openChannel,
    void Function(Object, StackTrace)? onError,
  ) async {
    try {
      final channel = await openChannel(client);
      activeConnections++;
      totalConnections++;
      client.listen(
        channel.sink.add,
        onError: (_) {},
        onDone: () {
          try {
            channel.sink.close();
          } catch (_) {}
        },
      );
      channel.stream.listen(
        client.add,
        onError: (_) {},
        onDone: () {
          try {
            client.close();
          } catch (_) {}
        },
      );
      unawaited(channel.done.whenComplete(() {
        activeConnections = (activeConnections - 1).clamp(0, 1 << 30);
        try {
          client.destroy();
        } catch (_) {}
      }));
    } catch (e, st) {
      onError?.call(e, st);
      try {
        client.destroy();
      } catch (_) {}
    }
  }

  void attachDynamic(SSHDynamicForward forward) {
    _dynamicForward = forward;
  }

  void attachRemote(SSHRemoteForward forward) {
    _remoteForward = forward;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _serverSocket?.close();
    } catch (_) {}
    try {
      await _dynamicForward?.close();
    } catch (_) {}
    _serverSocket = null;
    _dynamicForward = null;
    _remoteForward = null;
  }

  /// Returns the remote-forward handle so the manager can later cancel it
  /// via [SSHClient.cancelForwardRemote].
  SSHRemoteForward? get remoteForwardHandle => _remoteForward;
}
