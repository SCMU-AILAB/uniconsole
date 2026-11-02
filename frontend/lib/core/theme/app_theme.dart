import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_typography.dart';
import 'contrast.dart';
import 'status_colors.dart';

abstract final class AppTheme {
  /// [swatch] 为设置里选的强调色；默认蓝色直接用 token 原值。
  static ThemeData light({AccentSwatch swatch = AccentSwatch.blue}) => _build(
    swatch == AccentSwatch.blue
        ? AppColors.light
        : AppColors.light.copyWith(accent: swatch.light),
    StatusColors.light,
  );

  static ThemeData dark({AccentSwatch swatch = AccentSwatch.blue}) => _build(
    swatch == AccentSwatch.blue
        ? AppColors.dark
        : AppColors.dark.copyWith(accent: swatch.dark),
    StatusColors.dark,
  );

  static ThemeData _build(AppColors c, StatusColors s) {
    final type = AppTypography.forPlatform(defaultTargetPlatform);
    return ThemeData(
      brightness: c.brightness,
      useMaterial3: true,
      scaffoldBackgroundColor: c.windowBackground,
      canvasColor: c.windowBackground,
      dividerColor: c.separator,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: c.fillSecondary,
      focusColor: c.accentRing,
      visualDensity: VisualDensity.compact,
      colorScheme: ColorScheme.fromSeed(
        seedColor: c.accent,
        brightness: c.brightness,
        primary: c.accent,
        onPrimary: c.onAccent,
        surface: c.surface,
        onSurface: c.label,
        error: c.emergency,
      ),
      textTheme: TextTheme(
        bodyMedium: type.body.copyWith(color: c.label),
        bodySmall: type.subhead.copyWith(color: c.secondaryLabel),
        labelLarge: type.subheadMedium.copyWith(color: c.label),
        titleMedium: type.toolbarTitle.copyWith(color: c.label),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: c.accentRing,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          c.decorativeGray.withValues(alpha: 0.5),
        ),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: type.caption.copyWith(color: c.surface),
        decoration: BoxDecoration(
          color: c.label.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      extensions: [c, s, type],
    );
  }
}

/// 组件内取 token 的唯一入口。
extension AppThemeContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
  StatusColors get status => Theme.of(this).extension<StatusColors>()!;
  AppTypography get type => Theme.of(this).extension<AppTypography>()!;
}
