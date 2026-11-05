import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'app/destinations.dart';
import 'app/router.dart';
import 'core/dev/debug_screenshot.dart';
import 'core/platform/orientation.dart';
import 'core/theme/theme.dart';
import 'core/widgets/widgets.dart';
import 'data/api/live_auth_repository.dart';
import 'data/api/token_store.dart';
import 'data/mock/mock_repositories.dart';
import 'data/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppOrientation.portrait();
  // 真实后端登录：先从钥匙串恢复会话，路由守卫启动时就知道是否已登录。
  final auth = debugMockAuth
      ? null
      : await LiveAuthRepository.restore(SecureTokenStore());
  final container = ProviderContainer(
    overrides: [
      if (auth != null) authRepositoryProvider.overrideWithValue(auth),
      if (debugSignedOut)
        mockWorldProvider.overrideWith((ref) {
          final world = MockWorld(signedIn: false);
          ref.onDispose(world.dispose);
          return world;
        }),
    ],
  );
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
  // 校验恢复的会话（已在服务端失效时回到登录页）并刷新当前成员。
  unawaited(auth?.refresh());
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
    auth: ref.read(authRepositoryProvider),
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
