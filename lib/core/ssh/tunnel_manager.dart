import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../crypto/vault.dart';
import '../debug_log.dart';
import 'android_tunnel_keepalive.dart';
import 'host_key_store.dart';
import 'ssh_service.dart';
import 'tunnel_service.dart';

/// Runtime state of a single tunnel.
enum TunnelStatus { stopped, connecting, running, error }

class RunningTunnel {
  final String id;

  /// The saved configuration this runtime entry was started from.
  final Tunnel config;

  TunnelStatus status = TunnelStatus.stopped;
  String? error;

  /// Bind port actually allocated by the OS (for local / dynamic forwards
  /// where the user picked `bindPort == 0`).
  int? actualBindPort;

  SSHClient? client;
  TunnelForward? forward;

  /// Connection counters refreshed via [TunnelForward] callbacks.
  int activeConnections = 0;
  int totalConnections = 0;
  DateTime? connectedAt;

  RunningTunnel(this.id, this.config);
}

/// Owns every running standalone tunnel in the app.
///
/// Each running tunnel holds its own authenticated [SSHClient] (no shell) and
/// one or more attached [TunnelForward] objects. The manager exposes start /
/// stop / restart actions and is consumed via Riverpod as
/// [TunnelManager].
class TunnelManager extends ChangeNotifier {
  final AppDatabase _db;
  final Vault _vault;
  final SshService _ssh;
  final HostKeyStore _hostKeyStore;

  final Map<String, RunningTunnel> _running = {};

  /// In-flight lazy reconnects keyed by tunnel id, so several Chrome tabs
  /// hitting a dead tunnel share one SSH reconnect.
  final Map<String, Future<void>> _reconnectInFlight = {};

  /// Pending host-key verifications keyed by tunnel id. Resolved via
  /// [resolveHostKeyVerification].
  final Map<String, Completer<bool>> _pendingVerifications = {};

  TunnelManager({
    required this._db,
    required this._vault,
    required this._ssh,
    required this._hostKeyStore,
  });

  /// Snapshot view of all currently-running tunnels.
  List<RunningTunnel> get all => _running.values.toList(growable: false);

  RunningTunnel? statusOf(String id) => _running[id];

  /// Starts every saved tunnel whose `autoStart` flag is set.
  Future<void> startAllAuto() async {
    final tunnels = await _db.allTunnels();
    final auto = tunnels.where((t) => t.autoStart).toList(growable: false);
    if (auto.isEmpty) return;
    writeDebugLog('tunnel: auto-starting ${auto.length} tunnel(s)');
    for (final t in auto) {
      if (!_running.containsKey(t.id)) {
        // Best-effort; failures are surfaced through the per-tunnel status.
        unawaited(start(t));
      }
    }
  }

  Future<void> start(Tunnel tunnel) async {
    // A failed (or stopped) entry must be restartable; only an active
    // attempt blocks a new one.
    final existing = _running[tunnel.id];
    if (existing != null &&
        existing.status != TunnelStatus.error &&
        existing.status != TunnelStatus.stopped) {
      return;
    }
    final rt = RunningTunnel(tunnel.id, tunnel)
      ..status = TunnelStatus.connecting;
    _running[tunnel.id] = rt;
    unawaited(_logEvent(tunnel, 'info',
        'Starting ${tunnel.type} forward on ${tunnel.bindAddress}:'
        '${tunnel.bindPort ?? '(auto)'}'));
    notifyListeners();

    try {
      final creds = await _resolveCredentialsForTunnel(tunnel);
      if (creds == null) {
        throw StateError(
          tunnel.hostId != null
              ? 'No usable credentials for "${tunnel.name}": the linked host '
                  'has no username/password/key configured.'
              : 'No usable credentials for "${tunnel.name}": set the server '
                  'address, username and password/key on the tunnel.',
        );
      }
      // Diagnosability: record exactly what will be attempted (no secrets).
      unawaited(_logEvent(tunnel, 'info',
          'Connecting to ${creds.address}:${creds.port} as '
          '"${creds.username}" (${creds.authType} auth)'
          '${tunnel.hostId != null ? ", host-linked" : ", standalone"}'));

      final keyMaterial = await _loadKeyMaterial(creds.keyId);

      final client = await _ssh.connectClient(
        host: creds.address,
        port: creds.port,
        username: creds.username,
        password: creds.password,
        privateKeys: keyMaterial.$1,
        passphrase: keyMaterial.$2,
        onVerifyHostKey: (type, fingerprint) =>
            _verifyHostKey(tunnel.id, creds.address, creds.port, type, fingerprint),
      );

      rt.client = client;

      switch (tunnel.type) {
        case 'local':
          await _startLocal(rt, client, tunnel);
          break;
        case 'dynamic':
          await _startDynamic(rt, client, tunnel);
          break;
        case 'remote':
          await _startRemote(rt, client, tunnel);
          break;
        default:
          throw StateError('Unknown tunnel type: ${tunnel.type}');
      }

      rt.status = TunnelStatus.running;
      rt.connectedAt = DateTime.now();
      _watch(rt, client);
      _syncKeepAlive();
      unawaited(_logEvent(tunnel, 'info',
          'Running: ${tunnel.type} ${tunnel.bindAddress}:'
          '${rt.actualBindPort} via ${creds.address}:${creds.port}'));
      notifyListeners();
    } catch (e, st) {
      rt.error = _friendlyError(e);
      rt.status = TunnelStatus.error;
      unawaited(_logEvent(
        tunnel,
        'error',
        '${_friendlyError(e)}\n\nDetails: $e\n\nStack trace:\n$st',
      ));
      try {
        await rt.forward?.close();
      } catch (_) {}
      try {
        rt.client?.close();
      } catch (_) {}
      rt.forward = null;
      rt.client = null;
      notifyListeners();
      _syncKeepAlive();
    }
  }

