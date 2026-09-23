import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Search field styled like the Hosts page search bar. Kept in one place so
/// every list page matches.
class ListSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final String hintText;

  const ListSearchField({
    super.key,
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
    this.hintText = 'Search...',
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: onClear,
              ),
      ),
    );
  }
}

/// Uppercase section label used above grids on the Hosts page and the list
/// pages.
class ListSectionHeader extends StatelessWidget {
  final String title;

  const ListSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        title.toUpperCase(),
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

/// A 64px-high list card matching the Hosts page host card: tinted icon
/// badge, title, monospace subtitle, optional unread dot and trailing action.
class ListCard extends StatelessWidget {
  const ListCard({
    super.key,
    required this.icon,
    required this.iconColor,
    this.iconTooltip,
    required this.title,
    this.titleTrailing,
    required this.subtitle,
    this.subtitleMonospace = true,
    this.selected = false,
    this.trailing,
    this.action,
    this.reserveAction = false,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  });

  final IconData icon;
  final Color iconColor;
  final String? iconTooltip;
  final String title;
  final Widget? titleTrailing;
  final String subtitle;
  final bool subtitleMonospace;
  final bool selected;
  final Widget? trailing;
  final Widget? action;
  final bool reserveAction;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Offset globalPosition)? onLongPress;
  final void Function(Offset globalPosition)? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    final showActionSlot = action != null || reserveAction;
    return GestureDetector(
      onLongPressStart: onLongPress == null
          ? null
          : (details) => onLongPress!(details.globalPosition),
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onSecondaryTapDown: onSecondaryTapDown == null
            ? null
            : (details) => onSecondaryTapDown!(details.globalPosition),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: selected ? AppColors.surfaceAlt : AppColors.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? AppColors.accentBorder : AppColors.border,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: iconTooltip == null
                    ? Icon(icon, size: 15, color: iconColor)
                    : Tooltip(
                        message: iconTooltip!,
                        waitDuration: const Duration(milliseconds: 600),
                        child: Icon(icon, size: 15, color: iconColor),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (titleTrailing != null) ...[
                          const SizedBox(width: 5),
                          titleTrailing!,
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Flexible(
                      child: Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: subtitleMonospace
                              ? 'JetBrainsMono'
                              : null,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
              if (showActionSlot) ...[
                const SizedBox(width: 6),
                SizedBox(width: 28, child: action),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
