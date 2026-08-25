import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../ui/state/providers.dart';
import 'team_controller.dart';

/// Workspace-scoped variants of the list providers. They watch the active
/// workspace id from [teamControllerProvider] and filter rows by it, so the
/// hosts/groups/keys/snippets screens automatically show only the active
/// workspace's data (or the personal scope when no workspace is active).
///
/// These live in a separate file to avoid a circular import: the sync layer
/// (sync_controller.dart) depends on the all-rows providers in
/// providers.dart for dirty-tracking, and team_controller.dart depends on
/// sync_controller.dart. Keeping the workspace-scoped providers here lets
/// providers.dart stay free of any team-controller dependency.

final scopedHostsProvider = StreamProvider<List<Host>>((ref) {
  final ws = ref.watch(activeWorkspaceIdProvider);
  return ref.watch(appDatabaseProvider).watchHostsInScope(ws);
});

final scopedGroupsProvider = StreamProvider<List<Group>>((ref) {
  final ws = ref.watch(activeWorkspaceIdProvider);
  return ref.watch(appDatabaseProvider).watchGroupsInScope(ws);
});

final scopedIdentitiesProvider = StreamProvider<List<Identity>>((ref) {
  final ws = ref.watch(activeWorkspaceIdProvider);
  return ref.watch(appDatabaseProvider).watchIdentitiesInScope(ws);
});

final scopedSnippetsProvider = StreamProvider<List<Snippet>>((ref) {
  final ws = ref.watch(activeWorkspaceIdProvider);
  return ref.watch(appDatabaseProvider).watchSnippetsInScope(ws);
});