  Future<void> stop(String id) async {
    final rt = _running.remove(id);
    if (rt == null) return;
    unawaited(_logEvent(rt.config, 'info',
        'Stopped (was ${rt.status.name}, '
        '${rt.totalConnections} connection(s) served)'));
    try {
      if (rt.forward?.remoteForwardHandle != null) {
        await rt.client?.cancelForwardRemote(rt.forward!.remoteForwardHandle!);
      }
    } catch (_) {}
    try {
      await rt.forward?.close();
    } catch (_) {}
    try {
      rt.client?.close();
    } catch (_) {}
    notifyListeners();
    _syncKeepAlive();
  }

  Future<void> restart(Tunnel tunnel) async {
    await stop(tunnel.id);
    await start(tunnel);
  }

  Future<void> stopAll() async {
    final ids = _running.keys.toList();
    for (final id in ids) {
      await stop(id);
    }
  }

  // ----- self-healing ---------------------------------------------------------

  /// Watches the tunnel's SSH transport; when Android suspends the app or
  /// the network changes underneath, the connection dies silently and the
  /// card would otherwise keep saying "running" while every forwarded
  /// connection fails with
  /// `SSHStateError: connection closed while waiting for channel open`.
  void _watch(RunningTunnel rt, SSHClient client) {
    unawaited(client.done.whenComplete(() {
      // Ignore deaths of clients we replaced (reconnect) or tunnels the
      // user stopped (stop() removes the entry from _running).
      if (!_identicalTo(rt.id, rt, client)) return;
      unawaited(_onClientLost(rt));
    }));
  }

  bool _identicalTo(String id, RunningTunnel rt, SSHClient client) =>
      _running[id] == rt && rt.client == client;

