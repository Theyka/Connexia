import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../ui/state/providers.dart';
import 'team_controller.dart';

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
