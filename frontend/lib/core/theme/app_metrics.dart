import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

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

/// 间距：4pt 网格（HANDOFF.md §13）。所有内外边距与间隔都必须取自这里。
///
/// 命名即倍数：x3 = 3 × 4 = 12。唯一例外是 [half]（2pt），只用于紧贴关系：
/// 分段控件轨道内边距、标题与副标题之间、导航项之间的细缝。
abstract final class AppSpacing {
  static const double half = 2;
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x7 = 28;
  static const double x8 = 32;
  static const double x9 = 36;

  /// 内容区内边距（水平）
  static const double page = x6;

  /// 卡片内边距
  static const double card = x4;

  /// 区块之间
  static const double section = x5;
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

  /// 按当前窗口判断。手机（iOS / Android）按短边判断，横屏时仍是移动布局；
  /// 桌面窗口按宽度判断。
  static LayoutSize ofContext(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final phone =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    if (phone && size.shortestSide < 600) return compact;
    return of(size.width);
  }

  static LayoutSize of(double width) {
    if (width >= 1280) return wide;
    if (width >= 900) return expanded;
    if (width >= 600) return medium;
    return compact;
  }

  bool get isMobile => this == compact;
}
