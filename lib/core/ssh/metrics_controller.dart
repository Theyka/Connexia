import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../crypto/vault.dart';
import '../db/database.dart';
import 'host_credentials.dart';
import 'host_key_store.dart';
import 'metrics_service.dart';
import 'ssh_service.dart';

enum HostPollState { idle, connecting, ok, error }

class HostMetricsState {
  final HostPollState pollState;
  final String? error;
  final MetricSample? last;
  final String? hostname;
  final DateTime? lastUpdated;

  const HostMetricsState({
    this.pollState = HostPollState.idle,
    this.error,
    this.last,
    this.hostname,
    this.lastUpdated,
  });

  bool get isLive => pollState == HostPollState.ok && last != null;

  HostMetricsState copyWith({
    HostPollState? pollState,
    String? error,
    MetricSample? last,
    ValueGetter<String?>? hostname,
    DateTime? lastUpdated,
    bool clearError = false,
  }) => HostMetricsState(
    pollState: pollState ?? this.pollState,
    error: clearError ? null : (error ?? this.error),
    last: last ?? this.last,
    hostname: hostname != null ? hostname() : this.hostname,
    lastUpdated: lastUpdated ?? this.lastUpdated,
  );
}

class _HostConn {
  final String hostId;
  SSHClient? client;
  CpuCounters? prevCpu;
  double? prevRxCum;
  double? prevTxCum;
  DateTime? prevTs;
  DateTime lastPollAt;

  String username = '';
  String? password;

  _HostConn(this.hostId) : lastPollAt = DateTime.now();
}

class HostPoliciesState {
  final bool loading;
  final String? error;
  final bool unsupported;
  final List<ServiceInfo> units;
  final String crontab;
  final bool cronError;

  const HostPoliciesState({
    this.loading = false,
    this.error,
    this.unsupported = false,
    this.units = const [],
    this.crontab = '',
    this.cronError = false,
  });

  List<String> get cronLines =>
      crontab.split('\n').where((l) => l.trim().isNotEmpty).toList();
}

class MetricsController extends ChangeNotifier {
  final Vault vault;
  final AppDatabase db;
  final HostKeyStore hostKeyStore;
  final SshService ssh;
  final VoidCallback _onChanged;

  final List<String> _watchlist = [];

  final Map<String, _HostConn> _conns = {};
  final Map<String, HostMetricsState> _states = {};

  final Map<String, HostPoliciesState> _servicesStates = {};
  final Map<String, HostPoliciesState> _cronStates = {};

  String? selectedHostId;
  Timer? _liveTimer;
  Timer? _bgTimer;

  final Map<String, Future<void>> _polling = {};

  final Set<String> _cardsPending = {};

  final Set<String> _needsCredentials = {};

  final Map<String, ({String username, String password})> _typedCredentials =
      {};
  bool _disposed = false;

  MetricsController({
    required this.vault,
    required this.db,
    required this.hostKeyStore,
    required this.ssh,
    required this._onChanged,
  }) {
    _load();
  }

  List<String> get watchlist => List.unmodifiable(_watchlist);
  HostMetricsState stateOf(String hostId) =>
      _states[hostId] ?? const HostMetricsState();
  HostPoliciesState servicesOf(String hostId) =>
      _servicesStates[hostId] ?? const HostPoliciesState();
  HostPoliciesState cronOf(String hostId) =>
      _cronStates[hostId] ?? const HostPoliciesState();
  bool cardsPending(String hostId) => _cardsPending.contains(hostId);
  bool needsCredentials(String hostId) => _needsCredentials.contains(hostId);

