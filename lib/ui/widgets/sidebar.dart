import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/nav.dart';
import '../theme/app_colors.dart';

class Sidebar extends ConsumerWidget {
  final AppSection current;
  final ValueChanged<AppSection> onSelect;

  const Sidebar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final expanded = width >= 1160;
    final padding = expanded
        ? const EdgeInsets.symmetric(horizontal: 12)
        : const EdgeInsets.symmetric(horizontal: 6);

    return Container(
      width: expanded ? 224 : 64,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 10),
              children: [
                    Padding(
                      padding: padding,
                      child: _NavButton(
                        icon: AppSection.hosts.icon,
                        label: AppSection.hosts.label,
                        expanded: expanded,
                        selected: current == AppSection.hosts,
                        onTap: () => onSelect(AppSection.hosts),
                      ),
                    ),
                    Padding(
                      padding: padding,
                      child: _NavButton(
                        icon: AppSection.keys.icon,
                        label: AppSection.keys.label,
                        expanded: expanded,
                        selected: current == AppSection.keys,
                        onTap: () => onSelect(AppSection.keys),
                      ),
                    ),
                    Padding(
                      padding: padding,
                      child: _NavButton(
                        icon: AppSection.knownHosts.icon,
                        label: AppSection.knownHosts.label,
                        expanded: expanded,
                        selected: current == AppSection.knownHosts,
                        onTap: () => onSelect(AppSection.knownHosts),
                      ),
                    ),
                    Padding(
                      padding: padding,
                      child: _NavButton(
                        icon: AppSection.snippets.icon,
                        label: AppSection.snippets.label,
                        expanded: expanded,
                        selected: current == AppSection.snippets,
                        onTap: () => onSelect(AppSection.snippets),
                      ),
                    ),
                    Padding(
                      padding: padding,
                      child: _NavButton(
                        icon: AppSection.logs.icon,
                        label: AppSection.logs.label,
                        expanded: expanded,
                        selected: current == AppSection.logs,
                        onTap: () => onSelect(AppSection.logs),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Padding(
                  padding: padding,
                  child: _NavButton(
                    icon: AppSection.settings.icon,
                    label: AppSection.settings.label,
                    expanded: expanded,
                    selected: current == AppSection.settings,
                    onTap: () => onSelect(AppSection.settings),
                  ),
                ),
              ),
            ],
          ),
        );
  }
}

class _NavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool expanded;
  final bool selected;
  final VoidCallback onTap;

  const _NavButton({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 38,
        padding: expanded ? const EdgeInsets.symmetric(horizontal: 10) : null,
        decoration: BoxDecoration(
          color: selected ? AppColors.accentMuted : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.accentBorder : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? AppColors.accent : AppColors.textSecondary,
            ),
            if (expanded) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (expanded) return content;
    return Tooltip(message: label, child: content);
  }
}
