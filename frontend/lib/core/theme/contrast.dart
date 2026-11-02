import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show Brightness;

/// WCAG 2.x 对比度工具。
abstract final class Contrast {
  static double _channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  static double luminance(Color c) =>
      0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

  static double ratio(Color a, Color b) {
    final la = luminance(a), lb = luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// 保持色相与饱和度，逐步降低明度，直到 [on] 在其上的对比度 ≥ [min]。
  /// 已满足时原样返回。
  static Color darkenUntil(Color base, Color on, {double min = 4.5}) {
    if (ratio(on, base) >= min) return base;
    var hsl = HSLColor.fromColor(base);
    while (hsl.lightness > 0 && ratio(on, hsl.toColor()) < min) {
      hsl = hsl.withLightness(math.max(0, hsl.lightness - 0.005));
    }
    return hsl.toColor().withValues(alpha: base.a);
  }
}

/// 设置页（Settings.dc.html）可选的 6 个强调色。
enum AccentSwatch {
  blue('蓝色', Color(0xFF0071E3), Color(0xFF0A84FF)),
  indigo('靛蓝', Color(0xFF5856D6), Color(0xFF5E5CE6)),
  purple('紫色', Color(0xFFAF52DE), Color(0xFFBF5AF2)),
  green('绿色', Color(0xFF34C759), Color(0xFF30D158)),
  orange('橙色', Color(0xFFFF9500), Color(0xFFFF9F0A)),
  graphite('石墨', Color(0xFF8E8E93), Color(0xFF8E8E93));

  const AccentSwatch(this.label, this.light, this.dark);

  final String label;

  /// 浅色模式下的值（Apple 系统色浅色版）。
  final Color light;

  /// 深色模式下的值（Settings.dc.html 色板）。
  final Color dark;

  Color forBrightness(Brightness b) => b == Brightness.dark ? dark : light;
}
