import 'package:flutter/cupertino.dart';

import '../theme/theme.dart';

/// 导航意图，作为 go_router 的 `extra` 传入。
enum NavIntent {
  /// 层级推入（iOS 推入动画、可右滑返回）。
  push,
}

/// 路由页面的转场（§13）：
///
/// - 根页面（侧边栏、标签栏切换）：瞬时出现，与 macOS / iOS 原生一致；
/// - 层级进入（push）：iOS 推入动画，支持左缘右滑返回，下层页面带视差；
/// - 减弱动态效果：推入改为淡入，根页面仍瞬时。
///
/// 是否推入由导航意图决定：`context.push(location, extra: NavIntent.push)`。
/// 其余导航（侧边栏、标签栏的 `go`）都按根页面处理。
class AppRoutePage<T> extends Page<T> {
  const AppRoutePage({
    required this.child,
    this.push = false,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  /// 以层级推入的方式进入。
  final bool push;

  @override
  Route<T> createRoute(BuildContext context) => _AppPageRoute<T>(page: this);
}

class _AppPageRoute<T> extends PageRoute<T>
    with CupertinoRouteTransitionMixin<T> {
  _AppPageRoute({required AppRoutePage<T> page}) : super(settings: page);

  AppRoutePage<T> get _page => settings as AppRoutePage<T>;

  /// 页面自带不透明底色：推入时完整盖住下层页面（页面内容本身是透明的）。
  @override
  Widget buildContent(BuildContext context) {
    final c = context.colors;
    final mobile = LayoutSize.of(MediaQuery.sizeOf(context).width).isMobile;
    return ColoredBox(
      color: mobile ? c.mobileBackground : c.windowBackground,
      child: _page.child,
    );
  }

  /// 只有推入时才压暗下层页面（iOS 行为）；根页面没有遮罩。
  @override
  Color? get barrierColor => _page.push ? super.barrierColor : null;

  @override
  String? get title => null;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  /// 根页面不做进入动画。
  @override
  Duration get transitionDuration =>
      _page.push ? super.transitionDuration : Duration.zero;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = AppMotion.reduced(context);
    if (!_page.push) {
      if (reduced) return child;
      // 自己不动，但被上层页面推入时保留 iOS 的视差位移。
      return CupertinoPageTransition(
        primaryRouteAnimation: kAlwaysCompleteAnimation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: false,
        child: child,
      );
    }
    if (reduced) return FadeTransition(opacity: animation, child: child);
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
