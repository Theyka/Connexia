import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/secret_storage.dart';
import '../../core/crypto/vault.dart';
import '../../core/db/database.dart';
import '../../core/remote/remote_session.dart';
import '../../core/ssh/host_key_store.dart';
import '../../core/ssh/metrics_controller.dart';
import '../../core/ssh/session_manager.dart';
import '../../core/ssh/ssh_service.dart';
import '../../core/ssh/tunnel_manager.dart';
import '../widgets/multi_select_bar.dart';
import 'nav.dart';
import 'settings_controller.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final appSectionProvider = StateProvider<AppSection>((ref) => AppSection.hosts);

final sidebarOpenProvider = StateProvider<bool>(
  (ref) => !(Platform.isAndroid || Platform.isIOS),
);

final terminalSnippetsOpenProvider = StateProvider<bool>((ref) => false);

final workspaceSessionIdsProvider = StateProvider<List<String>>((ref) => []);

final workspaceColumnsProvider = StateProvider<int>((ref) => 2);

final workspaceOpenProvider = StateProvider<bool>((ref) => false);

enum SnippetSort { alphaAsc, alphaDesc, newest, oldest }

final snippetSortProvider = StateProvider<SnippetSort>(
  (ref) => SnippetSort.newest,
);

class HostEditorRequest {
  final String? hostId;
  final String? groupId;

  const HostEditorRequest({this.hostId, this.groupId});
}

final hostEditorRequestProvider = StateProvider<HostEditorRequest?>(
  (ref) => null,
);

class GroupEditorRequest {
  final String? groupId;

  const GroupEditorRequest({this.groupId});
}

final groupEditorRequestProvider = StateProvider<GroupEditorRequest?>(
  (ref) => null,
);

class SnippetEditorRequest {
  final String? snippetId;

  const SnippetEditorRequest({this.snippetId});
}

final snippetEditorRequestProvider = StateProvider<SnippetEditorRequest?>(
  (ref) => null,
);

final keyEditorRequestProvider = StateProvider<String?>((ref) => null);

final tunnelEditRequestProvider = StateProvider<String?>((ref) => null);

enum HoveredEditKind { host, group, key, snippet, tunnel }

class HoveredEditTarget {
  final HoveredEditKind kind;
  final String id;

  const HoveredEditTarget(this.kind, this.id);

  @override
  bool operator ==(Object other) =>
      other is HoveredEditTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

final hoveredEditTargetProvider = StateProvider<HoveredEditTarget?>(
  (ref) => null,
);

class SelectionBarData {
  final int count;
  final List<MultiSelectAction> actions;
  final VoidCallback onClose;

  const SelectionBarData({
    required this.count,
    required this.actions,
    required this.onClose,
  });
}

final selectionBarProvider = StateProvider<SelectionBarData?>((ref) => null);

final hostsProvider = StreamProvider<List<Host>>((ref) {
  return ref.watch(appDatabaseProvider).watchHosts();
});

final groupsProvider = StreamProvider<List<Group>>((ref) {
  return ref.watch(appDatabaseProvider).watchGroups();
});

final identitiesProvider = StreamProvider<List<Identity>>((ref) {
  return ref.watch(appDatabaseProvider).watchIdentities();
});

final knownHostsProvider = StreamProvider<List<KnownHost>>((ref) {
  return ref.watch(appDatabaseProvider).watchKnownHosts();
});

final snippetsProvider = StreamProvider<List<Snippet>>((ref) {
  return ref.watch(appDatabaseProvider).watchSnippets();
});

final sessionLogChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(appDatabaseProvider).watchSessionLogs().map((_) {});
});

class SessionLogsController extends AsyncNotifier<SessionLogsState> {
  static const pageSize = 50;

  String _query = '';

  @override
  Future<SessionLogsState> build() async {
    ref.watch(sessionLogChangesProvider);
    ref.watch(appDatabaseProvider);
    return _load();
  }

  Future<SessionLogsState> _load() async {
    final db = ref.read(appDatabaseProvider);
    final logs = await db.getSessionLogs(limit: pageSize, search: _query);
    final total = await db.countSessionLogs(search: _query);
    return SessionLogsState(
      logs: logs,
      hasMore: logs.length < total,
      total: total,
      loadingMore: false,
      query: _query,
    );
  }

