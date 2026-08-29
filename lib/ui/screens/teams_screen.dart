import 'package:flutter/material.dart';

import '../widgets/teams_settings_panel.dart';

/// Standalone Teams section (moved out of Settings). The panel is a
/// self-scrolling ListView that manages its own data loading.
class TeamsScreen extends StatelessWidget {
  const TeamsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const TeamsSettingsPanel();
  }
}
