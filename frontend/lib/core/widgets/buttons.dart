import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'app_icon.dart';
import 'pressable.dart';

/// 按钮尺寸，数值取自设计稿：
/// small = 工具栏按钮（28 高）、regular = 详情操作（32 高）、large = 姿态按钮（40 高）。
enum ButtonSize {
  small(height: 28, padding: 12, radius: AppRadius.sm, iconSize: 13),
  regular(height: 32, padding: 14, radius: AppRadius.md, iconSize: 15),
  large(height: 40, padding: 16, radius: AppRadius.lg, iconSize: 17);

  const ButtonSize({
    required this.height,
    required this.padding,
    required this.radius,
    required this.iconSize,
  });

  final double height;
  final double padding;
  final double radius;
  final double iconSize;
}

enum _Variant { primary, secondary, tinted, destructive }

class _AppButton extends StatelessWidget {
  const _AppButton({
    required this.variant,
    required this.label,
    required this.onPressed,
    required this.size,
    this.icon,
    this.trailingIcon,
    this.expand = false,
  });

  final _Variant variant;
  final String label;
  final VoidCallback? onPressed;
  final ButtonSize size;
  final AppIcons? icon;
  final AppIcons? trailingIcon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final (
      Color bg,
      Color fg,
      Color? border,
      FontWeight weight,
    ) = switch (variant) {
      _Variant.primary => (c.accentFill, c.onAccent, null, FontWeight.w500),
      _Variant.secondary => (
        c.isDark ? c.fillSecondary : c.surface,
        c.label,
        c.controlBorder,
        FontWeight.w400,
      ),
      _Variant.tinted => (c.fillSecondary, c.label, null, FontWeight.w400),
      _Variant.destructive => (
        s.critical.bg,
        s.critical.fg,
        null,
        FontWeight.w500,
      ),
    };
    final textStyle = (size == ButtonSize.small ? t.subhead : t.body).copyWith(
      color: fg,
      fontWeight: weight,
    );

