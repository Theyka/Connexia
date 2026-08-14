import 'package:connexia/core/db/database.dart';
import 'package:connexia/core/terminal/themes.dart';
import 'package:connexia/ui/state/providers.dart';
import 'package:connexia/ui/state/settings_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  TerminalView terminalViewInTree(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView));

  testWidgets(
      'changing the terminal theme through the settings controller '
      'reaches the TerminalView widget', (tester) async {
    final controller = container.read(settingsControllerProvider);
    await controller.load();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: _ThemeHarness(
              Terminal(maxLines: 100),
              TerminalController(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      terminalViewInTree(tester).theme,
      equals(terminalThemeByName('Default').theme),
    );

    await controller.update(const AppSettings(terminalTheme: 'Solarized Light'));
    await tester.pump();

    expect(
      terminalViewInTree(tester).theme,
      equals(terminalThemeByName('Solarized Light').theme),
    );

    await controller.update(const AppSettings(terminalTheme: 'Dracula'));
    await tester.pump();

    expect(
      terminalViewInTree(tester).theme,
      equals(terminalThemeByName('Dracula').theme),
    );
  });

  test('the selected theme survives a controller restart via the database',
      () async {
    final first = container.read(settingsControllerProvider);
    await first.update(const AppSettings(terminalTheme: 'Dracula'));
    expect(first.settings.terminalTheme, 'Dracula');

    final second = SettingsController(db);
    await second.load();
    expect(second.settings.terminalTheme, 'Dracula');
  });

  test('every settings preset resolves to a theme by name', () {
    for (final preset in terminalThemePresets) {
      expect(terminalThemeByName(preset.name).name, preset.name);
    }
  });
}

class _ThemeHarness extends ConsumerWidget {
  const _ThemeHarness(this.terminal, this.controller);

  final Terminal terminal;
  final TerminalController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).settings;
    final theme = terminalThemeByName(settings.terminalTheme).theme;
    return TerminalView(
      terminal,
      controller: controller,
      theme: theme,
      textStyle: const TerminalStyle(
        fontSize: 12,
        fontFamily: 'JetBrainsMono',
        height: 1.15,
      ),
      backgroundOpacity: 1,
    );
  }
}
