import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';

/// 设置（Settings.dc.html）。第 2 阶段先实现「外观」：浅色 / 深色 / 跟随系统、强调色。
/// 其余类别（手柄、快捷键、视频与网络、通知、账户）在第 6 阶段实现。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final mode = ref.watch(themeModeProvider);
    final accent = ref.watch(accentProvider);
    final mobile = LayoutSize.of(MediaQuery.sizeOf(context).width).isMobile;

    final appearance = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.x2),
          child: Semantics(
            header: true,
            child: Text('外观', style: t.cardTitle.copyWith(color: c.label)),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(AppSpacing.x4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(color: c.separator),
          ),
          child: Wrap(
            spacing: AppSpacing.x4,
            runSpacing: AppSpacing.x4,
            alignment: WrapAlignment.spaceEvenly,
            children: [
              for (final (m, label) in const [
                (ThemeMode.light, '浅色'),
                (ThemeMode.dark, '深色'),
                (ThemeMode.system, '跟随系统'),
              ])
                _ThemeCard(
                  mode: m,
                  label: label,
                  selected: mode == m,
                  onTap: () => ref.read(themeModeProvider.notifier).set(m),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(color: c.separator),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.x3),
                child: Wrap(
                  spacing: AppSpacing.x3,
                  runSpacing: AppSpacing.x2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    Text('强调色', style: t.body.copyWith(color: c.label)),
                    Semantics(
                      container: true,
                      label: '强调色',
                      child: Wrap(
                        spacing: AppSpacing.x3,
                        children: [
                          for (final sw in AccentSwatch.values)
                            _Swatch(
                              swatch: sw,
                              selected: sw == accent,
                              onTap: () =>
                                  ref.read(accentProvider.notifier).set(sw),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: c.separator),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.x3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '按钮预览（白字底色会自动加深，保证对比度 ≥ 4.5:1）',
                        style: t.footnote.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    PrimaryButton(label: '确认处理', onPressed: () {}),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return AppPage(
      title: '设置',
      subtitle: mobile ? null : '偏好设置按账户同步到所有设备',
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: appearance,
        ),
        Text(
          '控制与手柄、键盘快捷键、视频与网络、通知、账户与安全将在第 6 阶段实现。',
          style: t.footnote.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }
}

/// 外观缩略图（Settings.dc.html themes）：侧边栏 + 四张卡片的迷你窗口。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // 缩略图展示的是对应模式本身的颜色，而不是当前主题。
    final light = AppColors.light, dark = AppColors.dark;
    final (win, side, card, line) = switch (mode) {
      ThemeMode.light => (
        light.surface,
        light.sidebarBackground,
        light.separator,
        light.controlBorder,
      ),
      ThemeMode.dark => (
        dark.windowBackground,
        dark.surface,
        dark.separator,
        dark.controlBorder,
      ),
      ThemeMode.system => (
        dark.windowBackground,
        light.sidebarBackground,
        dark.separator,
        light.controlBorder,
      ),
    };
    Widget bar(Color color) => Container(
      height: 5,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      focusRadius: AppRadius.group,
      builder: (context, st) => SizedBox(
        width: 150,
        child: Column(
          children: [
            Container(
              height: 96,
              decoration: BoxDecoration(
                color: win,
                borderRadius: BorderRadius.circular(AppRadius.group),
                boxShadow: [
                  BoxShadow(
                    color: selected ? c.accent : c.separator,
                    spreadRadius: selected ? 3 : 1,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 48,
                    color: side,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x2,
                      vertical: AppSpacing.x3,
                    ),
                    child: Column(
                      children: [
                        bar(c.accent),
                        const SizedBox(height: AppSpacing.x1),
                        bar(line),
                        const SizedBox(height: AppSpacing.x1),
                        bar(line),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.x2,
                        vertical: AppSpacing.x3,
                      ),
                      child: GridView.count(
                        crossAxisCount: 2,
                        mainAxisSpacing: AppSpacing.x1,
                        crossAxisSpacing: AppSpacing.x1,
                        childAspectRatio: 1.25,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (var i = 0; i < 4; i++)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: card,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              label,
              style: context.type.body.copyWith(
                color: c.label,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.swatch,
    required this.selected,
    required this.onTap,
  });

  final AccentSwatch swatch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = swatch.forBrightness(c.brightness);
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: swatch.label,
      tooltip: swatch.label,
      focusRadius: 11,
      builder: (context, st) => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: selected
              ? [
                  BoxShadow(color: c.surface, spreadRadius: 2),
                  BoxShadow(color: color, spreadRadius: 4),
                ]
              : null,
        ),
      ),
    );
  }
}
