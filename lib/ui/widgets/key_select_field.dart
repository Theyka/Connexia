import 'package:flutter/material.dart';

import '../../core/db/database.dart';
import '../theme/app_colors.dart';
import 'select_field.dart';

class KeySelectField extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return FormField<String?>(
      initialValue: value,
      validator: validator,
      builder: (field) {
        final hasKeys = identities.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasKeys)
              SelectField<String?>(
                value: field.value,
                label: label,
                icon: Icons.vpn_key_outlined,
                searchable: identities.length >= 8,
                options: [
                  for (final identity in identities)
                    SelectOption<String?>(
                      identity.id,
                      identity.name,
                      subtitle: identity.comment.isEmpty
                          ? null
                          : identity.comment,
                      icon: Icons.vpn_key_outlined,
                    ),
                ],
                onChanged: (v) {
                  field.didChange(v);
                  onChanged?.call(v);
                },
              )
            else
              _NoKeysBox(label: label),
            if (field.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 12),
                child: Text(
                  field.errorText!,
                  style: const TextStyle(fontSize: 12, color: AppColors.danger),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NoKeysBox extends StatelessWidget {
  const _NoKeysBox({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
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
                      label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color: AppColors.textFaint,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'No keys imported yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: AppColors.textFaint,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
