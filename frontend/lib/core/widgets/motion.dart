import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// 内容出现 / 消失（横幅、提示条）：淡入并从上方 8pt 滑入，占位高度以弹簧展开。
/// 减弱动态效果时只保留淡入淡出（§13）。
class Presence extends StatelessWidget {
  const Presence({super.key, this.child, this.alignment = Alignment.topCenter});

  /// 为 null 时收起。
  final Widget? child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedSize(
      duration: AppMotion.move(context, AppMotion.smooth),
      curve: AppMotion.smooth,
      alignment: alignment,
      child: AnimatedSwitcher(
        duration: AppMotion.highlight * 2,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) {
          final fade = FadeTransition(opacity: animation, child: child);
          if (reduced) return fade;
          return SlideTransition(
            position: Tween(
              begin: const Offset(0, -0.12),
              end: Offset.zero,
            ).animate(animation),
            child: fade,
          );
        },
        layoutBuilder: (current, previous) =>
            Stack(alignment: alignment, children: [...previous, ?current]),
        child:
            child ??
            const SizedBox(
              key: ValueKey('presence-empty'),
              width: double.infinity,
            ),
      ),
    );
  }
}

/// 浮层提示（视频上的急停条）：淡入并从 96% 放大到 100%，与系统提示框的出现方式一致。
class PopIn extends StatelessWidget {
  const PopIn({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedSwitcher(
      duration: AppMotion.highlight * 2,
      switchInCurve: AppMotion.snappy,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        final fade = FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        );
        if (reduced) return fade;
        return ScaleTransition(
          scale: Tween(begin: 0.96, end: 1.0).animate(animation),
          child: fade,
        );
      },
      child: child ?? const SizedBox.shrink(key: ValueKey('popin-empty')),
    );
  }
}
