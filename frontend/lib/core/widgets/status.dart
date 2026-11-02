import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'pressable.dart';

/// 状态圆点（默认 6px；设备列表角标用 [ring] 加一圈底色描边）。
class StatusDot extends StatelessWidget {
  const StatusDot(this.tone, {super.key, this.size = 6, this.ring, this.color});

  final StatusTone tone;
  final double size;

  /// 外圈描边颜色（MobileFleet 设备图标右下角的状态点）。
  final Color? ring;

  /// 覆盖颜色（设备分组色点等非状态用途）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fill = color ?? context.status.of(tone).dot;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: ring == null
              ? null
              : Border.all(
                  color: ring!,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                ),
        ),
      ),
    );
  }
}

/// 状态胶囊：圆点 + 文字，22 高、圆角 11（Main.dc.html 设备卡右上角）。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.tone,
    required this.label,
    this.onSurface = false,
    this.large = false,
  });

  final StatusTone tone;
  final String label;

  /// 白底版本（叠在图片/灰底上，如检查器头图左上角）。
  final bool onSurface;

  /// 26 高、字号 12（Control.dc.html「你持有控制权」）。
  final bool large;

  @override
  Widget build(BuildContext context) {
    final sw = context.status.of(tone);
    final t = context.type;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        height: large ? 26 : 22,
        padding: EdgeInsets.symmetric(horizontal: large ? 10 : 8),
        decoration: BoxDecoration(
          color: onSurface ? context.colors.surface : sw.bg,
          borderRadius: BorderRadius.circular(large ? 13 : 11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(tone),
            const SizedBox(width: 5),
            Text(
              label,
              style: (large ? t.subheadMedium : t.footnoteMedium).copyWith(
                color: sw.fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小标签：方角胶囊（告警级别「严重」、角色「Owner」、录制标签）。
class Tag extends StatelessWidget {
  const Tag({
    super.key,
    required this.label,
    this.tone,
    this.strong = false,
    this.large = false,
  });

  final String label;

  /// 为空时使用中性灰（separatorSubtle 底 + tertiaryLabel 字）。
  final StatusTone? tone;
  final bool strong;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sw = tone == null ? null : context.status.of(tone!);
    final t = context.type;
    final style = (large ? t.footnote : t.caption).copyWith(
      color: sw?.fg ?? c.tertiaryLabel,
      fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: large ? 8 : 6,
        vertical: large ? 2 : 1,
      ),
      decoration: BoxDecoration(
        color: sw?.bg ?? c.separatorSubtle,
        borderRadius: BorderRadius.circular(large ? AppRadius.tag : 4),
      ),
      child: Text(label, style: style),
    );
  }
}

/// 可切换的筛选/辅助芯片（Control.dc.html「避障 开 / 灯光 / 语音」）。
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.selectedTone = StatusTone.online,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final StatusTone selectedTone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sw = context.status.of(selectedTone);
    return Pressable(
      onTap: onChanged == null ? null : () => onChanged!(!selected),
      semanticLabel: label,
      toggled: selected,
      builder: (context, st) => Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        decoration: BoxDecoration(
          color: selected
              ? sw.bg
              : st.hovered
              ? Color.lerp(c.fillSecondary, c.label, 0.05)
              : c.fillSecondary,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: context.type.subhead.copyWith(
                color: selected ? sw.fg : c.label,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 数字徽标（侧边栏告警计数、标签栏角标）。
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key, this.small = false});

  final int count;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = small ? 16.0 : 18.0;
    // 不设 alignment，避免在宽松约束下撑满父级宽度。
    return Container(
      constraints: BoxConstraints(minWidth: d),
      height: d,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: c.badge,
        borderRadius: BorderRadius.circular(d / 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '$count',
            style: (small ? context.type.tabLabel : context.type.caption)
                .copyWith(
                  color: c.onAccent,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
          ),
        ],
      ),
    );
  }
}
