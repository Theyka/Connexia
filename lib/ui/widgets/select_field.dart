import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class SelectOption<T> {
  const SelectOption(this.value, this.label, {this.subtitle, this.icon});

  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
}

class SelectField<T extends Object?> extends StatefulWidget {
  const SelectField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.label,
    this.helperText,
    this.icon,
    this.searchable,
  });

  final T? value;
  final List<SelectOption<T>> options;
  final ValueChanged<T?> onChanged;
  final String label;
  final String? helperText;
  final IconData? icon;

  final bool? searchable;

  @override
  State<SelectField<T>> createState() => _SelectFieldState<T>();
}

class _SelectFieldState<T extends Object?> extends State<SelectField<T>> {
  bool _hovered = false;
  bool _open = false;

  bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  SelectOption<T>? get _selected {
    for (final option in widget.options) {
      if (option.value == widget.value) return option;
    }
    return null;
  }

  Future<void> _pick() async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    setState(() => _open = true);
    final searchable = widget.searchable ?? widget.options.length >= 8;
    final SelectOption<T>? picked;
    if (_isTouch) {
      picked = await _showSheet(searchable);
    } else {
      final anchor = Rect.fromPoints(
        box.localToGlobal(Offset.zero),
        box.localToGlobal(box.size.bottomRight(Offset.zero)),
      ).shift(-overlay.localToGlobal(Offset.zero));
      picked = await Navigator.of(context).push(
        _SelectPopupRoute<T>(
          anchor: anchor,
          options: widget.options,
          selected: widget.value,
          searchable: searchable,
        ),
      );
    }
    if (!mounted) return;
    setState(() => _open = false);
    if (picked != null) widget.onChanged(picked.value);
  }

  Future<SelectOption<T>?> _showSheet(bool searchable) {
    return showModalBottomSheet<SelectOption<T>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 10, bottom: 6),
                    decoration: BoxDecoration(
                      color: AppColors.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Flexible(
                    child: _SelectPanel<T>(
                      options: widget.options,
                      selected: widget.value,
                      searchable: searchable,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkWell(
            onTap: _pick,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  if (widget.icon != null) ...[
                    Icon(widget.icon, size: 16, color: AppColors.textFaint),
                    const SizedBox(width: 10),
                  ],
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
                          selected?.label ?? 'Select...',
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
                    _open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 12),
            child: Text(
              widget.helperText!,
              style: TextStyle(fontSize: 11.5, color: AppColors.textFaint),
            ),
          ),
      ],
    );
  }
}

class _SelectPanel<T extends Object?> extends StatefulWidget {
  const _SelectPanel({
    required this.options,
    required this.selected,
    required this.searchable,
  });

  final List<SelectOption<T>> options;
  final T? selected;
  final bool searchable;

  @override
  State<_SelectPanel<T>> createState() => _SelectPanelState<T>();
}

class _SelectPanelState<T extends Object?> extends State<_SelectPanel<T>> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(SelectOption<T> option) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return option.label.toLowerCase().contains(q) ||
        (option.subtitle?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.options.where(_matches).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.searchable)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search...',
                isDense: true,
                filled: true,
                fillColor: AppColors.surfaceAlt,
                prefixIcon: const Icon(Icons.search, size: 16),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.accent),
                ),
                hintStyle: TextStyle(color: AppColors.textFaint),
              ),
            ),
          ),
        Flexible(
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No matches',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final option = filtered[index];
                    final selected = option.value == widget.selected;
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(option),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            if (option.icon != null) ...[
                              Icon(
                                option.icon,
                                size: 16,
                                color: selected
                                    ? AppColors.accent
                                    : AppColors.textSecondary,
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    option.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: selected
                                          ? AppColors.accent
                                          : AppColors.textPrimary,
                                    ),
                                  ),
                                  if (option.subtitle != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      option.subtitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'JetBrainsMono',
                                        color: AppColors.textFaint,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (selected) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.check,
                                size: 16,
                                color: AppColors.accent,
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SelectPopupRoute<T extends Object?> extends PopupRoute<SelectOption<T>> {
  _SelectPopupRoute({
    required this.anchor,
    required this.options,
    required this.selected,
    required this.searchable,
  });

  final Rect anchor;
  final List<SelectOption<T>> options;
  final T? selected;
  final bool searchable;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _SelectPopupLayoutDelegate(anchor),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.borderStrong),
            boxShadow: const [
              BoxShadow(
                color: Color(0x50000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: _SelectPanel<T>(
            options: options,
            selected: selected,
            searchable: searchable,
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }
}

class _SelectPopupLayoutDelegate extends SingleChildLayoutDelegate {
  _SelectPopupLayoutDelegate(this.anchor);

  final Rect anchor;

  static const double _gap = 4;
  static const double _margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = math.max(200.0, constraints.maxWidth - _margin * 2);
    // Match the width of the field the menu is anchored to.
    final width = anchor.width.clamp(200.0, maxW).toDouble();
    final maxH = math.max(160.0, constraints.maxHeight - _margin * 2);
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: maxH);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Drop down from the input, but flip above it when there is not enough
    // room left below.
    var top = anchor.bottom + _gap;
    if (top + childSize.height > size.height - _margin) {
      final above = anchor.top - childSize.height - _gap;
      top = above >= _margin
          ? above
          : math.max(_margin, size.height - childSize.height - _margin);
    }
    final left = anchor.left
        .clamp(
          _margin,
          math.max(_margin, size.width - childSize.width - _margin),
        )
        .toDouble();
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_SelectPopupLayoutDelegate oldDelegate) {
    return oldDelegate.anchor != anchor;
  }
}
