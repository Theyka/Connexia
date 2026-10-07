import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/update/app_version.dart';
import '../../core/update/update_controller.dart';
import '../theme/app_colors.dart';
import 'markdown_text.dart';

/// Where mobile users go to download the new build.
const String _websiteUrl = 'https://connexia.run/#downloads';

/// Shows the "update available" dialog. Used both by the automatic startup
/// check and by the button in Settings → About.
Future<void> showUpdateDialog(BuildContext context, {bool startup = false}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _UpdateDialog(startup: startup),
  );
}

class _UpdateDialog extends ConsumerStatefulWidget {
  final bool startup;

  const _UpdateDialog({required this.startup});

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updateControllerProvider);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update_alt, size: 20, color: AppColors.accent),
          const SizedBox(width: 10),
          const Text('Update available'),
        ],
      ),
      content: SizedBox(width: 420, child: _buildContent(state)),
      actions: _buildActions(state),
    );
  }

  Widget _buildContent(UpdateState state) {
    final release = state.release;
    final notes = release == null ? '' : _cleanNotes(release.notes);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          release == null
              ? 'A newer version of Connexia is available.'
              : 'Connexia ${release.version} is available. '
                    '${_youAreOn()}',
          style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
        ),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 14),
          _NotesBox(notes: notes),
        ],
        if (state.phase == UpdatePhase.downloading) ...[
          const SizedBox(height: 16),
          _DownloadProgress(progress: state.progress ?? 0),
        ],
        if (state.phase == UpdatePhase.ready) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 16,
                color: AppColors.success,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Downloaded ${state.downloadedPath == null ? '' : p.basename(state.downloadedPath!)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (state.phase == UpdatePhase.error) ...[
          const SizedBox(height: 14),
          Text(
            state.error ?? 'Something went wrong.',
            style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
          ),
        ],
      ],
    );
  }

  List<Widget> _buildActions(UpdateState state) {
    final notifier = ref.read(updateControllerProvider.notifier);

    switch (state.phase) {
      case UpdatePhase.downloading:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Hide'),
          ),
        ];
      case UpdatePhase.ready:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => _installDesktop(context, ref),
            child: const Text('Install now'),
          ),
        ];
      case UpdatePhase.error:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => notifier.check(),
            child: const Text('Retry'),
          ),
        ];
      case UpdatePhase.idle:
      case UpdatePhase.checking:
      case UpdatePhase.upToDate:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ];
      case UpdatePhase.available:
        return [
          if (widget.startup)
            TextButton(
              onPressed: () async {
                await notifier.skipVersion();
                if (!mounted) return;
                Navigator.of(context).pop();
              },
              child: const Text('Skip this version'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              if (UpdateController.isMobile) {
                _openWebsite();
                Navigator.of(context).pop();
              } else {
                notifier.download();
              }
            },
            child: Text(
              UpdateController.isMobile ? 'Update' : 'Download & install',
            ),
          ),
        ];
    }
  }

  static String _youAreOn() {
    if (AppVersion.parse(AppVersion.name) == null) {
      return 'You are running an unreleased build.';
    }
    return 'You are running v${AppVersion.name}.';
  }
}

class _NotesBox extends StatelessWidget {
  final String notes;

  const _NotesBox({required this.notes});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: SingleChildScrollView(
        child: MarkdownText(
          notes,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.45,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _DownloadProgress extends StatelessWidget {
  final double progress;

  const _DownloadProgress({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: AppColors.surface,
            color: AppColors.accent,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Downloading… ${(progress * 100).round()}%',
          style: TextStyle(fontSize: 12, color: AppColors.textFaint),
        ),
      ],
    );
  }
}

/// Opens the downloaded installer/file and, on Windows, quits so the installer
/// can replace the running executable.
Future<void> _installDesktop(BuildContext context, WidgetRef ref) async {
  await ref.read(updateControllerProvider.notifier).openDownloaded();
  if (!Platform.isWindows) return;
  await Future.delayed(const Duration(seconds: 1));
  exit(0);
}

Future<void> _openWebsite() async {
  try {
    await launchUrl(
      Uri.parse(_websiteUrl),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {}
}

/// Strips the GitHub release's download table and badges so only the human
/// readable notes remain.
String _cleanNotes(String notes) {
  final kept = <String>[];
  for (final line in notes.split('\n')) {
    final trimmed = line.trimRight();
    if (trimmed.startsWith('|')) continue;
    if (trimmed.startsWith('![')) continue;
    kept.add(trimmed);
  }
  var text = kept.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  if (text.length > 2000) text = '${text.substring(0, 2000)}…';
  return text;
}

/// Settings → About card that shows the current update status.
class UpdateCard extends ConsumerWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final notifier = ref.read(updateControllerProvider.notifier);

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_alt, size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              const Text(
                'Updates',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _status(state),
          const SizedBox(height: 14),
          _action(context, ref, state, notifier),
        ],
      ),
    );
  }

  Widget _status(UpdateState state) {
    switch (state.phase) {
      case UpdatePhase.idle:
        return _line(
          'Check for the latest version of Connexia.',
          color: AppColors.textSecondary,
        );
      case UpdatePhase.checking:
        return Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            _line('Checking for updates…', color: AppColors.textSecondary),
          ],
        );
      case UpdatePhase.upToDate:
        return Row(
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 16,
              color: AppColors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _line(
                'You are up to date (v${state.release?.version ?? AppVersion.name}).',
                color: AppColors.textSecondary,
              ),
            ),
          ],
        );
      case UpdatePhase.available:
        return _line(
          'Connexia ${state.release?.version} is available.',
          color: AppColors.textPrimary,
        );
      case UpdatePhase.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: state.progress ?? 0,
                minHeight: 6,
                backgroundColor: AppColors.surface,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: 6),
            _line(
              'Downloading… ${((state.progress ?? 0) * 100).round()}%',
              color: AppColors.textFaint,
            ),
          ],
        );
      case UpdatePhase.ready:
        return _line(
          'Downloaded. Ready to install.',
          color: AppColors.textPrimary,
        );
      case UpdatePhase.error:
        return _line(
          state.error ?? 'Update check failed.',
          color: AppColors.danger,
        );
    }
  }

  Widget _action(
    BuildContext context,
    WidgetRef ref,
    UpdateState state,
    UpdateController notifier,
  ) {
    switch (state.phase) {
      case UpdatePhase.checking:
      case UpdatePhase.downloading:
        return FilledButton(onPressed: null, child: const Text('Please wait…'));
      case UpdatePhase.available:
        return FilledButton(
          onPressed: () => showUpdateDialog(context),
          child: Text(
            UpdateController.isMobile ? 'Update' : 'Download & install',
          ),
        );
      case UpdatePhase.ready:
        return FilledButton(
          onPressed: () => _installDesktop(context, ref),
          child: const Text('Install now'),
        );
      case UpdatePhase.error:
        return Row(
          children: [
            FilledButton(
              onPressed: () => notifier.check(),
              child: const Text('Try again'),
            ),
          ],
        );
      case UpdatePhase.idle:
      case UpdatePhase.upToDate:
        return FilledButton(
          onPressed: () => notifier.check(),
          child: const Text('Check for updates'),
        );
    }
  }

  static Widget _line(String text, {required Color color}) {
    return Text(
      text,
      style: TextStyle(fontSize: 12.5, height: 1.4, color: color),
    );
  }
}
