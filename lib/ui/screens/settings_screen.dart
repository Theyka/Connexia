import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/shortcuts.dart';
import '../../core/terminal/themes.dart';
import '../state/providers.dart';
import '../state/settings_controller.dart';
import '../theme/app_colors.dart';
import '../widgets/account_settings_panel.dart';
import '../widgets/database_settings_panel.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _category = 0;

  static const _categories = [
    (Icons.cloud_outlined, 'Account'),
    (Icons.terminal, 'Terminal'),
    (Icons.keyboard_outlined, 'Shortcuts'),
    (Icons.storage_outlined, 'Database'),
    (Icons.info_outline, 'About'),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(settingsControllerProvider);
    final settings = controller.settings;

    final categories = _categories.map((c) => c.$2).toList();
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= 760;

    final content = switch (_category) {
      0 => _buildAccount(),
      1 => _buildTerminal(context, ref, controller, settings),
      2 => _buildShortcuts(context, ref, controller, settings),
      3 => _buildDatabase(),
      _ => _buildAbout(),
    };

    if (!useRail) {
      return Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (var i = 0; i < categories.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _CategoryChip(
                    label: categories[i],
                    selected: _category == i,
                    onTap: () => setState(() => _category = i),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: content),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 208,
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(right: BorderSide(color: AppColors.border)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _categories.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                _CategoryButton(
                  icon: _categories[i].$1,
                  label: _categories[i].$2,
                  selected: _category == i,
                  onTap: () => setState(() => _category = i),
                ),
              ],
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildAccount() {
    return const AccountSettingsPanel();
  }

  Widget _buildTerminal(
    BuildContext context,
    WidgetRef ref,
    SettingsController controller,
    AppSettings settings,
  ) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const _SectionTitle('PREVIEW'),
        _ThemePreview(themeName: settings.terminalTheme),
        const SizedBox(height: 16),
        const _SectionTitle('PRESETS'),
        for (final preset in terminalThemePresets)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PresetTile(
              preset: preset,
              selected: preset.name == settings.terminalTheme,
              onTap: () =>
                  controller.update(settings.copyWith(terminalTheme: preset.name)),
            ),
          ),
        const SizedBox(height: 8),
        const _SectionTitle('TERMINAL SETTINGS'),
        _StepperCard(
          title: 'Font size',
          description: 'Character size in terminal sessions.',
          icon: Icons.format_size,
          value: settings.fontSize,
          suffix: 'pt',
          min: 8,
          max: 28,
          isDouble: true,
          canDecrease: settings.fontSize > 8,
          canIncrease: settings.fontSize < 28,
          onDecrease: () => controller.update(
            settings.copyWith(fontSize: settings.fontSize - 1),
          ),
          onIncrease: () => controller.update(
            settings.copyWith(fontSize: settings.fontSize + 1),
          ),
          onChanged: (v) => controller.update(
            settings.copyWith(fontSize: v.toDouble()),
          ),
        ),
        const SizedBox(height: 10),
        _StepperCard(
          title: 'Scrollback lines',
          description: 'How many lines of history to keep per session.',
          icon: Icons.history,
          value: settings.scrollback.toDouble(),
          suffix: 'lines',
          min: 100,
          max: 100000,
          canDecrease: settings.scrollback > 100,
          canIncrease: settings.scrollback < 100000,
          onDecrease: () => controller.update(
            settings.copyWith(scrollback: settings.scrollback ~/ 2),
          ),
          onIncrease: () => controller.update(
            settings.copyWith(scrollback: settings.scrollback * 2),
          ),
          onChanged: (v) => controller.update(
            settings.copyWith(scrollback: v.toInt()),
          ),
        ),
        const SizedBox(height: 10),
        _StepperCard(
          title: 'Max parallel connections',
          description:
              'How many hosts may connect at the same time. Lower keeps '
              'the UI snappier; higher connects many hosts faster.',
          icon: Icons.sync_alt,
          value: settings.maxConcurrentConnects.toDouble(),
          min: SettingsController.maxConcurrentConnectsMin.toDouble(),
          max: SettingsController.maxConcurrentConnectsMax.toDouble(),
          canDecrease:
              settings.maxConcurrentConnects >
                  SettingsController.maxConcurrentConnectsMin,
          canIncrease:
              settings.maxConcurrentConnects <
                  SettingsController.maxConcurrentConnectsMax,
          onDecrease: () => controller.update(
            settings.copyWith(
              maxConcurrentConnects: settings.maxConcurrentConnects - 1,
            ),
          ),
          onIncrease: () => controller.update(
            settings.copyWith(
              maxConcurrentConnects: settings.maxConcurrentConnects + 1,
            ),
          ),
          onChanged: (v) => controller.update(
            settings.copyWith(maxConcurrentConnects: v.toInt()),
          ),
        ),
        const SizedBox(height: 10),
        _SettingsCard(
          title: 'Auto-accept host keys',
          description:
              'Trust the host key of any new host automatically without '
              'asking for confirmation.',
          icon: Icons.security_outlined,
          trailing: Switch(
            value: settings.autoAcceptHostKeys,
            activeTrackColor: AppColors.accent,
            onChanged: (value) => controller.update(
              settings.copyWith(autoAcceptHostKeys: value),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShortcuts(
    BuildContext context,
    WidgetRef ref,
    SettingsController controller,
    AppSettings settings,
  ) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const _SectionTitle('KEYBOARD SHORTCUTS'),
        Text(
          'Click Record on any shortcut to press a new key combination, or '
          'Reset to restore the default.',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 14),
        for (final shortcut in appShortcuts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ShortcutRow(
              shortcut: shortcut,
              binding: _effectiveBinding(settings, shortcut),
              isCustom: _isCustomBinding(settings, shortcut),
              onRecord: () => _recordShortcut(context, ref, shortcut),
              onReset: () => _resetShortcut(controller, settings, shortcut),
            ),
          ),
      ],
    );
  }

  bool _isCustomBinding(AppSettings settings, AppShortcut shortcut) {
    final custom = settings.customShortcuts[shortcut.id];
    return custom != null && custom.isNotEmpty;
  }

  String _effectiveBinding(AppSettings settings, AppShortcut shortcut) {
    final custom = settings.customShortcuts[shortcut.id];
    return (custom != null && custom.isNotEmpty)
        ? custom
        : shortcut.defaultBinding;
  }

  Future<void> _recordShortcut(
    BuildContext context,
    WidgetRef ref,
    AppShortcut shortcut,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ShortcutRecorderDialog(shortcut: shortcut),
    );
  }

  void _resetShortcut(
    SettingsController controller,
    AppSettings settings,
    AppShortcut shortcut,
  ) {
    final next = Map<String, String>.of(settings.customShortcuts)
      ..remove(shortcut.id);
    controller.update(settings.copyWith(customShortcuts: next));
  }

  Widget _buildAbout() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
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
                  const _ConnexiaMark(size: 40),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connexia',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Version 0.2.3',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'SSH client and terminal emulator. Works on Windows, macOS, '
                'Linux, iOS and Android. All data stays on your device.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: const [
                  _AboutTag(label: 'SSH / SFTP'),
                  _AboutTag(label: 'Local-first'),
                  _AboutTag(label: 'Open source'),
                ],
              ),
              const SizedBox(height: 20),
              _AboutLink(
                icon: const Icon(Icons.language, size: 15),
                label: 'connexia.run',
                url: 'https://connexia.run',
              ),
              _AboutLink(
                icon: const FaIcon(FontAwesomeIcons.github, size: 14),
                label: 'github.com/Theyka',
                url: 'https://github.com/Theyka',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDatabase() => const DatabaseSettingsPanel();
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

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

class _CategoryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.accentBorder : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentMuted : AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget trailing;

  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }
}

