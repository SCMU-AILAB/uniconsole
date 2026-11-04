import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 设置类别（Settings.dc.html CATS）；路由 `/settings/:id`。
enum SettingsCategory {
  look('外观', AppIcons.sun),
  pad('控制与手柄', AppIcons.control),
  keys('键盘快捷键', AppIcons.list),
  net('视频与网络', AppIcons.sensors),
  notify('通知', AppIcons.alerts),
  account('账户与安全', AppIcons.lock);

  const SettingsCategory(this.label, this.icon);

  final String label;
  final AppIcons icon;

  static SettingsCategory? byId(String? id) =>
      values.where((c) => c.name == id).firstOrNull;
}

/// 修改偏好（按账户同步）。
void updatePrefs(WidgetRef ref, Preferences Function(Preferences) change) =>
    ref.read(preferencesRepositoryProvider).update(change);

/// 分节标题（13 semibold，左右 4）。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    // 手机上类别名已经是导航栏标题，不再重复。
    final mobile = LayoutSize.ofContext(context).isMobile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!mobile)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x1,
              0,
              AppSpacing.x1,
              AppSpacing.x2,
            ),
            child: Semantics(
              header: true,
              child: Text(title, style: t.cardTitle.copyWith(color: c.label)),
            ),
          ),
        for (final (i, w) in children.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.x2),
          w,
        ],
      ],
    );
  }
}

/// 设置面板：白底圆角 12、行间分隔线（Settings.dc.html panel）。
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.padding});

  final List<Widget> children;

  /// 默认左右 16；外观缩略图面板四周 16。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.tile),
        border: Border.all(color: c.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, w) in children.indexed) ...[
            if (i > 0) Container(height: 1, color: c.separator),
            w,
          ],
        ],
      ),
    );
  }
}

/// 一行：左侧标题（可带说明），右侧控件或灰字值。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.subtitle,
    this.value,
    this.trailing,
    this.leading,
    this.dense = false,
  });

  final String label;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final Widget? leading;

  /// 手柄 / 快捷键列表行（上下 10）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: dense ? AppSpacing.x2 + AppSpacing.half : AppSpacing.x3,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppSpacing.x3),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.body.copyWith(color: c.label)),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.half),
                  Text(
                    subtitle!,
                    style: t.footnote.copyWith(color: c.secondaryLabel),
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: AppSpacing.x3),
            Flexible(
              child: Text(
                value!,
                textAlign: TextAlign.end,
                style: t.body.copyWith(color: c.secondaryLabel),
              ),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.x3),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 灰字值 + ⌄：点开菜单选择（视频与网络、通知等）。
class ChoiceValue<T> extends StatelessWidget {
  const ChoiceValue({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
  });

  final String label;
  final T value;
  final List<MenuOption<T>> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final current = options.where((o) => o.value == value).firstOrNull?.label;
    return AppMenu<T>(
      options: options,
      selected: value,
      onSelected: onSelected,
      anchor: (context, toggle) => Pressable(
        onTap: toggle,
        semanticLabel: '$label：$current',
        focusRadius: AppRadius.xs,
        builder: (context, st) => Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x1,
            vertical: AppSpacing.half,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  current ?? '—',
                  textAlign: TextAlign.end,
                  style: t.body.copyWith(
                    color: st.pressed ? c.label : c.secondaryLabel,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x1),
              AppIcon(AppIcons.chevronDown, size: 13, color: c.secondaryLabel),
            ],
          ),
        ),
      ),
    );
  }
}

/// 按键帽（手柄按键 / 键盘快捷键）。
class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key, this.minWidth = 40, this.mono = true});

  final String label;
  final double minWidth;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Container(
      constraints: BoxConstraints(minWidth: minWidth, minHeight: 26),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x2 + AppSpacing.half,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.segmentedTrack,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: mono ? Border.all(color: c.separator) : null,
      ),
      child: Text(
        label,
        style: mono
            ? t.monoLarge.copyWith(color: c.label)
            : t.subheadStrong.copyWith(color: c.label),
      ),
    );
  }
}

bool get _apple =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// 键盘快捷键（Settings.dc.html KEYS）。与 shell / 操控页的绑定一致；
/// Windows / Linux 上 ⌘ 显示为 Ctrl。
List<(String, String)> keyboardShortcuts() {
  final cmd = _apple ? '⌘' : 'Ctrl';
  final shift = _apple ? '⇧' : 'Shift';
  return [
    ('移动', 'W A S D'),
    ('转向', 'Q E'),
    ('急停（当前设备）', 'Space'),
    ('全局急停', '$cmd $shift E'),
    ('姿态动作 1–6', '1 … 6'),
    ('切换摄像头', 'C'),
    ('命令面板', '$cmd K'),
    ('呼出智能体', '$cmd J'),
    ('设置', '$cmd ,'),
  ];
}

/// 可重新绑定的手柄按键。
const gamepadControls = [
  'A',
  'B',
  'X',
  'Y',
  'LB',
  'RB',
  'LT',
  'RT',
  '左摇杆',
  '右摇杆',
  '十字键 ↑ ↓',
  '十字键 ← →',
  '菜单键',
  '视图键',
  'LB + RB 同时按',
];
