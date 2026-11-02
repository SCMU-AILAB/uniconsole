import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';

/// 设备总览（Main.dc.html）。第 2 阶段：统计卡已接数据层，卡片网格与检查器在第 3 阶段实现。
class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key, this.groupId});

  /// 侧边栏「设备分组」筛选。
  final String? groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = ref.watch(fleetSummaryProvider);
    final groups = ref.watch(deviceGroupsProvider).value ?? const [];
    final group = groups.where((g) => g.id == groupId).firstOrNull;
    final subtitle = group == null
        ? '${s.total} 台设备 · ${s.online} 台在线 · ${s.openAlerts} 条未处理告警'
        : '分组「${group.name}」· ${s.groupCounts[group.id] ?? 0} 台设备';

    return AppPage(
      title: '设备总览',
      mobileTitle: '设备',
      subtitle: subtitle,
      actions: [
        PrimaryButton(label: '添加设备', icon: AppIcons.plus, onPressed: () {}),
      ],
      mobileActions: [
        AppIconButton(
          icon: AppIcons.filter,
          label: '筛选',
          style: IconButtonStyle.circle,
          onPressed: () {},
        ),
        AppIconButton(
          icon: AppIcons.plus,
          label: '添加设备',
          style: IconButtonStyle.circle,
          onPressed: () {},
        ),
      ],
      inspectorLabel: '设备详情',
      inspector: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 150,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.fillSecondary,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Text(
              '设备详情检查器 · 第 3 阶段',
              style: context.type.cardTitle.copyWith(color: c.secondaryLabel),
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          Text(
            '右栏：≥ 1280 显示在右侧，900–1280 及以下堆到内容下方。',
            style: context.type.footnote.copyWith(color: c.secondaryLabel),
          ),
        ],
      ),
      children: [
        // 四个统计数字与侧边栏计数来自同一个 fleetSummaryProvider（§8.5）。
        _StatGrid(
          tiles: [
            StatTile(
              label: '设备总数',
              value: '${s.total}',
              caption: '${s.groupCounts.length} 个分组',
            ),
            StatTile(
              label: '在线',
              value: '${s.online}',
              caption: '${s.offline} 台离线',
              tone: StatusTone.online,
            ),
            StatTile(
              label: '告警',
              value: '${s.activeAlerts}',
              caption: '${s.openAlerts} 条未处理',
              tone: StatusTone.warning,
            ),
            StatTile(
              label: '控制会话',
              value: '${s.controlSessions}',
              caption: '含 ${s.fleetSessions} 个联调会话',
              tone: StatusTone.busy,
            ),
          ],
        ),
        const AppCard(
          child: EmptyState(
            icon: AppIcons.devices,
            title: '设备卡片网格将在第 3 阶段实现',
            message: '设计稿：Main.dc.html（桌面）· MobileFleet.dc.html（移动）',
          ),
        ),
      ],
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        const gap = AppSpacing.x3;
        final cols = ((box.maxWidth + gap) / (170 + gap)).floor().clamp(1, 4);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }
}
