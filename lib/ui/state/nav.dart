import 'package:flutter/material.dart';

/// Nested navigator that hosts routes shown below the window title bar
/// (e.g. the SFTP screen), keeping the session tabs and title bar visible.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Top-level sections of the app shell.
enum AppSection {
  hosts,
  keys,
  knownHosts,
  snippets,
  logs,
  settings,
  terminals,
  sftp,
}

extension AppSectionInfo on AppSection {
  String get label => switch (this) {
        AppSection.hosts => 'Hosts',
        AppSection.keys => 'Keys',
        AppSection.knownHosts => 'Known hosts',
        AppSection.snippets => 'Snippets',
        AppSection.logs => 'Logs',
        AppSection.settings => 'Settings',
        AppSection.terminals => 'Terminals',
        AppSection.sftp => 'SFTP',
      };

  IconData get icon => switch (this) {
        AppSection.hosts => Icons.dns_outlined,
        AppSection.keys => Icons.vpn_key_outlined,
        AppSection.knownHosts => Icons.shield_outlined,
        AppSection.snippets => Icons.code,
        AppSection.logs => Icons.receipt_long_outlined,
        AppSection.settings => Icons.settings_outlined,
        AppSection.terminals => Icons.terminal,
        AppSection.sftp => Icons.swap_horiz,
      };
}
