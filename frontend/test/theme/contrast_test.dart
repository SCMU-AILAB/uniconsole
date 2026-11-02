import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/core/theme/theme.dart';

double contrast(Color a, Color b) => Contrast.ratio(a, b);

/// 半透明背景叠在底色上的实际颜色。
Color over(Color top, Color base) => Color.alphaBlend(top, base);

void main() {
  const minRatio = 4.5;
  final modes = {
    'light': (AppColors.light, StatusColors.light),
    'dark': (AppColors.dark, StatusColors.dark),
  };

  for (final MapEntry(key: name, value: (c, s)) in modes.entries) {
    group('$name 模式', () {
      for (final tone in StatusTone.values) {
        test('${tone.name} fg 在标签底上 ≥ 4.5:1', () {
          final sw = s.of(tone);
          final bg = over(sw.bg, c.surface);
          expect(
            contrast(sw.fg, bg),
            greaterThanOrEqualTo(minRatio),
            reason: 'fg ${sw.fg} on bg ${sw.bg} over surface',
          );
        });
        test('${tone.name} fg 在 surface 上 ≥ 4.5:1', () {
          expect(
            contrast(s.of(tone).fg, c.surface),
            greaterThanOrEqualTo(minRatio),
          );
        });
      }

      final textPairs = <String, (Color, Color)>{
        'label / windowBackground': (c.label, c.windowBackground),
        'label / surface': (c.label, c.surface),
        'secondaryLabel / windowBackground': (
          c.secondaryLabel,
          c.windowBackground,
        ),
        'secondaryLabel / surface': (c.secondaryLabel, c.surface),
        'secondaryLabel / sidebarBackground': (
          c.secondaryLabel,
          c.sidebarBackground,
        ),
        'tertiaryLabel / surface': (c.tertiaryLabel, c.surface),
        'link / surface': (c.link, c.surface),
        'onAccent / emergency': (c.onAccent, c.emergency),
        'hudSecondary / hudOverlay(视频底)': (
          c.hudSecondary,
          over(c.hudOverlay, c.videoBackground),
        ),
      };
      textPairs.forEach((label, pair) {
        test('$label ≥ 4.5:1', () {
          expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(minRatio));
        });
      });

      test('onAccent / accentFill ≥ 4.5:1', () {
        expect(
          contrast(c.onAccent, c.accentFill),
          greaterThanOrEqualTo(minRatio),
        );
      });

      test('默认 accentFill 为 #0071E3（§12）', () {
        expect(c.accentFill, const Color(0xFF0071E3));
      });

      test('accent 作为非文字元素在 surface 上 ≥ 3:1', () {
        expect(contrast(c.accent, c.surface), greaterThanOrEqualTo(3));
      });

      // 设置页 6 个色板：切换后 accentFill 上的白字仍 ≥ 4.5:1。
      for (final sw in AccentSwatch.values) {
        test('色板 ${sw.label}：accentFill 白字 ≥ 4.5:1', () {
          final picked = c.copyWith(accent: sw.forBrightness(c.brightness));
          expect(picked.accent, sw.forBrightness(c.brightness));
          expect(
            contrast(picked.onAccent, picked.accentFill),
            greaterThanOrEqualTo(minRatio),
            reason: '${sw.name} fill ${picked.accentFill}',
          );
          // 只加深、不换色相（灰色无色相，跳过色相比较）。
          final a = HSLColor.fromColor(picked.accent);
          final f = HSLColor.fromColor(picked.accentFill);
          expect(f.lightness, lessThanOrEqualTo(a.lightness + 1e-6));
          if (a.saturation > 0.05 && sw != AccentSwatch.blue) {
            expect((f.hue - a.hue).abs(), lessThan(1.5));
          }
        });
      }
    });
  }
}
