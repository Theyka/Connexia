import 'package:flutter/material.dart';

import '../../core/db/database.dart';
import '../theme/app_colors.dart';

/// A polished replacement for the default Material dropdown used to pick an
/// SSH identity (private key). Renders as a filled form field with a key
/// icon, the selected key's name and a chevron; tapping opens a styled menu
/// listing every imported key.
class KeySelectField extends StatefulWidget {
  final String? value;
  final List<Identity> identities;
  final ValueChanged<String?>? onChanged;
  final String? Function(String?)? validator;
  final String label;

  const KeySelectField({
    super.key,
    required this.value,
    required this.identities,
    required this.onChanged,
    this.validator,
    this.label = 'Private key',
  });

  @override
  State<KeySelectField> createState() => _KeySelectFieldState();
}

class _KeySelectFieldState extends State<KeySelectField> {
  bool _hovered = false;
  bool _open = false;

  Future<void> _pick(FormFieldState<String?> field) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    setState(() => _open = true);
    final picked = await showMenu<String?>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero),
          box.localToGlobal(box.size.bottomRight(Offset.zero)),
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final identity in widget.identities)
          _keyMenuItem(identity, identity.id == field.value),
      ],
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (picked != null && picked != field.value) {
      field.didChange(picked);
      widget.onChanged?.call(picked);
    }
  }

  PopupMenuItem<String?> _keyMenuItem(Identity identity, bool selected) {
    return PopupMenuItem<String?>(
      height: 52,
      value: identity.id,
      child: Row(
        children: [
          Icon(
            Icons.vpn_key_outlined,
            size: 16,
            color: selected ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  identity.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (identity.comment.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    identity.comment,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textFaint,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (selected) ...[
            const SizedBox(width: 8),
            Icon(Icons.check, size: 16, color: AppColors.accent),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FormField<String?>(
      initialValue: widget.value,
      validator: widget.validator,
      builder: (field) {
        final selected = _identityById(field.value);
        final hasKeys = widget.identities.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MouseRegion(
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: InkWell(
                onTap: hasKeys ? () => _pick(field) : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _open
                          ? AppColors.accent
                          : _hovered
                              ? AppColors.borderStrong
                              : AppColors.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.vpn_key_outlined,
                        size: 16,
                        color: AppColors.textFaint,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.label.toUpperCase(),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.8,
                                color: AppColors.textFaint,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              selected?.name ??
                                  (hasKeys
                                      ? 'Select a key...'
                                      : 'No keys imported yet'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: selected != null
                                    ? AppColors.textPrimary
                                    : AppColors.textFaint,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _open
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (field.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 12),
                child: Text(
                  field.errorText!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.danger,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Identity? _identityById(String? id) {
    if (id == null) return null;
    for (final identity in widget.identities) {
      if (identity.id == id) return identity;
    }
    return null;
  }
}
