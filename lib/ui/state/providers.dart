import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/secret_storage.dart';
import '../../core/crypto/vault.dart';
import '../../core/db/database.dart';
import '../../core/ssh/host_key_store.dart';
import '../../core/ssh/session_manager.dart';
import '../../core/ssh/ssh_service.dart';
import '../widgets/multi_select_bar.dart';
import 'nav.dart';
import 'settings_controller.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Global navigation section for the app shell. Management screens navigate
/// to the terminal view by setting [AppSection.terminals].
final appSectionProvider = StateProvider<AppSection>((ref) => AppSection.hosts);

/// Whether the sidebar is visible. Toggled from the window title bar.
/// Defaults to hidden on mobile where the section chips replace it.
final sidebarOpenProvider = StateProvider<bool>(
  (ref) => !(Platform.isAndroid || Platform.isIOS),
);

/// Whether the snippets sidebar of the terminal screen is visible. The
/// window title bar toggles this while the terminals section is active.
final terminalSnippetsOpenProvider = StateProvider<bool>((ref) => false);

/// Sorting order for the snippets page. Lives at app scope so the selection
/// persists while navigating between sections or searching.
enum SnippetSort { alphaAsc, alphaDesc, newest, oldest }

final snippetSortProvider =
    StateProvider<SnippetSort>((ref) => SnippetSort.newest);

/// A pending request to open the host editor (from the top bar or an empty
/// state). The hosts screen consumes this and clears it.
class HostEditorRequest {
  final String? hostId;
  final String? groupId;

  const HostEditorRequest({this.hostId, this.groupId});
}

final hostEditorRequestProvider =
    StateProvider<HostEditorRequest?>((ref) => null);

/// A pending request to open the group editor panel. The hosts screen
/// consumes this and clears it.
class GroupEditorRequest {
  final String? groupId;

  const GroupEditorRequest({this.groupId});
}

final groupEditorRequestProvider =
    StateProvider<GroupEditorRequest?>((ref) => null);

/// A pending request to open the snippet editor panel (from the snippets
/// screen or the terminal sidebar). The consuming screen clears it.
class SnippetEditorRequest {
  final String? snippetId;

  const SnippetEditorRequest({this.snippetId});
}

final snippetEditorRequestProvider =
    StateProvider<SnippetEditorRequest?>((ref) => null);

/// The floating multi-select action bar shown above the Settings item in
/// the left sidebar while items are selected on a list/grid screen. The
/// owning screen publishes it and clears it when nothing is selected.
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

/// Paginated view of the session log list. Loads the first page on start
/// and appends pages on demand so the log screen stays fast with thousands
/// of entries.
class SessionLogsController extends AsyncNotifier<SessionLogsState> {
  static const pageSize = 50;

  @override
  Future<SessionLogsState> build() async {
    final db = ref.watch(appDatabaseProvider);
    final logs = await db.getSessionLogs(limit: pageSize);
    final total = await db.countSessionLogs();
    return SessionLogsState(
      logs: logs,
      hasMore: logs.length < total,
      total: total,
      loadingMore: false,
    );
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
      );
      state = AsyncData(
        SessionLogsState(
          logs: [...current.logs, ...more],
          hasMore: more.length == SessionLogsController.pageSize,
          total: current.total,
          loadingMore: false,
        ),
      );
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> clearAll() async {
    final db = ref.read(appDatabaseProvider);
    await db.clearSessionLogs();
    state = const AsyncData(SessionLogsState.empty);
  }
}

class SessionLogsState {
  final List<SessionLog> logs;
  final bool hasMore;
  final int total;
  final bool loadingMore;

  const SessionLogsState({
    required this.logs,
    required this.hasMore,
    required this.total,
    required this.loadingMore,
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
      );
}

final sessionLogsProvider =
    AsyncNotifierProvider<SessionLogsController, SessionLogsState>(
  SessionLogsController.new,
);

final settingsControllerProvider =
    ChangeNotifierProvider<SettingsController>((ref) {
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

final sessionManagerProvider = ChangeNotifierProvider<SessionManager>((ref) {
  final manager = SessionManager(
    db: ref.watch(appDatabaseProvider),
    vault: ref.watch(vaultProvider),
    ssh: ref.watch(sshServiceProvider),
    hostKeyStore: ref.watch(hostKeyStoreProvider),
  );
  // Keep the parallel-connect limit in sync with the user's setting. The
  // settings controller notifies after load() and on every update.
  ref.listen(settingsControllerProvider, (_, next) {
    manager.maxConcurrentConnects = next.settings.maxConcurrentConnects;
  });
  ref.onDispose(manager.dispose);
  // Close logs left "active" by a previous run that ended without logging
  // (crash or force quit); this process cannot have live sessions yet.
  ref.watch(appDatabaseProvider).endStaleSessionLogs();
  return manager;
});
