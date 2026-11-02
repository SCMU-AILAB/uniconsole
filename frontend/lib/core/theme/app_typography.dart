import 'package:flutter/material.dart';

/// 字体（HANDOFF.md §3.5 / §11）。
///
/// Apple 平台使用系统默认字体（SF Pro + PingFang SC），不打包字体文件；
/// 其他平台按 fallback 链选择。所有样式都开启等宽数字。
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography._(this._base, this._mono);

  factory AppTypography.forPlatform(TargetPlatform platform) {
    final isApple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    final base = TextStyle(
      fontFamily: isApple ? null : _sansFor(platform),
      fontFamilyFallback: isApple ? const ['PingFang SC'] : _sansFallback,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.3,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final mono = TextStyle(
      fontFamily: isApple ? 'SF Mono' : _monoFor(platform),
      fontFamilyFallback: const [
        'Menlo',
        'Consolas',
        'DejaVu Sans Mono',
        'PingFang SC',
        'Microsoft YaHei',
      ],
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.35,
    );
    return AppTypography._(base, mono);
  }

  static String? _sansFor(TargetPlatform p) => switch (p) {
    TargetPlatform.windows => 'Segoe UI',
    TargetPlatform.linux => 'Noto Sans',
    _ => null,
  };

  static String? _monoFor(TargetPlatform p) => switch (p) {
    TargetPlatform.windows => 'Consolas',
    TargetPlatform.linux => 'DejaVu Sans Mono',
    _ => 'Menlo',
  };

  static const _sansFallback = [
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'PingFang SC',
  ];

  final TextStyle _base;
  final TextStyle _mono;

  TextStyle _s(
    double size, [
    FontWeight weight = FontWeight.w400,
    double? ls,
  ]) => _base.copyWith(fontSize: size, fontWeight: weight, letterSpacing: ls);

  // ---- 桌面 ----
  /// 正文 13
  TextStyle get body => _s(13);
  TextStyle get bodyMedium => _s(13, FontWeight.w500);

  /// 卡片标题 13 semibold
  TextStyle get cardTitle => _s(13, FontWeight.w600);

  /// 卡片名称 14 semibold（设备卡名、品牌名）
  TextStyle get headline => _s(14, FontWeight.w600);

  /// 次要 12（按钮、筛选、统计卡说明）
  TextStyle get subhead => _s(12);
  TextStyle get subheadMedium => _s(12, FontWeight.w500);
  TextStyle get subheadStrong => _s(12, FontWeight.w600);

  /// 次要 11.5（卡片元信息、标签）
  TextStyle get footnote => _s(11.5);
  TextStyle get footnoteMedium => _s(11.5, FontWeight.w500);

  /// 次要 11（工具栏副标题、侧边栏分组标题、徽标）
  TextStyle get caption => _s(11);
  TextStyle get captionStrong => _s(11, FontWeight.w600);

  /// 10–10.5 的微型文字（时间轴刻度、事件标记）
  TextStyle get micro => _s(10.5);
  TextStyle get microStrong => _s(10.5, FontWeight.w600);

  /// 工具栏标题 15 semibold
  TextStyle get toolbarTitle => _s(15, FontWeight.w600);

  /// HUD/IMU 数值 15 semibold
  TextStyle get metric => _s(15, FontWeight.w600);

  /// 区块标题 17 semibold
  TextStyle get sectionTitle => _s(17, FontWeight.w600);

  /// 详情标题 20 / 22 bold
  TextStyle get detailTitleSmall => _s(20, FontWeight.w700);
  TextStyle get detailTitle => _s(22, FontWeight.w700, -0.3);

  /// 统计数字 26 / 30 semibold
  TextStyle get stat => _s(26, FontWeight.w600, -0.5);
  TextStyle get statLarge => _s(30, FontWeight.w600, -0.5);

  // ---- 移动 ----
  TextStyle get largeTitle => _s(34, FontWeight.w700, 0.2);
  TextStyle get mobileHeadline => _s(16, FontWeight.w600);
  TextStyle get mobileBody => _s(15);
  TextStyle get mobileBodyLarge => _s(17);
  TextStyle get mobileFootnote => _s(13);
  TextStyle get tabLabel => _s(10, FontWeight.w500);

  // ---- 等宽（指令、日志、终端、快捷键） ----
  TextStyle get mono => _mono.copyWith(fontSize: 11.5);
  TextStyle get monoLarge => _mono.copyWith(fontSize: 12);

  @override
  AppTypography copyWith() => this;

  @override
  AppTypography lerp(AppTypography? other, double t) =>
      other == null || t < 0.5 ? this : other;
}
