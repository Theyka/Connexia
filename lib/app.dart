import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/screens/home_screen.dart';
import 'ui/state/providers.dart';
import 'ui/theme/app_theme.dart';
import 'core/debug_log.dart';

class ConnexiaApp extends ConsumerStatefulWidget {
  const ConnexiaApp({super.key});

  @override
  ConsumerState<ConnexiaApp> createState() => _ConnexiaAppState();
}

class _ConnexiaAppState extends ConsumerState<ConnexiaApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // The window is closing: end the log entries of any still-open
      // sessions so they don't stay marked as active.
      ref.read(sessionManagerProvider).closeAllSessionLogs();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    writeDebugLog('App build: logical=${size.width}x${size.height} '
        'dpr=$dpr physical=${size.width * dpr}x${size.height * dpr}');
    return MaterialApp(
      title: 'Connexia',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
