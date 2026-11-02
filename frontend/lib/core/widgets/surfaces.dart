import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'app_icon.dart';
import 'pressable.dart';

/// 桌面卡片：白底、1px 描边、圆角 14、内边距 14/16。
///
/// 传入 [onTap] 即成为可选中卡片（选中时强调色描边 + 外圈）。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: AppSpacing.card,
    ),
    this.gap = AppSpacing.lg,
    this.radius = AppRadius.card,
    this.onTap,
    this.selected = false,
    this.semanticLabel,
  });

  final Widget child;

  /// 卡片标题（13 semibold）。
  final String? title;

  /// 标题行右侧（单位、「全部」链接等）。
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final double gap;
  final double radius;
  final VoidCallback? onTap;
  final bool selected;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget body = child;
    if (title != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title!,
                    style: context.type.cardTitle.copyWith(color: c.label),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          SizedBox(height: gap),
          child,
        ],
      );
    }
    Widget frame(bool hovered) => AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: padding,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: selected ? c.accent : c.separator),
        boxShadow: [
          if (selected) BoxShadow(color: c.accentRing, spreadRadius: 3),
          if (hovered && !selected)
            BoxShadow(
              color: c.shadow,
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      child: body,
    );
    if (onTap == null) return frame(false);
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: semanticLabel,
      focusRadius: radius,
      builder: (context, st) => frame(st.hovered),
    );
  }
}

/// 统计卡：标签 / 大数字 / 说明（Main.dc.html 顶部四格）。
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.tone,
    this.unit,
    this.large = false,
  });

  final String label;
  final String value;
  final String? caption;

  /// 数字着色（在线=online、告警=warning、会话=busy），为空用主文字色。
  final StatusTone? tone;
  final String? unit;

  /// 30 号数字（电源卡）。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Semantics(
      container: true,
      label: '$label $value${unit ?? ''}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: AppSpacing.card,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.tile),
          border: Border.all(color: c.separator),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: t.subhead.copyWith(color: c.secondaryLabel)),
            const SizedBox(height: AppSpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: (large ? t.statLarge : t.stat).copyWith(
                    color: tone == null ? c.label : context.status.of(tone!).fg,
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    unit!,
                    style: t.metric.copyWith(
                      color: c.secondaryLabel,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
            if (caption != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                caption!,
                style: t.subhead.copyWith(color: c.secondaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 小型数值格（IMU 三格：灰底圆角 9）。
class MetricCell extends StatelessWidget {
  const MetricCell({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.windowBackground,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.type.caption.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(value, style: context.type.metric.copyWith(color: c.label)),
        ],
      ),
    );
  }
}

/// 头像：首字母 + 背景色。颜色默认按名字稳定取自 avatarPalette。
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 28, this.color});

  final String name;
  final double size;
  final Color? color;

  static Color colorFor(String name, List<Color> palette) {
    var h = 0;
    for (final r in name.runes) {
      h = (h * 31 + r) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final initial = name.isEmpty || name == '—'
        ? '—'
        : String.fromCharCode(name.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: name == '—'
              ? c.decorativeGray
              : (color ?? colorFor(name, c.avatarPalette)),
          shape: BoxShape.circle,
        ),
        child: Text(
          initial,
          style: context.type.body.copyWith(
            color: c.onAccent,
            fontWeight: FontWeight.w600,
            fontSize: (size * 0.43).roundToDouble(),
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// 电量/进度条（5–6px 高，按阈值着色：≤20 严重、≤40 警告，其余在线）。
class ProgressBar extends StatelessWidget {
  const ProgressBar({
    super.key,
    required this.value,
    this.height = 5,
    this.color,
    this.semanticLabel,
    this.battery = true,
  });

  /// 0–1。
  final double value;
  final double height;
  final Color? color;
  final String? semanticLabel;

  /// 按电量阈值自动着色；false 时用强调色。
  final bool battery;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final v = value.clamp(0.0, 1.0);
    final fill =
        color ??
        (!battery
            ? c.accent
            : v <= 0.2
            ? s.critical.dot
            : v <= 0.4
            ? s.warning.dot
            : s.online.dot);
    return Semantics(
      label: semanticLabel,
      value: '${(v * 100).round()}%',
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: c.separator,
          borderRadius: BorderRadius.circular(height / 2),
        ),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: v,
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        ),
      ),
    );
  }
}

enum BannerKind { emergency, success, info, warning }

/// 横幅提示。emergency 为急停后的红色提示条（白字、实底），其余为浅底彩字。
class AppBanner extends StatelessWidget {
  const AppBanner({
    super.key,
    required this.kind,
    required this.message,
    this.action,
  });

  final BannerKind kind;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final (Color bg, Color fg, AppIcons icon) = switch (kind) {
      BannerKind.emergency => (c.emergency, c.onAccent, AppIcons.stopAlert),
      BannerKind.success => (s.online.bg, s.online.fg, AppIcons.check),
      BannerKind.info => (s.busy.bg, s.busy.fg, AppIcons.info),
      BannerKind.warning => (s.warning.bg, s.warning.fg, AppIcons.warning),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: AppSpacing.lg,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadius.group),
        ),
        child: Row(
          children: [
            AppIcon(icon, size: 17, color: fg, strokeWidth: 2),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                message,
                style: context.type.body.copyWith(
                  color: fg,
                  fontWeight: kind == BannerKind.emergency
                      ? FontWeight.w600
                      : FontWeight.w500,
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: AppSpacing.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 空状态：图标 + 标题 + 说明 + 可选操作。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = AppIcons.search,
    this.action,
  });

  final String title;
  final String? message;
  final AppIcons icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.fillSecondary,
              borderRadius: BorderRadius.circular(AppRadius.tile),
            ),
            child: AppIcon(icon, size: 24, color: c.decorativeGray),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            title,
            style: context.type.cardTitle.copyWith(color: c.label),
            textAlign: TextAlign.center,
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              message!,
              style: context.type.subhead.copyWith(color: c.secondaryLabel),
              textAlign: TextAlign.center,
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: AppSpacing.xl),
            action!,
          ],
        ],
      ),
    );
  }
}
