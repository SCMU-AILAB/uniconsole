import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../app/shell.dart';
import '../../core/layout/app_page.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';

/// 移动端「我的」：个人信息 + 标签栏之外的页面入口（HANDOFF.md §2：移动端没有画的页面
/// 先用桌面布局的单列堆叠版本）。桌面宽度下同样可访问。
class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final me = ref.watch(currentUserProvider).value;
    final summary = ref.watch(fleetSummaryProvider);

    void open(String id) {
      final loc = locationFor(id, ref);
      if (loc != null) context.push(loc, extra: NavIntent.push);
    }

    String? countFor(String id) => switch (id) {
      'fleet' when summary.fleetSessions > 0 => '${summary.fleetSessions}',
      'leases' when summary.pendingLeaseRequests > 0 =>
        '${summary.pendingLeaseRequests} 个申请',
      _ => null,
    };

    return AppPage(
      title: '我的',
      children: [
        if (me != null)
          InsetGroupedSection(
            children: [
              GroupedListRow(
                leading: Avatar(
                  name: me.name,
                  size: 44,
                  color: c.avatarPalette.first,
                ),
                title: me.name,
                titleWeight: FontWeight.w600,
                subtitle: '${me.handle} · ${me.role.label}',
              ),
            ],
          ),
        InsetGroupedSection(
          header: '更多功能',
          dividerIndent: 52,
          children: [
            for (final e in mobileMoreEntries)
              GroupedListRow(
                leading: _IconTile(icon: e.icon),
                title: e.label,
                value: countFor(e.id),
                onTap: () => open(e.id),
              ),
          ],
        ),
        if (showDevEntries)
          InsetGroupedSection(
            header: '开发',
            dividerIndent: 52,
            children: [
              GroupedListRow(
                leading: const _IconTile(icon: AppIcons.devices),
                title: '组件预览',
                onTap: () => open('gallery'),
              ),
            ],
          ),
      ],
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon});

  final AppIcons icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: AppIcon(icon, size: 17, color: c.onAccent),
    );
  }
}