  Future<void> _onClientLost(RunningTunnel rt) async {
    rt.status = TunnelStatus.connecting;
    rt.error = null;
    rt.connectedAt = null;
    notifyListeners();
    _syncKeepAlive();
    unawaited(_logEvent(
        rt.config, 'error', 'Connection lost — reconnecting automatically'));
    // Backoff while the app may still be network-restricted in the
    // background; each attempt also serves as the "is it back yet?" ping.
    for (final delay in [
      Duration.zero,
      const Duration(seconds: 5),
      const Duration(seconds: 15),
      const Duration(seconds: 60),
    ]) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_running[rt.id] != rt) return;
      try {
        await _reconnectOnce(rt);
        return;
      } catch (_) {
        // Try again after the next backoff slot.
      }
    }
    if (_running[rt.id] != rt) return;
    rt.status = TunnelStatus.error;
    rt.error = 'Connection lost and could not be re-established. Check the '
        'network, then start the tunnel again. (It also heals itself the '
        'next time something connects to it.)';
    notifyListeners();
    _syncKeepAlive();
    unawaited(_logEvent(rt.config, 'error',
        'Reconnect failed after repeated attempts; tunnel marked as error'));
  }

  /// Reconnects [rt] once, coalescing concurrent callers into a single
  /// attempt. Local forwards keep their listener socket: the caller's
  /// accept handler picks up the fresh [RunningTunnel.client].
  Future<void> _reconnectOnce(RunningTunnel rt) {
    final pending = _reconnectInFlight[rt.id];
    if (pending != null) return pending;
    final completer = Completer<void>();
    _reconnectInFlight[rt.id] = completer.future;
    () async {
      try {
        final current = rt.client;
        if (current != null && !current.isClosed) return;
        await _reconnectNow(rt);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _reconnectInFlight.remove(rt.id);
      }
    }();
    return completer.future;
  }

  Future<void> _reconnectNow(RunningTunnel rt) async {
    if (_running[rt.id] != rt) return;
    final tunnel = rt.config;
    final creds = await _resolveCredentialsForTunnel(tunnel);
    if (creds == null) {
      throw StateError('Credentials for "${tunnel.name}" are no longer '
          'available.');
    }
    final keyMaterial = await _loadKeyMaterial(creds.keyId);
    final client = await _ssh.connectClient(
      host: creds.address,
      port: creds.port,
      username: creds.username,
      password: creds.password,
      privateKeys: keyMaterial.$1,
      passphrase: keyMaterial.$2,
      onVerifyHostKey: (type, fingerprint) => _verifyHostKey(
          tunnel.id, creds.address, creds.port, type, fingerprint),
    );
    if (_running[rt.id] != rt) {
      // Stopped while handshaking.
      client.close();
      return;
    }
    final old = rt.client;
    rt.client = client;
    try {
      old?.close();
    } catch (_) {}

    switch (tunnel.type) {
      case 'local':
        // The listener socket survives; only the SSH side is replaced.
        break;
      case 'dynamic':
      case 'remote':
        // These forward types are bound to the dead client, so they must
        // be rebuilt on the fresh connection.
        try {
          await rt.forward?.close();
        } catch (_) {}
        rt.forward = null;
        if (tunnel.type == 'dynamic') {
          await _startDynamic(rt, client, tunnel);
        } else {
          await _startRemote(rt, client, tunnel);
        }
        break;
      default:
        break;
    }

    rt.status = TunnelStatus.running;
    rt.error = null;
    rt.connectedAt = DateTime.now();
    _watch(rt, client);
    _syncKeepAlive();
    notifyListeners();
    unawaited(_logEvent(tunnel, 'info',
        'Reconnected: ${tunnel.type} ${tunnel.bindAddress}:'
        '${rt.actualBindPort} via ${creds.address}:${creds.port}'));
  }

  /// Opens a forwarded channel, transparently reconnecting the tunnel's
  /// SSH client when it died (Android backgrounding, network switch).
  /// This is the "open the URL in Chrome" path: Chrome's connection wakes
  /// the app and the tunnel heals itself before serving the request.
  Future<SSHForwardChannel> _openHealedLocalChannel(
    RunningTunnel rt, {
    required String remoteHost,
    required int remotePort,
  }) async {
    var client = rt.client;
    if (client == null || client.isClosed) {
      await _reconnectOnce(rt);
      client = rt.client;
    }
    try {
      return await _ssh.openForwardLocalChannel(client!,
          remoteHost: remoteHost, remotePort: remotePort);
    } on SSHStateError {
      // Died between the liveness check and the channel open.
      await _reconnectOnce(rt);
      return await _ssh.openForwardLocalChannel(rt.client!,
          remoteHost: remoteHost, remotePort: remotePort);
    }
  }

  /// Holds the Android foreground service while any tunnel is meant to be
  /// up, so the process (and its sockets) survive being backgrounded.
  void _syncKeepAlive() {
    final active = _running.values.any((rt) =>
        rt.status == TunnelStatus.running ||
        rt.status == TunnelStatus.connecting);
    if (active) {
      unawaited(AndroidTunnelKeepAlive.activate());
    } else {
      unawaited(AndroidTunnelKeepAlive.deactivate());
    }
  }

  /// Called by the UI when the user accepts/rejects an unknown host key.
  void resolveHostKeyVerification(String tunnelId, {required bool accept}) {
    final completer = _pendingVerifications.remove(tunnelId);
    if (completer == null) return;
    if (!accept) {
      final rt = _running[tunnelId];
      if (rt != null) {
        rt.error = 'Connection cancelled: host key not trusted.';
        rt.status = TunnelStatus.error;
        notifyListeners();
      }
    }
    completer.complete(accept);
  }

  @override
  void dispose() {
    unawaited(stopAll());
    super.dispose();
  }

  /// Records a tunnel event in the device-local tunnel log (visible in the
  /// Logs screen, Tunnels tab) and mirrors it to the temp debug file.
  Future<void> _logEvent(
    Tunnel tunnel,
    String level,
    String message,
  ) async {
    writeDebugLog('tunnel[${tunnel.id}] $level: $message');
    try {
      await _db.insertTunnelLog(
        TunnelLogsCompanion.insert(
          id: const Uuid().v4(),
          tunnelId: tunnel.id,
          tunnelName: tunnel.name,
          tunnelType: tunnel.type,
          level: level,
          message: message,
          createdAt: drift.Value(DateTime.now()),
        ),
      );
    } catch (_) {
      // Logging must never break tunneling.
    }
  }

  // ----- internal helpers --------------------------------------------------

  /// Resolves the credentials a tunnel connects with.
  ///
  /// Host-linked tunnels use ONLY the host's (or its group's) credentials —
  /// exactly like opening a terminal for that host. The inline fields on the
  /// tunnel row are ignored there so stale values can never silently
  /// override the working host configuration. Standalone tunnels use ONLY
  /// their own inline fields.
  Future<_ResolvedCreds?> _resolveCredentialsForTunnel(Tunnel tunnel) async {
    if (tunnel.hostId != null) {
      return _resolveFromHost(tunnel);
    }
    return _resolveStandalone(tunnel);
  }

  Future<_ResolvedCreds?> _resolveFromHost(Tunnel tunnel) async {
    final host = await _db.findHostById(tunnel.hostId!);
    if (host == null) return null;

    Group? group;
    if (host.groupId != null) {
      final groups = await _db.allGroups();
      for (final g in groups) {
        if (g.id == host.groupId) {
          group = g;
          break;
        }
      }
    }

    // Same resolution order as the terminal path (connection_helpers.dart):
    // the host's own credentials win, then the group's.
    final username =
        host.username.isNotEmpty ? host.username : (group?.username ?? '');
    final authType =
        host.authType.isNotEmpty ? host.authType : (group?.authType ?? '');

    String? password;
    String? keyId;
    if (authType == 'key') {
      keyId = host.keyId ?? group?.keyId;
    } else {
      final encrypted = host.encryptedPassword ?? group?.encryptedPassword;
      if (encrypted != null) {
        try {
          password = await _vault.decrypt(encrypted);
        } catch (_) {
          password = null;
        }
      }
    }

    if (username.isEmpty) return null;
    if (keyId == null && (password == null || password.isEmpty)) {
      return null;
    }

    return _ResolvedCreds(
      address: host.address,
      port: host.port,
      username: username,
      authType: keyId != null ? 'key' : 'password',
      password: password,
      keyId: keyId,
    );
  }

  Future<_ResolvedCreds?> _resolveStandalone(Tunnel tunnel) async {
    final address = tunnel.address ?? '';
    final username = tunnel.username ?? '';
    if (address.isEmpty || username.isEmpty) return null;

    String? password;
    String? keyId;
    if (tunnel.authType == 'key') {
      keyId = tunnel.keyId;
    } else if (tunnel.encryptedPassword != null) {
      try {
        password = await _vault.decrypt(tunnel.encryptedPassword!);
      } catch (_) {
        password = null;
      }
    } else {
      keyId = tunnel.keyId;
    }

    if (keyId == null && (password == null || password.isEmpty)) {
      return null;
    }

    return _ResolvedCreds(
      address: address,
      port: tunnel.port,
      username: username,
      authType: keyId != null ? 'key' : 'password',
      password: password,
      keyId: keyId,
    );
  }

  Future<(List<String>, String?)> _loadKeyMaterial(String? identityId) async {
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
    String tunnelId,
    String address,
    int port,
    String type,
    String fingerprint,
  ) async {
    try {
      final trusted = await _hostKeyStore.isTrusted(
        address: address,
        port: port,
        keyType: type,
        fingerprint: fingerprint,
      );
      if (trusted) return true;
    } on HostKeyMismatchError catch (e) {
      final rt = _running[tunnelId];
      if (rt != null) {
        rt.error = 'Host key mismatch — refusing to connect.';
        rt.status = TunnelStatus.error;
        notifyListeners();
        unawaited(_logEvent(rt.config, 'error',
            'Host key mismatch for $address:$port: $e'));
      }
      return false;
    }

    final autoAccept = await _db.getSetting('autoAcceptHostKeys') == 'true';
    if (autoAccept) {
      await _hostKeyStore.trust(
        address: address,
        port: port,
        keyType: type,
        fingerprint: fingerprint,
      );
      return true;
    }

    final completer = Completer<bool>();
    _pendingVerifications[tunnelId] = completer;
    final rt = _running[tunnelId];
    if (rt != null) {
      rt.status = TunnelStatus.connecting;
      rt.error = 'Awaiting host-key verification...';
      notifyListeners();
    }
    return completer.future.then((accepted) {
      if (accepted) {
        return _hostKeyStore
            .trust(
              address: address,
              port: port,
              keyType: type,
              fingerprint: fingerprint,
            )
            .then((_) => true);
      }
      return false;
    });
  }

  Future<void> _startLocal(
    RunningTunnel rt,
    SSHClient client,
    Tunnel tunnel,
  ) async {
    final forward = TunnelForward(
      id: tunnel.id,
      type: 'local',
      bindAddress: tunnel.bindAddress,
      requestedBindPort: tunnel.bindPort,
      targetHost: tunnel.targetHost ?? 'localhost',
      targetPort: tunnel.targetPort ?? 0,
    );
    final boundPort = await forward.bindLocal(
      (clientSocket) => _openHealedLocalChannel(
        rt,
        remoteHost: forward.targetHost!,
        remotePort: forward.targetPort!,
      ),
      onError: (e, st) {
        unawaited(_logEvent(
          tunnel,
          'error',
          'Forward error: $e\n\nStack trace:\n$st',
        ));
      },
    );
    rt.actualBindPort = boundPort;
    rt.forward = forward;
  }

  Future<void> _startDynamic(
    RunningTunnel rt,
    SSHClient client,
    Tunnel tunnel,
  ) async {
    final forward = TunnelForward(
      id: tunnel.id,
      type: 'dynamic',
      bindAddress: tunnel.bindAddress,
      requestedBindPort: tunnel.bindPort,
    );
    final dyn = await client.forwardDynamic(
      bindHost: tunnel.bindAddress,
      bindPort: tunnel.bindPort,
    );
    forward.attachDynamic(dyn);
    rt.actualBindPort = dyn.port;
    rt.forward = forward;
  }

  Future<void> _startRemote(
    RunningTunnel rt,
    SSHClient client,
    Tunnel tunnel,
  ) async {
    final forward = TunnelForward(
      id: tunnel.id,
      type: 'remote',
      bindAddress: tunnel.bindAddress,
      requestedBindPort: tunnel.bindPort,
    );
    final rf = await client.forwardRemote(
      host: tunnel.bindAddress == '127.0.0.1' ? 'localhost' : tunnel.bindAddress,
      port: tunnel.bindPort,
    );
    if (rf == null) {
      throw StateError('Server refused remote-forward on '
          '${tunnel.bindAddress}:${tunnel.bindPort}');
    }
    forward.attachRemote(rf);
    rt.actualBindPort = rf.port;
    rt.forward = forward;
  }
}

class _ResolvedCreds {
  final String address;
  final int port;
  final String username;
  final String authType;
  final String? password;
  final String? keyId;

  const _ResolvedCreds({
    required this.address,
    required this.port,
    required this.username,
    required this.authType,
    this.password,
    this.keyId,
  });
}

/// Maps raw SSH/IO exceptions to actionable messages for the tunnel card
/// and the Logs screen. The full exception and stack trace stay in the log
/// entry below the friendly text.
String _friendlyError(Object e) {
  if (e is SSHAuthFailError) {
    return 'Authentication failed — the server rejected every method '
        '(key, password). Check the username and the password/key '
        'configured on the tunnel or its linked host. If the server only '
        'accepts interactive logins, try re-entering the password.';
  }
  if (e is SocketException) {
    final target = e.address?.host ?? '';
    final suffix = target.isEmpty ? '' : ' to $target';
    return 'Could not connect$suffix — ${e.message}. '
        'Check the host address, port and your network.';
  }
  return e.toString();
}
