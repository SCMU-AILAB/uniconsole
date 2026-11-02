import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/dev/debug_screenshot.dart';
import 'core/theme/theme.dart';
import 'features/gallery/gallery_page.dart';

void main() {
  final container = ProviderContainer();
  if (debugStartDark) {
    container.read(themeModeProvider.notifier).set(ThemeMode.dark);
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const UniConsoleApp(),
    ),
  );
  maybeCaptureDebugScreenshot();
}

class UniConsoleApp extends ConsumerWidget {
  const UniConsoleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'UniConsole',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      // 第 2 阶段替换为 go_router + AppShell。
      home: const GalleryPage(),
    );
  }
}
