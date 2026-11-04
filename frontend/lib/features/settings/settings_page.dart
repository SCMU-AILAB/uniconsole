import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import 'settings_sections.dart';
import 'settings_widgets.dart';

/// 设置（Settings.dc.html）：外观、控制与手柄、键盘快捷键、视频与网络、通知、账户与安全。
///
/// 桌面左侧为类别、右侧为内容，类别写在地址里（`/settings/pad`）；
/// 手机上 `/settings` 是类别列表，点进 `/settings/:id`（iOS 设置的层级方式）。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key, this.category});

  /// 地址里的类别；为空时桌面显示「外观」，手机显示类别列表。
  final String? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mobile = LayoutSize.ofContext(context).isMobile;
    final cat = SettingsCategory.byId(category);
    if (mobile) return cat == null ? const _MobileIndex() : _MobileDetail(cat);

    final selected = cat ?? SettingsCategory.look;
    return AppPage(
      title: '设置',
      subtitle: '偏好设置按账户同步到所有设备',
      children: [
        FlexColumns(
          leadingWidth: 220,
          mainMin: 520,
          gap: AppSpacing.x5,
          leading: _CategoryTabs(selected: selected),
          main: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: settingsContent(selected),
            ),
          ),
        ),
      ],
    );
  }
}

/// 桌面类别列表（竖向标签，选中为强调色实底）。
class _CategoryTabs extends StatelessWidget {
  const _CategoryTabs({required this.selected});

  final SettingsCategory selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Semantics(
      container: true,
      label: '设置类别',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final cat in SettingsCategory.values) ...[
            Pressable(
              onTap: () => context.go('${Routes.settings}/${cat.name}'),
              selected: cat == selected,
              semanticLabel: cat.label,
              focusRadius: AppRadius.md,
              builder: (context, st) {
                final on = cat == selected;
                return Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3,
                  ),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: on
                        ? c.accentFill
                        : st.pressed
                        ? c.sidebarSelected
                        : null,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Text(
                    cat.label,
                    style: t.body.copyWith(
                      color: on ? c.onAccent : c.label,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.half),
          ],
        ],
      ),
    );
  }
}

class _MobileIndex extends ConsumerWidget {
  const _MobileIndex();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final mode = ref.watch(themeModeProvider);
    final prefs = ref.watch(preferencesProvider);
    final pad = ref.watch(gamepadProvider).value;
    String? value(SettingsCategory cat) => switch (cat) {
      SettingsCategory.look => switch (mode) {
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
        ThemeMode.system => '跟随系统',
      },
      SettingsCategory.pad => pad == null ? '未连接' : '已连接',
      SettingsCategory.net => prefs.videoQuality.label.split(' ').first,
      SettingsCategory.account => prefs.twoFactor ? '二次验证已开启' : null,
      _ => null,
    };
    return AppPage(
      title: '设置',
      subtitle: '偏好设置按账户同步到所有设备',
      children: [
        InsetGroupedSection(
          dividerIndent: 52,
          children: [
            for (final cat in SettingsCategory.values)
              GroupedListRow(
                leading: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: AppIcon(cat.icon, size: 17, color: c.onAccent),
                ),
                title: cat.label,
                value: value(cat),
                onTap: () => context.push(
                  '${Routes.settings}/${cat.name}',
                  extra: NavIntent.push,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _MobileDetail extends StatelessWidget {
  const _MobileDetail(this.category);

  final SettingsCategory category;

  @override
  Widget build(BuildContext context) => AppPage(
    title: category.label,
    largeTitle: false,
    backLabel: '设置',
    children: [settingsContent(category)],
  );
}