  Future<void> setQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed == _query) return;
    _query = trimmed;
    state = const AsyncLoading();
    state = await AsyncValue.guard(_load);
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;
    final db = ref.read(appDatabaseProvider);
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final more = await db.getSessionLogs(
        limit: SessionLogsController.pageSize,
        offset: current.logs.length,
        search: _query,
      );
      state = AsyncData(
        SessionLogsState(
          logs: [...current.logs, ...more],
          hasMore: more.length == SessionLogsController.pageSize,
          total: current.total,
          loadingMore: false,
          query: _query,
        ),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> clearAll() async {
    final db = ref.read(appDatabaseProvider);
    await db.clearSessionLogs();
    _query = '';
    state = const AsyncData(SessionLogsState.empty);
  }
}

class SessionLogsState {
  final List<SessionLog> logs;
  final bool hasMore;
  final int total;
  final bool loadingMore;
  final String query;

  const SessionLogsState({
    required this.logs,
    required this.hasMore,
    required this.total,
    required this.loadingMore,
    this.query = '',
  });

  static const empty = SessionLogsState(
    logs: [],
    hasMore: false,
    total: 0,
    loadingMore: false,
  );

  SessionLogsState copyWith({bool? loadingMore}) => SessionLogsState(
    logs: logs,
    hasMore: hasMore,
    total: total,
    loadingMore: loadingMore ?? this.loadingMore,
    query: query,
  );
}

final sessionLogsProvider =
    AsyncNotifierProvider<SessionLogsController, SessionLogsState>(
      SessionLogsController.new,
    );

final settingsControllerProvider = ChangeNotifierProvider<SettingsController>((
  ref,
) {
  final controller = SettingsController(ref.watch(appDatabaseProvider));
  controller.load();
  return controller;
});

final themesProvider = StreamProvider<List<AppTheme>>((ref) {
  return ref.watch(appDatabaseProvider).watchThemes();
});

final secretStorageProvider = Provider<SecretStorage>(
  (ref) => PlatformSecretStorage(),
);

final vaultProvider = Provider<Vault>(
  (ref) => Vault(ref.watch(secretStorageProvider)),
);

final hostKeyStoreProvider = Provider<HostKeyStore>(
  (ref) => HostKeyStore(ref.watch(appDatabaseProvider)),
);

final sshServiceProvider = Provider<SshService>((ref) => SshService());

final metricsControllerProvider = ChangeNotifierProvider<MetricsController>((
  ref,
) {
  final controller = MetricsController(
    vault: ref.watch(vaultProvider),
    db: ref.watch(appDatabaseProvider),
    hostKeyStore: ref.watch(hostKeyStoreProvider),
    ssh: ref.watch(sshServiceProvider),
    onChanged: () => ref.notifyListeners(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final sessionManagerProvider = ChangeNotifierProvider<SessionManager>((ref) {
  final manager = SessionManager(
    db: ref.watch(appDatabaseProvider),
    vault: ref.watch(vaultProvider),
    ssh: ref.watch(sshServiceProvider),
    hostKeyStore: ref.watch(hostKeyStoreProvider),
  );

  ref.listen(settingsControllerProvider, (_, next) {
    manager.maxConcurrentConnects = next.settings.maxConcurrentConnects;
    manager.scrollbackLines = next.settings.scrollback;
  });

  void syncVisible() {
    manager.updateVisibleSessions(
      terminalsVisible: ref.read(appSectionProvider) == AppSection.terminals,
      workspaceOpen: ref.read(workspaceOpenProvider),
      workspaceIds: {...ref.read(workspaceSessionIdsProvider)},
    );
  }

  ref.listen(
    appSectionProvider,
    (_, _) => syncVisible(),
    fireImmediately: true,
  );
  ref.listen(workspaceOpenProvider, (_, _) => syncVisible());
  ref.listen(workspaceSessionIdsProvider, (_, _) => syncVisible());
  ref.onDispose(manager.dispose);

  ref.watch(appDatabaseProvider).endStaleSessionLogs();
  return manager;
});

final remoteManagerProvider = ChangeNotifierProvider<RemoteSessionManager>((
  ref,
) {
  final manager = RemoteSessionManager();
  ref.onDispose(manager.dispose);
  return manager;
});

final tunnelManagerProvider = ChangeNotifierProvider<TunnelManager>((ref) {
  final manager = TunnelManager(
    db: ref.watch(appDatabaseProvider),
    vault: ref.watch(vaultProvider),
    ssh: ref.watch(sshServiceProvider),
    hostKeyStore: ref.watch(hostKeyStoreProvider),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final watchTunnelsProvider = StreamProvider<List<Tunnel>>((ref) {
  return ref.watch(appDatabaseProvider).watchTunnels();
});

final tunnelLogsProvider = StreamProvider<List<TunnelLog>>((ref) {
  return ref.watch(appDatabaseProvider).watchTunnelLogs();
});