    return Pressable(
      onTap: onPressed,
      semanticLabel: label,
      focusRadius: size.radius,
      builder: (context, st) {
        var fill = bg;
        if (st.pressed) {
          fill = Color.lerp(bg, c.stateOverlay, 0.14)!;
        } else if (st.hovered) {
          fill = Color.lerp(bg, c.stateOverlay, 0.06)!;
        }
        return Opacity(
          opacity: st.enabled ? 1 : 0.45,
          child: Container(
            height: size.height,
            padding: EdgeInsets.symmetric(horizontal: size.padding),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(size.radius),
              border: border == null ? null : Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  AppIcon(
                    icon!,
                    size: size.iconSize,
                    color: fg,
                    strokeWidth: 2.2,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: textStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  AppIcon(
                    trailingIcon!,
                    size: 11,
                    color: c.secondaryLabel,
                    strokeWidth: 2.4,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 主按钮：强调色底 + 白字。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.size = ButtonSize.small,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppIcons? icon;
  final ButtonSize size;
  final bool expand;

  @override
  Widget build(BuildContext context) => _AppButton(
    variant: _Variant.primary,
    label: label,
    onPressed: onPressed,
    icon: icon,
    size: size,
    expand: expand,
  );
}

/// 次级按钮：描边（默认）或灰底（[filled]，如「−10 s」「灯光」）。
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
    this.size = ButtonSize.small,
    this.filled = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppIcons? icon;
  final AppIcons? trailingIcon;
  final ButtonSize size;
  final bool filled;
  final bool expand;

  @override
  Widget build(BuildContext context) => _AppButton(
    variant: filled ? _Variant.tinted : _Variant.secondary,
    label: label,
    onPressed: onPressed,
    icon: icon,
    trailingIcon: trailingIcon,
    size: size,
    expand: expand,
  );
}

/// 危险操作：严重色浅底 + 深红字（如「远程趴下」「强制收回」）。
class DestructiveButton extends StatelessWidget {
  const DestructiveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.size = ButtonSize.small,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppIcons? icon;
  final ButtonSize size;
  final bool expand;

  @override
  Widget build(BuildContext context) => _AppButton(
    variant: _Variant.destructive,
    label: label,
    onPressed: onPressed,
    icon: icon,
    size: size,
    expand: expand,
  );
}

/// 急停按钮（Control.dc.html 工具栏右侧）。
///
/// [engaged] 为真时显示「解除急停」灰底；页面负责把空格键绑定到 [onPressed]。
class EmergencyStopButton extends StatelessWidget {
  const EmergencyStopButton({
    super.key,
    required this.engaged,
    required this.onPressed,
    this.label = '急停',
    this.releaseLabel = '解除急停',
    this.compact = false,
  });

  final bool engaged;
  final VoidCallback? onPressed;
  final String label;
  final String releaseLabel;

  /// 紧凑尺寸用于卡片内（32 高）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = engaged ? releaseLabel : label;
    return Pressable(
      onTap: onPressed,
      semanticLabel: text,
      tooltip: engaged ? null : '$label（空格）',
      toggled: engaged,
      focusRadius: AppRadius.lg,
      builder: (context, st) {
        final base = engaged ? c.emergencyReleased : c.emergency;
        final bg = st.pressed
            ? Color.lerp(base, c.pressShade, 0.18)!
            : st.hovered
            ? Color.lerp(base, c.pressShade, 0.08)!
            : base;
        return Container(
          height: compact ? 32 : 36,
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: engaged
                ? null
                : [
                    BoxShadow(
                      color: c.emergency.withValues(alpha: 0.35),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                AppIcons.stop,
                size: compact ? 15 : 17,
                color: c.onAccent,
                strokeWidth: 2,
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                text,
                style: context.type.body.copyWith(
                  color: c.onAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

enum IconButtonStyle {
  /// 透明底，悬停显示灰底（工具栏、侧边栏用户卡）
  plain,

  /// 灰底圆形（移动端导航栏，36×36）
  circle,

  /// 灰底圆角方块
  filled,

  /// 强调色圆形（回放播放/暂停）
  primary,
}

/// 图标按钮。§11 要求必须带 tooltip 与 Semantics，因此 [label] 必填。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.style = IconButtonStyle.plain,
    this.size,
    this.iconSize,
    this.color,
    this.selected = false,
  });

  final AppIcons icon;
  final String label;
  final VoidCallback? onPressed;
  final IconButtonStyle style;
  final double? size;
  final double? iconSize;
  final Color? color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final round =
        style == IconButtonStyle.circle || style == IconButtonStyle.primary;
    final dim = size ?? (round ? 36.0 : 28.0);
    final radius = round ? dim / 2 : AppRadius.xs;
    return Pressable(
      onTap: onPressed,
      semanticLabel: label,
      tooltip: label,
      selected: selected,
      focusRadius: radius,
      builder: (context, st) {
        final rest = switch (style) {
          IconButtonStyle.plain =>
            selected ? c.segmentedTrack : Colors.transparent,
          IconButtonStyle.circle => c.mobileControlFill,
          IconButtonStyle.filled => c.fillSecondary,
          IconButtonStyle.primary => c.accentFill,
        };
        final bg = st.pressed
            ? Color.lerp(
                rest == Colors.transparent ? c.fillSecondary : rest,
                c.label,
                0.1,
              )!
            : st.hovered
            ? (rest == Colors.transparent
                  ? c.fillSecondary
                  : Color.lerp(rest, c.label, 0.05)!)
            : rest;
        return Opacity(
          opacity: st.enabled ? 1 : 0.45,
          child: Container(
            width: dim,
            height: dim,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: AppIcon(
              icon,
              size: iconSize ?? (round ? 18 : 17),
              color:
                  color ??
                  switch (style) {
                    IconButtonStyle.primary => c.onAccent,
                    IconButtonStyle.circle => c.label,
                    _ => c.secondaryLabel,
                  },
            ),
          ),
        );
      },
    );
  }
}