class _StepperCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String description;
  final num value;
  final String? suffix;
  final num min;
  final num max;
  final bool isDouble;
  final bool canDecrease;
  final bool canIncrease;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final ValueChanged<num> onChanged;

  const _StepperCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    this.suffix,
    required this.min,
    required this.max,
    this.isDouble = false,
    required this.canDecrease,
    required this.canIncrease,
    required this.onDecrease,
    required this.onIncrease,
    required this.onChanged,
  });

  @override
  State<_StepperCard> createState() => _StepperCardState();
}

class _StepperCardState extends State<_StepperCard> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller.text = _format(widget.value);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_StepperCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focused && oldWidget.value != widget.value) {
      _controller.text = _format(widget.value);
    }
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _focused = true;
    } else if (_focused) {
      _commit();
    }
  }

  String _format(num value) {
    if (!widget.isDouble) return value.round().toString();
    final d = value.toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
  }

  /// Applies the typed value (clamped to [min, max]); reverts to the current
  /// value when the text cannot be parsed.
  void _commit() {
    if (!_focused) return;
    _focused = false;
    final parsed = widget.isDouble
        ? double.tryParse(_controller.text.trim())
        : int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = _format(widget.value);
      return;
    }
    final clamped = parsed.clamp(widget.min, widget.max);
    _controller.text = _format(clamped);
    if (clamped != widget.value) {
      widget.onChanged(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(widget.icon, size: 18, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ValueField(
            controller: _controller,
            focusNode: _focusNode,
            isDouble: widget.isDouble,
            suffix: widget.suffix,
            onSubmitted: (_) => _commit(),
          ),
          const SizedBox(width: 8),
          _StepButton(
            icon: Icons.remove,
            onPressed: widget.canDecrease ? widget.onDecrease : null,
          ),
          const SizedBox(width: 4),
          _StepButton(
            icon: Icons.add,
            onPressed: widget.canIncrease ? widget.onIncrease : null,
          ),
        ],
      ),
    );
  }
}

