import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

/// On mobile the Terminals / Remote desktops sections show a Hosts-style list
/// of live connections. Selecting a connection switches that section to the
/// live session view; this is true while such a view is being shown, so the
/// section chip is only marked open on the list, never inside a session.
final liveSessionViewProvider = StateProvider<bool>((ref) => false);

enum AppSection {
  hosts,
  metrics,
  keys,
  tunnels,
  snippets,
  knownHosts,
  logs,
  teams,
  settings,
  terminals,
  remotes,
  sftp,
}

extension AppSectionInfo on AppSection {
  String get label => switch (this) {
    AppSection.hosts => 'Hosts',
    AppSection.metrics => 'Metrics',
    AppSection.keys => 'Keys',
    AppSection.tunnels => 'Tunnels',
    AppSection.snippets => 'Snippets',
    AppSection.knownHosts => 'Known hosts',
    AppSection.logs => 'Logs',
    AppSection.teams => 'Teams',
    AppSection.settings => 'Settings',
    AppSection.terminals => 'Terminals',
    AppSection.remotes => 'Remote desktops',
    AppSection.sftp => 'SFTP',
  };

  IconData get icon => switch (this) {
    AppSection.hosts => Icons.dns_outlined,
    AppSection.metrics => Icons.query_stats_outlined,
    AppSection.keys => Icons.vpn_key_outlined,
    AppSection.tunnels => Icons.lan_outlined,
    AppSection.snippets => Icons.code,
    AppSection.knownHosts => Icons.shield_outlined,
    AppSection.logs => Icons.receipt_long_outlined,
    AppSection.teams => Icons.groups_outlined,
    AppSection.settings => Icons.settings_outlined,
    AppSection.terminals => Icons.terminal,
    AppSection.remotes => Icons.desktop_windows_outlined,
    AppSection.sftp => Icons.swap_horiz,
  };
}
