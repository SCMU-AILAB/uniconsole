/// 尺寸、圆角、间距、断点（HANDOFF.md §3.6 / §11）。
abstract final class AppRadius {
  /// 小按钮、分段控件选中块
  static const double xs = 6;

  /// 搜索框、侧边栏导航项
  static const double sm = 7;

  /// 按钮
  static const double md = 8;

  /// 大按钮、急停
  static const double lg = 9;

  /// 内部分组、HUD 浮层
  static const double group = 10;

  /// 统计卡、移动卡片
  static const double tile = 12;

  /// 桌面卡片、视频面板
  static const double card = 14;

  /// 小标签（Tag）
  static const double tag = 5;
}

abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 10;
  static const double xl = 12;
  static const double xxl = 16;
  static const double section = 20;
  static const double page = 24;

  /// 卡片内边距
  static const double card = 14;
}

abstract final class AppSizes {
  static const double sidebarWidth = 224;
  static const double sidebarRailWidth = 64;
  static const double navItemHeight = 30;
  static const double toolbarMinHeight = 52;
  static const double inspectorWidth = 340;
  static const double minTouchTarget = 44;
  static const double mobileTabBarHeight = 83;

  /// 侧边栏/工具栏图标
  static const double icon = 17;
  static const double iconStroke = 1.8;
}

/// 响应式断点（§11 替换 §4）。
enum LayoutSize {
  /// < 600：移动布局（底部标签栏）
  compact,

  /// 600–900：桌面布局，侧边栏收为 64px 图标栏
  medium,

  /// 900–1280：右栏堆到内容下方
  expanded,

  /// ≥ 1280：侧边栏 + 内容 + 右栏
  wide;

  static LayoutSize of(double width) {
    if (width >= 1280) return wide;
    if (width >= 900) return expanded;
    if (width >= 600) return medium;
    return compact;
  }

  bool get isMobile => this == compact;
}
