import 'package:flutter/material.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

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
    AppSection.sftp => Icons.swap_horiz,
  };
}
