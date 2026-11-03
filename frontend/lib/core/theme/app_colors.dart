import 'package:flutter/material.dart';

import 'contrast.dart';

/// 颜色 tokens（HANDOFF.md §3.1 / §3.2 / §3.4 / §11）。
///
/// 页面和组件只能通过 `context.colors` 取色，禁止写死颜色值。
/// 标注「推导值」的是设计稿未直接给出、按 Apple 深色惯例推导的值。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.brightness,
    required this.windowBackground,
    required this.surface,
    required this.toolbarBackground,
    required this.sidebarBackground,
    required this.sidebarSelected,
    required this.sidebarBorder,
    required this.sidebarUserCard,
    required this.separator,
    required this.separatorSubtle,
    required this.fillSecondary,
    required this.segmentedTrack,
    required this.segmentedSelected,
    required this.controlBorder,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.decorativeGray,
    required this.decorativeGrayLight,
    required this.accent,
    required this.accentFill,
    required this.accentRing,
    required this.onAccent,
    required this.link,
    required this.emergency,
    required this.emergencyReleased,
    required this.rowSelected,
    required this.switchOn,
    required this.badge,
    required this.logo,
    required this.onLogo,
    required this.mobileBackground,
    required this.mobileControlFill,
    required this.tabBarBackground,
    required this.tabBarBorder,
    required this.chartBackground,
    required this.mapBackground,
    required this.mapGrid,
    required this.mapWall,
    required this.mapRoomFill,
    required this.mapOverlay,
    required this.mapMarker,
    required this.videoBackground,
    required this.pointCloudBackground,
    required this.hudOverlay,
    required this.hudText,
    required this.hudSecondary,
    required this.hudTertiary,
    required this.hudBorder,
    required this.hudSelected,
    required this.live,
    required this.cloudNear,
    required this.cloudMid,
    required this.cloudFar,
    required this.shadow,
    required this.avatarPalette,
  });

  final Brightness brightness;

  // 窗口与容器
  final Color windowBackground;
  final Color surface;
  final Color toolbarBackground;
  final Color sidebarBackground;
  final Color sidebarSelected;
  final Color sidebarBorder;
  final Color sidebarUserCard;
  final Color separator;
  final Color separatorSubtle;
  final Color fillSecondary;
  final Color segmentedTrack;
  final Color segmentedSelected;
  final Color controlBorder;

  // 文字
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;

  /// 仅用于图标/装饰（及禁用态文字），不能用于正文。
  final Color decorativeGray;
  final Color decorativeGrayLight;

  // 强调（HANDOFF.md §12）
  /// 非文字用途：图标、选中外圈、进度条、开关、描边。只要求 3:1。
  final Color accent;

  /// 承载白字（[onAccent]）的底色：主按钮、选中分段、对讲按钮。白字 ≥ 4.5:1。
  final Color accentFill;
  final Color accentRing;
  final Color onAccent;
  final Color link;
  final Color emergency;

  /// 急停已触发后按钮变为「解除急停」时的底色（Control.dc.html `stopBg`）。
  final Color emergencyReleased;
  final Color rowSelected;
  final Color switchOn;
  final Color badge;
  final Color logo;
  final Color onLogo;

  // 移动端
  final Color mobileBackground;
  final Color mobileControlFill;
  final Color tabBarBackground;
  final Color tabBarBorder;

  // 图表与地图
  final Color chartBackground;
  final Color mapBackground;
  final Color mapGrid;
  final Color mapWall;
  final Color mapRoomFill;
  final Color mapOverlay;

  /// 地图上普通设备标记（白色首字母在上，Fleet.dc.html #3A3A3C）。
  final Color mapMarker;

  // 视频与传感器面板（§3.4，两种模式相同）
  final Color videoBackground;
  final Color pointCloudBackground;
  final Color hudOverlay;
  final Color hudText;
  final Color hudSecondary;
  final Color hudTertiary;
  final Color hudBorder;
  final Color hudSelected;
  final Color live;
  final Color cloudNear;
  final Color cloudMid;
  final Color cloudFar;

  final Color shadow;
  final List<Color> avatarPalette;

  bool get isDark => brightness == Brightness.dark;

  /// 开关/滑块圆钮（两种模式都是白色）。
  Color get knob => const Color(0xFFFFFFFF);

  /// 悬停/按下时叠加到底色上的色调：浅色压暗、深色提亮。
  Color get stateOverlay =>
      isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);

  /// 彩色实底按钮（急停）悬停/按下时的压暗色。
  Color get pressShade => const Color(0xFF000000);

  /// 远程终端配色（Maintenance.dc.html），两种模式相同。
  TerminalColors get terminal => const TerminalColors();

  static const _avatarPalette = [
    Color(0xFF5856D6),
    Color(0xFF0071E3),
    Color(0xFFAF52DE),
    Color(0xFFFF9500),
    Color(0xFF248A3D),
    Color(0xFFFF2D55),
    Color(0xFF5AC8FA),
    Color(0xFF8E8E93),
  ];

  static const light = AppColors(
    brightness: Brightness.light,
    windowBackground: Color(0xFFF5F5F7),
    surface: Color(0xFFFFFFFF),
    toolbarBackground: Color(0xFFFFFFFF),
    sidebarBackground: Color(0xFFF2F2F5),
    sidebarSelected: Color(0xFFDCDCE2),
    sidebarBorder: Color(0xFFE0E0E5),
    sidebarUserCard: Color(0xFFE8E8EC),
    separator: Color(0xFFE5E5EA),
    separatorSubtle: Color(0xFFEFEFF2),
    fillSecondary: Color(0xFFF2F2F7),
    segmentedTrack: Color(0xFFEBEBEF),
    segmentedSelected: Color(0xFFFFFFFF),
    controlBorder: Color(0xFFD8D8DD),
    label: Color(0xFF1D1D1F),
    secondaryLabel: Color(0xFF636366),
    tertiaryLabel: Color(0xFF3A3A3C),
    decorativeGray: Color(0xFF8E8E93),
    decorativeGrayLight: Color(0xFFAEAEB2),
    accent: Color(0xFF0071E3),
    accentFill: Color(0xFF0071E3),
    accentRing: Color(0x330071E3),
    onAccent: Color(0xFFFFFFFF),
    link: Color(0xFF0058B8),
    emergency: Color(0xFFD70015),
    emergencyReleased: Color(0xFF636366),
    rowSelected: Color(0xFFEEF4FE),
    switchOn: Color(0xFF34C759),
    badge: Color(0xFFFF3B30),
    logo: Color(0xFF1D1D1F),
    onLogo: Color(0xFFFFFFFF),
    mobileBackground: Color(0xFFF2F2F7),
    mobileControlFill: Color(0xFFE3E3E8),
    tabBarBackground: Color(0xF0F9F9F9),
    tabBarBorder: Color(0xFFD8D8DD),
    chartBackground: Color(0xFFFAFAFC),
    mapBackground: Color(0xFFFBFBFD),
    mapGrid: Color(0xFFEEEEF2),
    mapWall: Color(0xFFC7C7CC),
    mapRoomFill: Color(0xFFF2F2F7),
    mapOverlay: Color(0xF5FFFFFF),
    mapMarker: Color(0xFF3A3A3C),
    videoBackground: Color(0xFF121214),
    pointCloudBackground: Color(0xFF0E0E10),
    hudOverlay: Color(0xB81E1E20),
    hudText: Color(0xFFFFFFFF),
    hudSecondary: Color(0xFFAEAEB2),
    hudTertiary: Color(0xFFD1D1D6),
    hudBorder: Color(0x1FFFFFFF),
    hudSelected: Color(0x38FFFFFF),
    live: Color(0xFFFF453A),
    cloudNear: Color(0xFFFF9F0A),
    cloudMid: Color(0xFF64D2FF),
    cloudFar: Color(0xFF0A84FF),
    shadow: Color(0x1F000000),
    avatarPalette: _avatarPalette,
  );

  static const dark = AppColors(
    brightness: Brightness.dark,
    windowBackground: Color(0xFF1C1C1E),
    surface: Color(0xFF2C2C2E),
    toolbarBackground: Color(0xFF232325),
    sidebarBackground: Color(0xFF232325),
    sidebarSelected: Color(0xFF3A3A3C),
    sidebarBorder: Color(0xFF3A3A3C),
    sidebarUserCard: Color(0xFF2C2C2E),
    separator: Color(0xFF3A3A3C),
    separatorSubtle: Color(0xFF323234), // 推导值
    fillSecondary: Color(0xFF3A3A3C), // 推导值
    segmentedTrack: Color(0xFF3A3A3C), // 推导值
    segmentedSelected: Color(0xFF636366), // 推导值
    controlBorder: Color(0xFF48484A), // 推导值
    label: Color(0xFFF5F5F7),
    secondaryLabel: Color(0xFFAEAEB2),
    tertiaryLabel: Color(0xFFD1D1D6), // 推导值
    decorativeGray: Color(0xFF8E8E93),
    decorativeGrayLight: Color(0xFF636366), // 推导值
    accent: Color(0xFF0A84FF),
    accentFill: Color(0xFF0071E3),
    accentRing: Color(0x330A84FF),
    onAccent: Color(0xFFFFFFFF),
    link: Color(0xFF409CFF),
    emergency: Color(0xFFD70015),
    emergencyReleased: Color(0xFF636366),
    rowSelected: Color(0x2E0A84FF),
    switchOn: Color(0xFF30D158),
    badge: Color(0xFFFF453A), // 推导值
    logo: Color(0xFFF5F5F7),
    onLogo: Color(0xFF1C1C1E),
    mobileBackground: Color(0xFF1C1C1E), // 推导值
    mobileControlFill: Color(0xFF3A3A3C), // 推导值
    tabBarBackground: Color(0xF0232325), // 推导值
    tabBarBorder: Color(0xFF3A3A3C), // 推导值
    chartBackground: Color(0xFF232325), // 推导值
    mapBackground: Color(0xFF1F1F21), // 推导值
    mapGrid: Color(0xFF2A2A2C), // 推导值
    mapWall: Color(0xFF636366), // 推导值
    mapRoomFill: Color(0xFF2C2C2E), // 推导值
    mapOverlay: Color(0xF52C2C2E), // 推导值
    mapMarker: Color(0xFF636366), // 推导值：深色底上仍与白字 ≥ 4.5:1
    videoBackground: Color(0xFF121214),
    pointCloudBackground: Color(0xFF0E0E10),
    hudOverlay: Color(0xB81E1E20),
    hudText: Color(0xFFFFFFFF),
    hudSecondary: Color(0xFFAEAEB2),
    hudTertiary: Color(0xFFD1D1D6),
    hudBorder: Color(0x1FFFFFFF),
    hudSelected: Color(0x38FFFFFF),
    live: Color(0xFFFF453A),
    cloudNear: Color(0xFFFF9F0A),
    cloudMid: Color(0xFF64D2FF),
    cloudFar: Color(0xFF0A84FF),
    shadow: Color(0x66000000),
    avatarPalette: _avatarPalette,
  );

  /// 由强调色得到承载白字的底色：默认蓝两种模式都是 #0071E3，
  /// 其余颜色保持色相逐步加深，直到白字对比度 ≥ 4.5:1。
  static Color fillFor(Color accent) {
    if (accent == AccentSwatch.blue.light || accent == AccentSwatch.blue.dark) {
      return const Color(0xFF0071E3);
    }
    return Contrast.darkenUntil(accent, const Color(0xFFFFFFFF));
  }

  /// 强调色可在设置里切换（Settings.dc.html），其余 token 不变。
  @override
  AppColors copyWith({Color? accent, Color? link}) {
    if (accent == null && link == null) return this;
    final a = accent ?? this.accent;
    return AppColors(
      brightness: brightness,
      windowBackground: windowBackground,
      surface: surface,
      toolbarBackground: toolbarBackground,
      sidebarBackground: sidebarBackground,
      sidebarSelected: sidebarSelected,
      sidebarBorder: sidebarBorder,
      sidebarUserCard: sidebarUserCard,
      separator: separator,
      separatorSubtle: separatorSubtle,
      fillSecondary: fillSecondary,
      segmentedTrack: segmentedTrack,
      segmentedSelected: segmentedSelected,
      controlBorder: controlBorder,
      label: label,
      secondaryLabel: secondaryLabel,
      tertiaryLabel: tertiaryLabel,
      decorativeGray: decorativeGray,
      decorativeGrayLight: decorativeGrayLight,
      accent: a,
      accentFill: fillFor(a),
      accentRing: a.withValues(alpha: 0.2),
      onAccent: onAccent,
      link: link ?? this.link,
      emergency: emergency,
      emergencyReleased: emergencyReleased,
      rowSelected: a.withValues(alpha: isDark ? 0.18 : 0.07),
      switchOn: switchOn,
      badge: badge,
      logo: logo,
      onLogo: onLogo,
      mobileBackground: mobileBackground,
      mobileControlFill: mobileControlFill,
      tabBarBackground: tabBarBackground,
      tabBarBorder: tabBarBorder,
      chartBackground: chartBackground,
      mapBackground: mapBackground,
      mapGrid: mapGrid,
      mapWall: mapWall,
      mapRoomFill: mapRoomFill,
      mapOverlay: mapOverlay,
      mapMarker: mapMarker,
      videoBackground: videoBackground,
      pointCloudBackground: pointCloudBackground,
      hudOverlay: hudOverlay,
      hudText: hudText,
      hudSecondary: hudSecondary,
      hudTertiary: hudTertiary,
      hudBorder: hudBorder,
      hudSelected: hudSelected,
      live: live,
      cloudNear: cloudNear,
      cloudMid: cloudMid,
      cloudFar: cloudFar,
      shadow: shadow,
      avatarPalette: avatarPalette,
    );
  }

  /// 浅色 / 深色切换时逐色插值，配合 MaterialApp 的主题动画做交叉淡化（§13）。
  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      windowBackground: l(windowBackground, other.windowBackground),
      surface: l(surface, other.surface),
      toolbarBackground: l(toolbarBackground, other.toolbarBackground),
      sidebarBackground: l(sidebarBackground, other.sidebarBackground),
      sidebarSelected: l(sidebarSelected, other.sidebarSelected),
      sidebarBorder: l(sidebarBorder, other.sidebarBorder),
      sidebarUserCard: l(sidebarUserCard, other.sidebarUserCard),
      separator: l(separator, other.separator),
      separatorSubtle: l(separatorSubtle, other.separatorSubtle),
      fillSecondary: l(fillSecondary, other.fillSecondary),
      segmentedTrack: l(segmentedTrack, other.segmentedTrack),
      segmentedSelected: l(segmentedSelected, other.segmentedSelected),
      controlBorder: l(controlBorder, other.controlBorder),
      label: l(label, other.label),
      secondaryLabel: l(secondaryLabel, other.secondaryLabel),
      tertiaryLabel: l(tertiaryLabel, other.tertiaryLabel),
      decorativeGray: l(decorativeGray, other.decorativeGray),
      decorativeGrayLight: l(decorativeGrayLight, other.decorativeGrayLight),
      accent: l(accent, other.accent),
      accentFill: l(accentFill, other.accentFill),
      accentRing: l(accentRing, other.accentRing),
      onAccent: l(onAccent, other.onAccent),
      link: l(link, other.link),
      emergency: l(emergency, other.emergency),
      emergencyReleased: l(emergencyReleased, other.emergencyReleased),
      rowSelected: l(rowSelected, other.rowSelected),
      switchOn: l(switchOn, other.switchOn),
      badge: l(badge, other.badge),
      logo: l(logo, other.logo),
      onLogo: l(onLogo, other.onLogo),
      mobileBackground: l(mobileBackground, other.mobileBackground),
      mobileControlFill: l(mobileControlFill, other.mobileControlFill),
      tabBarBackground: l(tabBarBackground, other.tabBarBackground),
      tabBarBorder: l(tabBarBorder, other.tabBarBorder),
      chartBackground: l(chartBackground, other.chartBackground),
      mapBackground: l(mapBackground, other.mapBackground),
      mapGrid: l(mapGrid, other.mapGrid),
      mapWall: l(mapWall, other.mapWall),
      mapRoomFill: l(mapRoomFill, other.mapRoomFill),
      mapOverlay: l(mapOverlay, other.mapOverlay),
      mapMarker: l(mapMarker, other.mapMarker),
      videoBackground: l(videoBackground, other.videoBackground),
      pointCloudBackground: l(pointCloudBackground, other.pointCloudBackground),
      hudOverlay: l(hudOverlay, other.hudOverlay),
      hudText: l(hudText, other.hudText),
      hudSecondary: l(hudSecondary, other.hudSecondary),
      hudTertiary: l(hudTertiary, other.hudTertiary),
      hudBorder: l(hudBorder, other.hudBorder),
      hudSelected: l(hudSelected, other.hudSelected),
      live: l(live, other.live),
      cloudNear: l(cloudNear, other.cloudNear),
      cloudMid: l(cloudMid, other.cloudMid),
      cloudFar: l(cloudFar, other.cloudFar),
      shadow: l(shadow, other.shadow),
      avatarPalette: t < 0.5 ? avatarPalette : other.avatarPalette,
    );
  }
}

@immutable
class TerminalColors {
  const TerminalColors();

  Color get background => const Color(0xFF1C1C1E);
  Color get header => const Color(0xFF2C2C2E);
  Color get tabSelected => const Color(0xFF3A3A3C);
  Color get text => const Color(0xFFD1D1D6);
  Color get textSecondary => const Color(0xFFAEAEB2);
  Color get prompt => const Color(0xFF30D158);
  Color get path => const Color(0xFF64D2FF);
  Color get cursor => const Color(0xFFF2F2F7);
  Color get error => const Color(0xFFFF6961);
  Color get warning => const Color(0xFFFFB340);
}