/// Compact numeric input used inside [_StepperCard]; commit happens on
/// submit or focus loss (see [_StepperCardState._commit]).
class _ValueField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isDouble;
  final String? suffix;
  final ValueChanged<String> onSubmitted;

  const _ValueField({
    required this.controller,
    required this.focusNode,
    required this.isDouble,
    this.suffix,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 64,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
            ),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(isDouble ? r'[0-9.]' : r'[0-9]'),
              ),
            ],
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            cursorColor: AppColors.accent,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 7,
              ),
              filled: true,
              fillColor: AppColors.surfaceAlt,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.accentBorder),
              ),
            ),
            onSubmitted: onSubmitted,
          ),
        ),
        if (suffix != null) ...[
          const SizedBox(width: 6),
          Text(
            suffix!,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textFaint,
            ),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _StepButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(
          icon,
          size: 15,
          color: onPressed != null
              ? AppColors.textSecondary
              : AppColors.textFaint,
        ),
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  final TerminalThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _PresetTile({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceAlt : AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.accentBorder : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            for (final color in [
              preset.theme.background,
              preset.theme.foreground,
              preset.theme.green,
              preset.theme.blue,
              preset.theme.red,
            ])
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                preset.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 17,
              color: selected ? AppColors.accent : AppColors.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutTag extends StatelessWidget {
  final String label;

  const _AboutTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// The Connexia logo: dark rounded tile with the teal chevron-and-underscore
/// glyph, matching the app icon and website branding.
class _ConnexiaMark extends StatelessWidget {
  final double size;

  const _ConnexiaMark({this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: AppColors.border),
      ),
      child: CustomPaint(
        painter: _ConnexiaMarkPainter(
          color: AppColors.accent,
          // Scale the 24-unit design grid so the glyph occupies the same
          // share of the tile as on the Android app icon (~52% wide).
          scale: size * 1.16 / 24,
        ),
      ),
    );
  }
}

class _ConnexiaMarkPainter extends CustomPainter {
  final Color color;
  final double scale;

  _ConnexiaMarkPainter({required this.color, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Center the 24-unit design grid inside the tile.
    canvas.translate(
      (size.width - 24 * scale) / 2,
      (size.height - 24 * scale) / 2,
    );
    canvas.scale(scale, scale);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // Chevron: >-shape at the left, same geometry as the icon.
    paint.strokeWidth = 1.9;
    final chevron = Path()
      ..moveTo(6.6, 7.9)
      ..lineTo(10.2, 12)
      ..lineTo(6.6, 14.8);
    canvas.drawPath(chevron, paint);

    // Underscore to its lower right.
    paint.strokeWidth = 1.7;
    final underscore = Path()
      ..moveTo(12.1, 16.1)
      ..lineTo(17.5, 16.1);
    canvas.drawPath(underscore, paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ConnexiaMarkPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.scale != scale;
}

/// A single external link row (Website / GitHub) in the About card.
class _AboutLink extends StatelessWidget {
  final Widget icon;
  final String label;
  final String url;

  const _AboutLink({
    required this.icon,
    required this.label,
    required this.url,
  });

  Future<void> _open() async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // No browser available — ignore silently.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(width: 20, child: icon),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.open_in_new,
                size: 11,
                color: AppColors.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final AppShortcut shortcut;
  final String binding;
  final bool isCustom;
  final VoidCallback onRecord;
  final VoidCallback onReset;

  const _ShortcutRow({
    required this.shortcut,
    required this.binding,
    required this.isCustom,
    required this.onRecord,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              Icons.keyboard_outlined,
              size: 18,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortcut.label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isCustom) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Custom',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(
              binding,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onRecord,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.accentMuted,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.accentBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_outlined, size: 13, color: AppColors.accent),
                  const SizedBox(width: 4),
                  Text(
                    'Record',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isCustom) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: onReset,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.border),
                ),
                child: Icon(
                  Icons.restart_alt,
                  size: 14,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Modal that captures the next key combination pressed by the user. Escape
/// cancels, Backspace/Delete removes the custom binding (falls back to the
/// default).
class _ShortcutRecorderDialog extends ConsumerStatefulWidget {
  final AppShortcut shortcut;

  const _ShortcutRecorderDialog({required this.shortcut});

  @override
  ConsumerState<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState
    extends ConsumerState<_ShortcutRecorderDialog> {
  final _focusNode = FocusNode(debugLabel: 'shortcutRecorder');
  String? _preview;

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hk = HardwareKeyboard.instance;
    final key = event.logicalKey;

    // Pressing a modifier alone records nothing.
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    final settings = ref.read(settingsControllerProvider).settings;

    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      final next = Map<String, String>.of(settings.customShortcuts)
        ..remove(widget.shortcut.id);
      ref
          .read(settingsControllerProvider)
          .update(settings.copyWith(customShortcuts: next));
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    final chord = ShortcutChord.fromCurrentState(hk, key);
    final next = Map<String, String>.of(settings.customShortcuts)
      ..[widget.shortcut.id] = chord.format();
    ref
        .read(settingsControllerProvider)
        .update(settings.copyWith(customShortcuts: next));
    setState(() => _preview = chord.format());
    Navigator.of(context).pop();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: Text('Record shortcut'),
      content: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        autofocus: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.shortcut.label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.accentBorder),
              ),
              child: Text(
                _preview ?? 'Press the keys now…',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Press Escape to cancel, Backspace to clear.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textFaint,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _ThemePreview extends StatelessWidget {
  final String themeName;

  const _ThemePreview({required this.themeName});

  @override
  Widget build(BuildContext context) {
    final theme = terminalThemeByName(themeName).theme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            r'connexia@server:~$',
            style: TextStyle(
              color: theme.green,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ssh connected — ready',
            style: TextStyle(
              color: theme.foreground,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            r'connexia@server:~$ █',
            style: TextStyle(
              color: theme.cyan,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