  Future<void> _load() async {
    final raw = await db.getSetting('metricsWatchlist');
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = List<String>.from((jsonDecode(raw) as List));
        _watchlist
          ..clear()
          ..addAll(list);
      } catch (_) {}
    }
    if (_disposed) return;
    if (_watchlist.isNotEmpty) {
      selectedHostId ??= _watchlist.first;
      _cardsPending.add(selectedHostId!);
      _startTimers();
      unawaited(pollAll());
    }
    _onChanged();
  }

  Future<void> toggleWatch(String hostId) async {
    if (_watchlist.remove(hostId)) {
      if (selectedHostId == hostId) {
        selectedHostId = _watchlist.isNotEmpty ? _watchlist.first : null;
      }
      final conn = _conns.remove(hostId);
      conn?.client?.close();
      _states.remove(hostId);
      _servicesStates.remove(hostId);
      _cronStates.remove(hostId);
      _cardsPending.remove(hostId);
      _needsCredentials.remove(hostId);
    } else {
      _watchlist.add(hostId);
      selectedHostId = hostId;
      _cardsPending.add(hostId);
      _startTimers();
      unawaited(poll(_watchlist.last));
    }
    await _persistWatchlist();
    _onChanged();
  }

  Future<void> select(String hostId) async {
    selectedHostId = hostId;
    _cardsPending.add(hostId);
    _onChanged();
    unawaited(poll(hostId));
  }

  void provideCredentials(String hostId, String username, String password) {
    _typedCredentials[hostId] = (username: username, password: password);
    _needsCredentials.remove(hostId);
    final conn = _conns[hostId];
    conn?.client?.close();
    conn?.client = null;
    _cardsPending.add(hostId);
    _onChanged();
    unawaited(poll(hostId));
  }

  Future<void> _persistWatchlist() =>
      db.setSetting('metricsWatchlist', jsonEncode(_watchlist));

  void _startTimers() {
    _liveTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      final id = selectedHostId;
      if (id != null) unawaited(poll(id));
    });
    _bgTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(pollAll(skip: selectedHostId)),
    );
  }

  Future<void> pollAll({String? skip}) async {
    if (_watchlist.isEmpty) return;
    for (final id in List<String>.from(_watchlist)) {
      if (id == skip) continue;
      unawaited(poll(id));
    }
  }

  Future<void> poll(String hostId) {
    final running = _polling[hostId];
    if (running != null) return running;
    final future = _poll(hostId).whenComplete(() {
      _polling.remove(hostId);
      if (!_disposed) _onChanged();
    });
    _polling[hostId] = future;
    return future;
  }

  Future<void> _poll(String hostId) async {
    try {
      final host = await db.findHostById(hostId);
      if (host == null || !_watchlist.contains(hostId)) return;
      if (_needsCredentials.contains(hostId)) return;

      final existing = _states[hostId];
      if (existing == null || existing.pollState != HostPollState.ok) {
        _states[hostId] = (existing ?? const HostMetricsState()).copyWith(
          pollState: HostPollState.connecting,
        );
        _onChanged();
      }

      final typed = _typedCredentials[hostId];
      final creds = typed != null
          ? null
          : await resolveHostCredentials(db, vault, host);
      final username = typed?.username ?? creds?.username ?? '';
      final password = typed?.password ?? creds?.password;
      if (typed == null &&
          (creds == null || (creds.authType != 'key' && password == null))) {
        _needsCredentials.add(hostId);
        _states[hostId] = _states[hostId]!.copyWith(
          pollState: HostPollState.error,
          error: creds == null
              ? 'No saved sign-in for this host'
              : 'No saved password for this host',
        );
        _onChanged();
        return;
      }

      List<String> pems = const [];
      String? keyPassphrase;
      if (typed == null && creds!.authType == 'key') {
        final identity = await db.findIdentityById(creds.keyId!);
        if (identity == null) {
          _states[hostId] = _states[hostId]!.copyWith(
            pollState: HostPollState.error,
            error: 'Identity not found',
          );
          _onChanged();
          return;
        }
        try {
          pems = [await vault.decrypt(identity.encryptedKeyPem)];
          if (identity.encryptedPassphrase != null) {
            keyPassphrase = await vault.decrypt(identity.encryptedPassphrase!);
          }
        } catch (e) {
          _states[hostId] = _states[hostId]!.copyWith(
            pollState: HostPollState.error,
            error: 'Vault error: $e',
          );
          _onChanged();
          return;
        }
      }

      var conn = _conns.putIfAbsent(hostId, () => _HostConn(hostId));
      conn
        ..username = username
        ..password = password;
      SSHClient client;
      try {
        client = await _ensureClient(
          conn,
          host: host,
          username: username,
          password: password,
          pems: pems,
          keyPassphrase: keyPassphrase,
        );
      } catch (e) {
        _states[hostId] = _states[hostId]!.copyWith(
          pollState: HostPollState.error,
          error: _friendly(e),
        );
        conn.client = null;

        if (_friendly(e) == 'Authentication failed') {
          _needsCredentials.add(hostId);
        }
        _onChanged();
        return;
      }

      final sample = await collectSample(client);

      final sample2 = _finalizeRates(conn, sample);
      _states[hostId] = _states[hostId]!.copyWith(
        pollState: HostPollState.ok,
        last: sample2,
        clearError: true,
        hostname: () => sample2.sysInfo?.hostname,
        lastUpdated: sample2.ts,
      );
      _onChanged();

      final cardsGaveUp =
          _gaveUp(_servicesStates[hostId]) || _gaveUp(_cronStates[hostId]);
      if (_cardsPending.remove(hostId) || cardsGaveUp) {
        unawaited(loadServices(hostId));
        unawaited(loadCron(hostId));
      }
      await _persist(host, sample2);
    } on TimeoutException {
      _states[hostId] =
          _states[hostId]?.copyWith(
            pollState: HostPollState.error,
            error: 'Timed out',
          ) ??
          const HostMetricsState(
            pollState: HostPollState.error,
            error: 'Timed out',
          );
      _onChanged();
    } catch (e) {
      _states[hostId] =
          _states[hostId]?.copyWith(
            pollState: HostPollState.error,
            error: _friendly(e),
          ) ??
          HostMetricsState(pollState: HostPollState.error, error: _friendly(e));
      final conn = _conns[hostId];
      conn?.client = null;
      _onChanged();
    }
  }

  MetricSample _finalizeRates(_HostConn conn, MetricSample s) {
    double? cpu;
    if (conn.prevCpu != null && s.cpuCounters != null) {
      final dTotal = s.cpuCounters!.total - conn.prevCpu!.total;
      final dIdle = s.cpuCounters!.idle - conn.prevCpu!.idle;
      if (dTotal > 0 && dIdle >= 0) {
        cpu = (1 - dIdle / dTotal) * 100;
        cpu = cpu.clamp(0, 100);
      }
    }
    if (s.cpuCounters != null) conn.prevCpu = s.cpuCounters;

    double rxRate;
    double txRate;
    var rxCum = 0.0;
    var txCum = 0.0;
    for (final i in s.ifaces) {
      rxCum += i.rxBytes;
      txCum += i.txBytes;
    }
    if (conn.prevRxCum != null &&
        conn.prevTs != null &&
        rxCum >= conn.prevRxCum!) {
      final dt = s.ts.difference(conn.prevTs!).inMilliseconds / 1000;
      if (dt > 0) {
        rxRate = (rxCum - conn.prevRxCum!) / dt;
        txRate = (txCum - conn.prevTxCum!) / dt;
      } else {
        rxRate = 0;
        txRate = 0;
      }
    } else {
      rxRate = 0;
      txRate = 0;
    }
    conn.prevRxCum = rxCum;
    conn.prevTxCum = txCum;
    conn.prevTs = s.ts;

    return MetricSample(
      ts: s.ts,
      cpuCounters: s.cpuCounters,
      cpuPct: cpu,
      memPct: s.memPct,
      memUsedMb: s.memUsedMb,
      memTotalMb: s.memTotalMb,
      disks: s.disks,
      ifaces: s.ifaces,
      load1: s.load1,
      load5: s.load5,
      load15: s.load15,
      temps: s.temps,
      procCount: s.procCount,
      uptimeSec: s.uptimeSec,
      ports: s.ports,
      logins: s.logins,
      procs: s.procs,
      sysInfo: s.sysInfo,
      netRxRate: rxRate,
      netTxRate: txRate,
      netRxCum: rxCum,
      netTxCum: txCum,
    );
  }

  Future<void> _persist(Host host, MetricSample s) async {
    final disk = s.disks.isNotEmpty ? s.disks.first : null;
    final hottest = s.hottestTemp;
    await db.insertHostMetric(
      HostMetricsCompanion.insert(
        hostId: host.id,
        ts: s.ts,
        cpuPct: Value(s.cpuPct),
        memPct: s.memPct,
        memUsedMb: Value(s.memUsedMb),
        memTotalMb: Value(s.memTotalMb),
        diskPct: Value(disk?.pct),
        diskUsedGb: Value(disk?.usedMb != null ? disk!.usedMb / 1024 : null),
        diskTotalGb: Value(disk?.totalMb != null ? disk!.totalMb / 1024 : null),
        netRx: Value(s.netRxRate),
        netTx: Value(s.netTxRate),
        netRxCum: Value(s.netRxCum),
        netTxCum: Value(s.netTxCum),
        load1: Value(s.load1),
        load5: Value(s.load5),
        load15: Value(s.load15),
        temp: Value(hottest?.celsius),
        procCount: Value(s.procCount),
        uptimeSec: Value(s.uptimeSec),
        sysInfo: Value(
          s.sysInfo == null
              ? null
              : [
                  s.sysInfo!.hostname,
                  s.sysInfo!.kernel,
                  s.sysInfo!.arch,
                  s.sysInfo!.prettyName,
                  s.sysInfo!.cpuModel,
                  s.sysInfo!.cores,
                ].join('|'),
        ),
      ),
    );
  }

  String _friendly(Object e) {
    final msg = e.toString();
    if (msg.contains('SSHAuthFail') || msg.toLowerCase().contains('auth')) {
      return 'Authentication failed';
    }
    if (msg.contains('SocketException')) {
      return 'Connection refused / unreachable';
    }
    if (msg.contains('HandshakeException')) return 'SSH handshake failed';
    if (e is TimeoutException) return 'Timed out';
    return msg.length > 180 ? msg.substring(0, 180) : msg;
  }

  Future<SSHClient> _ensureClient(
    _HostConn conn, {
    required Host host,
    required String username,
    required String? password,
    required List<String> pems,
    required String? keyPassphrase,
  }) async {
    final current = conn.client;
    if (current != null && !current.isClosed) return current;

    final autoAccept = await db.getSetting('autoAcceptHostKeys') == 'true';
    return await ssh
        .connectClient(
          host: host.address,
          port: host.port,
          username: username,
          password: password,
          privateKeys: pems,
          passphrase: keyPassphrase,
          onVerifyHostKey: (type, fingerprint) => _verifyBackground(
            host,
            type,
            fingerprint,
            autoAccept: autoAccept,
          ),
        )
        .then((client) {
          conn.client = client;
          conn.prevCpu = null;
          return client;
        });
  }

  Future<bool> _verifyBackground(
    Host host,
    String type,
    String fingerprint, {
    required bool autoAccept,
  }) async {
    try {
      final trusted = await hostKeyStore.isTrusted(
        address: host.address,
        port: host.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      if (trusted) return true;
    } on HostKeyMismatchError {
      return false;
    }
    if (autoAccept) {
      await hostKeyStore.trust(
        address: host.address,
        port: host.port,
        keyType: type,
        fingerprint: fingerprint,
      );
      return true;
    }
    _states[host.id] =
        _states[host.id]?.copyWith(
          pollState: HostPollState.error,
          error:
              'Host key not verified yet — connect once via a Terminal first',
        ) ??
        const HostMetricsState(
          pollState: HostPollState.error,
          error:
              'Host key not verified yet — connect once via a Terminal first',
        );
    _onChanged();
    return false;
  }

  bool _gaveUp(HostPoliciesState? p) =>
      p != null && !p.loading && p.error == 'Host is offline';

  Future<void> loadServices(String hostId) async {
    final previousServices = servicesOf(hostId);
    _servicesStates[hostId] = HostPoliciesState(
      loading: true,
      units: previousServices.units,
      unsupported: previousServices.unsupported,
    );
    _onChanged();
    final client = _conns[hostId]?.client;
    if (client == null) {
      await poll(hostId);
    }
    final c = _conns[hostId]?.client;
    if (c == null) {
      _servicesStates[hostId] = const HostPoliciesState(
        error: 'Host is offline',
      );
      _onChanged();
      return;
    }
    try {
      final units = await listServiceUnits(c);
      _servicesStates[hostId] = HostPoliciesState(
        units: units,
        unsupported: units.isEmpty,
      );
    } catch (e) {
      _servicesStates[hostId] = HostPoliciesState(error: e.toString());
    }
    _onChanged();
  }

  Future<void> serviceAction(String hostId, String unit, String action) async {
    final c = _conns[hostId]?.client;
    if (c == null) return;
    try {
      final conn = _conns[hostId]!;
      final err = await runServiceAction(
        c,
        unit,
        action,
        sudoPassword: conn.username == 'root' ? null : conn.password,
      );
      if (err != null) {
        _servicesStates[hostId] = HostPoliciesState(
          units: servicesOf(hostId).units,
          error: err,
        );
      }
      await loadServices(hostId);
    } catch (e) {
      _servicesStates[hostId] = HostPoliciesState(
        units: servicesOf(hostId).units,
        error: e.toString(),
      );
    }
    _onChanged();
  }

  Future<void> loadCron(String hostId) async {
    _cronStates[hostId] = HostPoliciesState(
      loading: true,
      crontab: cronOf(hostId).crontab,
    );
    _onChanged();
    final c0 = _conns[hostId]?.client;
    if (c0 == null) {
      await poll(hostId);
    }
    final c = _conns[hostId]?.client;
    if (c == null) {
      _cronStates[hostId] = const HostPoliciesState(error: 'Host is offline');
      _onChanged();
      return;
    }
    try {
      final body = await readCrontab(c);
      _cronStates[hostId] = HostPoliciesState(crontab: body);
    } catch (e) {
      _cronStates[hostId] = HostPoliciesState(error: e.toString());
    }
    _onChanged();
  }

  Future<String?> writeCron(String hostId, String newBody) async {
    final c = _conns[hostId]?.client;
    if (c == null) return 'Host is offline';
    try {
      final err = await writeCrontab(c, newBody);
      if (err == null) {
        _cronStates[hostId] = HostPoliciesState(crontab: newBody);
        _onChanged();
      }
      return err;
    } catch (e) {
      return e.toString();
    }
  }

  Future<List<HostMetric>> history(String hostId, {int limit = 2000}) async {
    final rows = await db.hostMetricsHistory(hostId, limit: limit);
    return rows.reversed.toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _liveTimer?.cancel();
    _bgTimer?.cancel();
    for (final c in _conns.values) {
      c.client?.close();
    }
    super.dispose();
  }
}
