import 'package:flutter/material.dart';

/// Nested navigator that hosts routes shown below the window title bar
/// (e.g. the SFTP screen), keeping the session tabs and title bar visible.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Top-level sections of the app shell.
///
/// The order mirrors the sidebar list; [AppSection.index] is also used as
/// the IndexedStack index in home_screen, so children there must match.
enum AppSection {
  hosts,
  keys,
  tunnels,
  snippets,
  knownHosts,
  logs,
  teams,
  settings,
  terminals,
  sftp,
}

extension AppSectionInfo on AppSection {
  String get label => switch (this) {
        AppSection.hosts => 'Hosts',
        AppSection.keys => 'Keys',
        AppSection.tunnels => 'Tunnels',
        AppSection.snippets => 'Snippets',
        AppSection.knownHosts => 'Known hosts',
        AppSection.logs => 'Logs',
        AppSection.teams => 'Teams',
        AppSection.settings => 'Settings',
        AppSection.terminals => 'Terminals',
        AppSection.sftp => 'SFTP',
      };

  IconData get icon => switch (this) {
        AppSection.hosts => Icons.dns_outlined,
        AppSection.keys => Icons.vpn_key_outlined,
        AppSection.tunnels => Icons.lan_outlined,
        AppSection.snippets => Icons.code,
        AppSection.knownHosts => Icons.shield_outlined,
        AppSection.logs => Icons.receipt_long_outlined,
        AppSection.teams => Icons.groups_outlined,
        AppSection.settings => Icons.settings_outlined,
        AppSection.terminals => Icons.terminal,
        AppSection.sftp => Icons.swap_horiz,
      };
}
