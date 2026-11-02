import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// 动效规范（HANDOFF.md §13），按 Apple HIG 的动效理念：
///
/// - **有目的**：动画只用来表达状态变化、空间关系和反馈；不做装饰性动画。
///   侧边栏 / 标签栏切换页面是瞬时的，只有层级进入（push）才滑入。
/// - **自然**：位移、缩放一律用弹簧（与 SwiftUI `spring(duration:bounce:)` 同一模型），
///   不用线性或回弹夸张的曲线；颜色、透明度用短促的缓出。
/// - **快速、可打断**：控件反馈 ≤ 0.3s；所有隐式动画都会从当前值重新起步。
/// - **按下即时、松开渐隐**：按下高亮立即出现，松开后 [highlight] 渐隐。
/// - **尊重「减弱动态效果」**：开启时取消位移与缩放（[move] 返回 0），
///   页面进入改为淡入；颜色与透明度的短渐变保留。
abstract final class AppMotion {
  /// 悬停 / 按下高亮松开后的渐隐、细小的颜色变化。
  static const highlight = Duration(milliseconds: 150);
  static const highlightCurve = Curves.easeOut;

  /// 浅色 / 深色切换的整体交叉淡化（与 macOS 切换外观一致）。
  static const appearance = Duration(milliseconds: 300);
  static const appearanceCurve = Curves.easeInOut;

  /// 控件状态：开关圆钮、分段控件滑块、勾选（SwiftUI `.snappy`）。
  static final snappy = SpringCurve(
    duration: const Duration(milliseconds: 300),
    bounce: 0.15,
  );

  /// 内容进出、尺寸变化、进度（SwiftUI `.smooth`，无回弹）。
  static final smooth = SpringCurve(
    duration: const Duration(milliseconds: 400),
  );

  /// 是否开启了系统的「减弱动态效果」。
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// 位移 / 缩放动画时长：减弱动态效果时为 0。
  static Duration move(BuildContext context, SpringCurve spring) =>
      reduced(context) ? Duration.zero : spring.settle;

  /// 颜色 / 透明度动画时长：按下时为 0（即时），松开后渐隐。
  static Duration fade({bool pressed = false}) =>
      pressed ? Duration.zero : highlight;
}

/// 把弹簧模拟包装成 [Curve]，供 AnimatedContainer 等隐式动画使用。
///
/// [duration] 与 [bounce] 的含义与 SwiftUI 相同：duration 是感知时长，
/// bounce 0 为临界阻尼（无回弹），0.15 为轻微回弹。[settle] 是弹簧静止
/// 所需的实际时长，用作动画的 duration，保证曲线在结束时恰好落到 1。
class SpringCurve extends Curve {
  SpringCurve({required Duration duration, double bounce = 0})
    : spring = SpringDescription.withDurationAndBounce(
        duration: duration,
        bounce: bounce,
      ) {
    settle = Duration(microseconds: (_settleSeconds() * 1e6).round());
  }

  final SpringDescription spring;

  /// 弹簧进入 ±0.1% 并保持静止的时间。
  late final Duration settle;

  double get _seconds => settle.inMicroseconds / 1e6;

  double _settleSeconds() {
    final sim = SpringSimulation(
      spring,
      0,
      1,
      0,
      tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
    );
    var t = 0.0;
    while (!sim.isDone(t) && t < 3) {
      t += 1 / 240;
    }
    return t;
  }

  @override
  double transformInternal(double t) =>
      SpringSimulation(spring, 0, 1, 0).x(t * _seconds);
}
