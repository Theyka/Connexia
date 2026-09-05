import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Small pulsing teal dot shown at the right side of a session tab or chip
/// while the session received output that the user hasn't seen yet.
class NewOutputDot extends StatefulWidget {
  const NewOutputDot({super.key});

  @override
  State<NewOutputDot> createState() => _NewOutputDotState();
}

class _NewOutputDotState extends State<NewOutputDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.55),
              blurRadius: 5,
            ),
          ],
        ),
      ),
    );
  }
}
