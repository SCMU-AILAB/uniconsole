import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app/destinations.dart';
import 'app/router.dart';
import 'core/dev/debug_screenshot.dart';
import 'core/platform/orientation.dart';
import 'core/theme/theme.dart';
import 'core/widgets/widgets.dart';
import 'data/providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppOrientation.portrait();
  final container = ProviderContainer();
  switch (debugThemeOverride) {
    case 'light':
      container.read(themeModeProvider.notifier).set(ThemeMode.light);
    case 'dark':
      container.read(themeModeProvider.notifier).set(ThemeMode.dark);
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: UniConsoleApp(
        initialLocation: debugInitialRoute ?? Routes.devices,
      ),
    ),
  );
  maybeCaptureDebugScreenshot();
}

class UniConsoleApp extends ConsumerStatefulWidget {
  const UniConsoleApp({super.key, this.initialLocation = Routes.devices});

  final String initialLocation;

  @override
  ConsumerState<UniConsoleApp> createState() => _UniConsoleAppState();
}

class _UniConsoleAppState extends ConsumerState<UniConsoleApp> {
  late final GoRouter _router = buildRouter(
    initialLocation: widget.initialLocation,
  );

  @override
  void initState() {
    super.initState();
    if (debugDemoPush) {
      Future<void>.delayed(
        const Duration(seconds: 1),
        () => ref.read(mockWorldProvider).alerts.raiseDemo(),
      );
    }
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(accentProvider);
    return MaterialApp.router(
      title: 'UniConsole',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(swatch: accent),
      darkTheme: AppTheme.dark(swatch: accent),
      themeMode: ref.watch(themeModeProvider),
      // 外观切换整体交叉淡化（§13）。
      themeAnimationDuration: AppMotion.appearance,
      themeAnimationCurve: AppMotion.appearanceCurve,
      routerConfig: _router,
      builder: (context, child) => HudOpacity(
        opacity: ref.watch(preferencesProvider).hudOpacity,
        child: child!,
      ),
    );
  }
}
