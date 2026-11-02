import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'contrast.dart';

/// 浅色 / 深色 / 跟随系统。默认跟随系统；第 6 阶段按账户同步。
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  void set(ThemeMode mode) => state = mode;

  void toggle() =>
      state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

/// 强调色（设置 › 外观）。accentFill 由 AppColors.fillFor 自动推导。
class AccentController extends Notifier<AccentSwatch> {
  @override
  AccentSwatch build() => AccentSwatch.blue;

  void set(AccentSwatch swatch) => state = swatch;
}

final accentProvider = NotifierProvider<AccentController, AccentSwatch>(
  AccentController.new,
);
