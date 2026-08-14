import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../theme/app_colors.dart';

class DatabaseSettingsPanel extends ConsumerStatefulWidget {
  const DatabaseSettingsPanel({super.key});

  @override
  ConsumerState<DatabaseSettingsPanel> createState() =>
      _DatabaseSettingsPanelState();
}

class _DatabaseSettingsPanelState extends ConsumerState<DatabaseSettingsPanel> {
  static const _dataTiles = [
    ('hosts', 'Hosts', Icons.dns_outlined),
    ('groups', 'Groups', Icons.folder_outlined),
    ('identities', 'Keys', Icons.key_outlined),
    ('snippets', 'Snippets', Icons.code),
    ('known_hosts', 'Known hosts', Icons.verified_user_outlined),
    ('session_logs', 'Session logs', Icons.history),
  ];

  static const _exportOptions = [
    ('hosts', 'Hosts', Icons.dns_outlined,
        'Addresses, credentials, groups and notes for every saved host'),
    ('groups', 'Groups', Icons.folder_outlined,
        'Group structure and their shared settings'),
    ('keys', 'SSH keys', Icons.key_outlined,
        'Private key files, passphrases and certificates'),
    ('snippets', 'Snippets', Icons.code, 'Saved command snippets'),
    ('knownHosts', 'Known hosts', Icons.verified_user_outlined,
        'Host key fingerprints of servers you have connected to'),
  ];

  String? _path;
  int? _mainSize;
  int? _walSize;
  Map<String, int>? _tableRows;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = ref.read(appDatabaseProvider);
      final path = await db.databaseFilePath();
      final rows = await db.tableRowCounts();
      final mainFile = File(path);
      final walFile = File('$path-wal');
      if (!mounted) return;
      setState(() {
        _path = path;
        _mainSize = mainFile.existsSync() ? mainFile.lengthSync() : 0;
        _walSize = walFile.existsSync() ? walFile.lengthSync() : null;
        _tableRows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _copyPath() async {
    final path = _path;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Database path copied to clipboard')),
    );
  }

  Future<void> _export() async {
    final types = await _pickExportTypes();
    if (types == null || types.isEmpty || !mounted) return;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    try {
      final db = ref.read(appDatabaseProvider);
      final data = <String, dynamic>{
        'app': 'connexia',
        'formatVersion': 1,
        'exportedAt': now.toIso8601String(),
      };
      final counts = <String>[];
      if (types.contains('hosts')) {
        final items = (await db.allHosts()).map((h) => h.toJson()).toList();
        data['hosts'] = items;
        counts.add('${items.length} host${items.length == 1 ? '' : 's'}');
      }
      if (types.contains('groups')) {
        final items = (await db.allGroups()).map((g) => g.toJson()).toList();
        data['groups'] = items;
        counts.add('${items.length} group${items.length == 1 ? '' : 's'}');
      }
      if (types.contains('keys')) {
        final items =
            (await db.allIdentities()).map((i) => i.toJson()).toList();
        data['keys'] = items;
        counts.add('${items.length} key${items.length == 1 ? '' : 's'}');
      }
      if (types.contains('snippets')) {
        final items =
            (await db.allSnippets()).map((s) => s.toJson()).toList();
        data['snippets'] = items;
        counts.add('${items.length} snippet${items.length == 1 ? '' : 's'}');
      }
      if (types.contains('knownHosts')) {
        final items =
            (await db.allKnownHosts()).map((k) => k.toJson()).toList();
        data['knownHosts'] = items;
        counts.add('${items.length} known host${items.length == 1 ? '' : 's'}');
      }
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final isMobile = Platform.isAndroid || Platform.isIOS;
      final fileName = 'connexia_export_$stamp.json';
      final picked = await FilePicker.saveFile(
        dialogTitle: 'Export data',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        // Required on Android/iOS: the plugin writes these bytes itself.
        // On desktop the dialog only picks the destination.
        bytes: isMobile ? utf8.encode(json) : null,
      );
      if (picked == null || !mounted) return;
      if (!isMobile) {
        final file = File(picked);
        await file.writeAsString(json);
      }
      if (!mounted) return;
      // On Android/iOS the plugin returns an opaque document URI (e.g.
      // "/document/264"); the chosen folder is where the user picked it,
      // so the filename is what they need to find it.
      final where = isMobile ? fileName : picked;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Exported ${counts.join(', ')} to $where',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<Set<String>?> _pickExportTypes() async {
    final selected = <String>{
      for (final option in _exportOptions) option.$1,
    };
    return showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Export data'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Choose what to include in the export file.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                for (final option in _exportOptions)
                  CheckboxListTile(
                    value: selected.contains(option.$1),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(option.$1);
                      } else {
                        selected.remove(option.$1);
                      }
                    }),
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      option.$2,
                      style: const TextStyle(fontSize: 13),
                    ),
                    secondary: Icon(
                      option.$3,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Passwords and private keys are exported in their '
                  'encrypted form, never in plain text.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textFaint,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(dialogContext).pop(selected),
              child: const Text('Export'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: _PanelTitle('DATABASE FILE')),
            if (_path != null)
              InkWell(
                onTap: _load,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Icon(
                    Icons.refresh,
                    size: 15,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _fileCard(),
        const SizedBox(height: 20),
        const _PanelTitle('DATA'),
        _tilesCard(),
        const SizedBox(height: 20),
        _exportCard(),
      ],
    );
  }

  Widget _fileCard() {
    if (_loading) {
      return const _PanelCard(
        child: SizedBox(
          height: 64,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return _PanelCard(
        child: Text(
          _error!,
          style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
        ),
      );
    }
    final path = _path ?? '';
    final wal = _walSize ?? 0;
    return _PanelCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _iconBox(Icons.storage_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Location',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  path,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'JetBrainsMono',
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Database file: ${_formatBytes(_mainSize ?? 0)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textFaint,
                  ),
                ),
                if (wal > 0)
                  Text(
                    'Write-ahead log: ${_formatBytes(wal)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textFaint,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Copy path',
            icon: const Icon(Icons.copy_outlined, size: 17),
            onPressed: _copyPath,
          ),
        ],
      ),
    );
  }

  Widget _tilesCard() {
    if (_loading) {
      return const _PanelCard(
        child: SizedBox(
          height: 60,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return _PanelCard(
        child: Text(
          _error!,
          style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
        ),
      );
    }
    final rows = _tableRows ?? const <String, int>{};
    final tiles = <Widget>[
      for (final tile in _dataTiles)
        _StatTile(
          icon: tile.$3,
          label: tile.$2,
          count: rows[tile.$1] ?? 0,
        ),
    ];
    return Column(
      children: [
        for (var i = 0; i < tiles.length; i += 3) ...[
          if (i > 0) const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < 3; c++) ...[
                if (c > 0) const SizedBox(width: 8),
                if (i + c < tiles.length)
                  Expanded(child: tiles[i + c])
                else
                  const Expanded(child: SizedBox.shrink()),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _exportCard() {
    return _PanelCard(
      child: Row(
        children: [
          _iconBox(Icons.file_download_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Export data',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Save hosts, keys, snippets and more as a readable JSON '
                  'file. You can choose which parts to include.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.save_alt, size: 16),
            label: const Text('Export'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconBox(IconData icon) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.accentMuted,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(icon, size: 18, color: AppColors.accent),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 27,
            height: 27,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 14, color: AppColors.accent),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.1,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  final String text;

  const _PanelTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.textFaint,
        ),
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  final Widget child;

  const _PanelCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}
