import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// An action shown in a [MultiSelectBar].
class MultiSelectAction {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const MultiSelectAction({
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
  });
}

/// Floating bar shown while multiple items are selected, mirroring the
/// hosts screen's selection bar.
class MultiSelectBar extends StatelessWidget {
  final int count;
  final List<MultiSelectAction> actions;
  final VoidCallback onClose;

  const MultiSelectBar({
    super.key,
    required this.count,
    required this.actions,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.accentBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count selected',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          for (final action in actions) ...[
            _barButton(action),
            const SizedBox(width: 6),
          ],
          const SizedBox(width: 10),
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barButton(MultiSelectAction action) {
    final style = TextButton.styleFrom(
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      foregroundColor: action.danger ? AppColors.danger : AppColors.accent,
    );
    if (action.label.isEmpty) {
      return IconButton(
        onPressed: action.onTap,
        icon: Icon(action.icon, size: 15),
        style: IconButton.styleFrom(
          minimumSize: const Size(32, 32),
          foregroundColor: action.danger ? AppColors.danger : AppColors.accent,
        ),
        padding: const EdgeInsets.all(4),
      );
    }
    return TextButton.icon(
      onPressed: action.onTap,
      icon: Icon(action.icon, size: 15),
      label: Text(action.label),
      style: style,
    );
  }
}
