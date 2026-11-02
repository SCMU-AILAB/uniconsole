import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// iOS 风格大标题滚动视图（HANDOFF.md §12）。
///
/// 展开时：左对齐 34pt 大标题，透明底。
/// 滚动时：大标题上移淡出，收起为 17pt 居中标题栏；内容滚到标题栏下方后
/// 显示半透明毛玻璃背景和底部分割线。右上角操作始终可见。
class LargeTitleScrollView extends StatelessWidget {
  const LargeTitleScrollView({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.leading,
    this.controller,
  });

  final String title;
  final List<Widget> slivers;

  /// 标题栏右侧（圆形图标按钮等）。
  final List<Widget> actions;

  /// 标题栏左侧（返回按钮）。
  final Widget? leading;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return CustomScrollView(
      controller: controller,
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _LargeTitleHeader(
            title: title,
            topPadding: top,
            actions: actions,
            leading: leading,
            colors: context.colors,
            type: context.type,
          ),
        ),
        ...slivers,
      ],
    );
  }
}

class _LargeTitleHeader extends SliverPersistentHeaderDelegate {
  _LargeTitleHeader({
    required this.title,
    required this.topPadding,
    required this.actions,
    required this.leading,
    required this.colors,
    required this.type,
  });

  final String title;
  final double topPadding;
  final List<Widget> actions;
  final Widget? leading;
  final AppColors colors;
  final AppTypography type;

  /// 标题栏（收起后）高度。
  static const double barHeight = 52;

  /// 大标题区高度。
  static const double largeHeight = 50;

  @override
  double get minExtent => topPadding + barHeight;

  @override
  double get maxExtent => topPadding + barHeight + largeHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final c = colors;
    final t = (shrinkOffset / largeHeight).clamp(0.0, 1.0);
    final collapsed = t >= 1;
    // 内容滚到标题栏下面时才出现背景（iOS 的 scrollEdgeAppearance）。
    final showBar =
        collapsed && (overlapsContent || shrinkOffset > largeHeight);

    // 标题按整屏居中，两侧各留 88pt 给返回按钮和操作按钮。
    final bar = SizedBox(
      height: barHeight,
      child: Stack(
        children: [
          Positioned.fill(
            left: 88,
            right: 88,
            child: Center(
              child: AnimatedOpacity(
                duration: AppMotion.highlight,
                opacity: collapsed ? 1 : 0,
                child: ExcludeSemantics(
                  excluding: !collapsed,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.mobileBodyLarge.copyWith(
                      color: c.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              const SizedBox(width: AppSpacing.x2),
              ?leading,
              const Spacer(),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.x2),
                actions[i],
              ],
              const SizedBox(width: AppSpacing.x4),
            ],
          ),
        ],
      ),
    );

    final content = Stack(
      children: [
        Positioned(left: 0, right: 0, top: topPadding, child: bar),
        Positioned(
          left: AppSpacing.x4,
          right: AppSpacing.x4,
          top: topPadding + barHeight - shrinkOffset.clamp(0, largeHeight),
          height: largeHeight,
          child: Opacity(
            opacity: (1 - t * 1.4).clamp(0.0, 1.0),
            child: Semantics(
              header: true,
              excludeSemantics: collapsed,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.largeTitle.copyWith(color: c.label),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return ClipRect(
      child: BackdropFilter(
        enabled: showBar,
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AnimatedContainer(
          duration: AppMotion.highlight,
          decoration: BoxDecoration(
            color: showBar
                ? c.tabBarBackground
                : c.mobileBackground.withValues(alpha: 0),
            border: Border(
              bottom: BorderSide(
                color: showBar
                    ? c.tabBarBorder
                    : c.tabBarBorder.withValues(alpha: 0),
              ),
            ),
          ),
          child: content,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_LargeTitleHeader old) =>
      old.title != title ||
      old.topPadding != topPadding ||
      old.actions != actions ||
      old.leading != leading ||
      old.colors != colors ||
      old.type != type;
}
