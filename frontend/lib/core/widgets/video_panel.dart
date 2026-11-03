import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'motion.dart';
import 'pressable.dart';

/// 视频面板（Control.dc.html）：深色底 + 十字准星 + 四角 HUD 插槽。
///
/// 真实画面接 WebRTC 后放进 [video]；目前显示占位文字。
class VideoPanel extends StatelessWidget {
  const VideoPanel({
    super.key,
    this.video,
    this.placeholder = '[视频流 · WebRTC]',
    this.topLeft,
    this.topRight,
    this.bottomLeft,
    this.bottomRight,
    this.overlay,
    this.showCrosshair = true,
    this.hideBottomRightWhenNarrow = true,
    this.aspectRatio = 16 / 9,
    this.semanticLabel = '实时视频',
  });

  final Widget? video;
  final String placeholder;
  final Widget? topLeft;
  final Widget? topRight;
  final Widget? bottomLeft;
  final Widget? bottomRight;

  /// 顶部居中的提示（急停横幅）。
  final Widget? overlay;
  final bool showCrosshair;

  /// 窄于 420 时隐藏右下角（默认用于雷达小窗）；移动端的「横屏操控」按钮需要保留。
  final bool hideBottomRightWhenNarrow;
  final double aspectRatio;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: ColoredBox(
            color: c.videoBackground,
            child: LayoutBuilder(
              builder: (context, box) {
                final narrow = box.maxWidth < 420;
                final inset = narrow ? AppSpacing.x2 : AppSpacing.x4;
                return Stack(
                  children: [
                    if (video != null)
                      Positioned.fill(child: video!)
                    else
                      Align(
                        alignment: const Alignment(0, 0.25),
                        child: Text(
                          placeholder,
                          style: context.type.subhead.copyWith(
                            color: c.hudSecondary,
                          ),
                        ),
                      ),
                    if (showCrosshair) const Center(child: _Crosshair()),
                    if (topLeft != null)
                      Positioned(left: inset, top: inset, child: topLeft!),
                    if (topRight != null)
                      Positioned(right: inset, top: inset, child: topRight!),
                    if (bottomLeft != null)
                      Positioned(
                        left: inset,
                        bottom: inset,
                        right: box.maxWidth / 2,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: bottomLeft!,
                        ),
                      ),
                    if (bottomRight != null &&
                        !(narrow && hideBottomRightWhenNarrow))
                      Positioned(
                        right: inset,
                        bottom: inset,
                        child: bottomRight!,
                      ),
                    Positioned(
                      left: inset,
                      right: inset,
                      top: narrow ? 48 : 60,
                      child: Center(child: PopIn(child: overlay)),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ExcludeSemantics(
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.hudText.withValues(alpha: 0.55)),
              ),
            ),
            Container(
              width: 1,
              height: 18,
              color: c.hudText.withValues(alpha: 0.7),
            ),
            Container(
              width: 18,
              height: 1,
              color: c.hudText.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

/// HUD 半透明浮层容器（rgba(30,30,32,.72)、圆角 9–10）。
class HudPanel extends StatelessWidget {
  const HudPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.x1),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: context.colors.hudOverlay,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: DefaultTextStyle.merge(
        style: context.type.subhead.copyWith(color: context.colors.hudText),
        child: child,
      ),
    );
  }
}

/// LIVE 红点 + 参数（如「1280×720 · 30 fps · 端到端 48 ms」）。
class LiveIndicator extends StatelessWidget {
  const LiveIndicator({super.key, this.detail});

  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return HudPanel(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
      child: SizedBox(
        height: 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: c.live, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.x1),
            Text('LIVE', style: t.subhead.copyWith(color: c.hudText)),
            if (detail != null) ...[
              const SizedBox(width: AppSpacing.x3),
              Flexible(
                child: Text(
                  detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.subhead.copyWith(color: c.hudTertiary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class HudMetric {
  const HudMetric(this.label, this.value);

  final String label;
  final String value;
}

/// HUD 数值组（左下角速度、步态）。
class HudMetrics extends StatelessWidget {
  const HudMetrics({super.key, required this.metrics});

  final List<HudMetric> metrics;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return HudPanel(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x4,
        vertical: AppSpacing.x3,
      ),
      child: Wrap(
        spacing: AppSpacing.x4,
        runSpacing: AppSpacing.x2,
        children: [
          for (final m in metrics)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(m.label, style: t.caption.copyWith(color: c.hudSecondary)),
                const SizedBox(height: AppSpacing.half),
                Text(m.value, style: t.metric.copyWith(color: c.hudText)),
              ],
            ),
        ],
      ),
    );
  }
}

/// HUD 内的分段按钮（摄像头切换）。
class HudSegmented<T> extends StatelessWidget {
  const HudSegmented({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: HudPanel(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.x1),
              Pressable(
                onTap: () => onChanged(options[i].$1),
                selected: options[i].$1 == value,
                semanticLabel: options[i].$2,
                focusRadius: AppRadius.xs,
                builder: (context, st) => AnimatedContainer(
                  duration: AppMotion.fade(pressed: st.pressed),
                  curve: AppMotion.highlightCurve,
                  height: 26,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: options[i].$1 == value
                        ? c.hudSelected
                        : st.pressed
                        ? c.hudBorder
                        : c.hudBorder.withValues(alpha: 0),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    options[i].$2,
                    style: context.type.subhead.copyWith(color: c.hudText),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
