import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../alerts/alert_widgets.dart' show watchNowOf;
import '../devices/device_widgets.dart';
import 'member_dialog.dart';
import 'member_widgets.dart';

/// 成员与权限（Roles.dc.html）：成员表、角色权限矩阵、审计日志。
class MembersPage extends ConsumerWidget {
  const MembersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider).value ?? const <Member>[];
    final me = ref.watch(currentUserProvider).value;
    final ui = ref.watch(membersUiProvider);
    final mobile = LayoutSize.ofContext(context).isMobile;
    final admin = me?.role == MemberRole.admin;

    final filter = SegmentedControl<MemberRole?>(
      semanticLabel: '按角色筛选',
      expand: mobile,
      size: mobile ? SegmentedSize.mobile : SegmentedSize.small,
      options: [
        const SegmentOption(null, '全部'),
        for (final r in MemberRole.values) SegmentOption(r, r.shortLabel),
      ],
      value: ui.filter,
      onChanged: ref.read(membersUiProvider.notifier).filter,
    );

    void invite() => showMemberDialog(context, ref);

    final notice = Presence(
      child: ui.notice == null
          ? null
          : Padding(
              key: ValueKey(ui.notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
            ),
    );

    return AppPage(
      title: '成员与权限',
      mobileTitle: '成员',
      subtitle:
          '${members.length} 名成员 · ${MemberRole.values.length} 种角色 · 审计日志保留 180 天',
      actions: [
        filter,
        PrimaryButton(label: '邀请成员', onPressed: admin ? invite : null),
      ],
      mobileActions: [
        AppIconButton(
          icon: AppIcons.plus,
          label: '邀请成员',
          style: IconButtonStyle.circle,
          onPressed: admin ? invite : null,
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            notice,
            if (mobile) ...[
              filter,
              const SizedBox(height: AppSpacing.x4),
              const _MobileMembers(),
              const SizedBox(height: AppSpacing.x4),
              const PermissionMatrixCard(),
              const SizedBox(height: AppSpacing.x4),
              const AuditLogCard(),
            ] else
              const FlexColumns(
                mainMin: 560,
                trailingWidth: 340,
                main: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MembersTableCard(),
                    SizedBox(height: AppSpacing.x4),
                    PermissionMatrixCard(),
                  ],
                ),
                trailing: AuditLogCard(),
              ),
          ],
        ),
      ],
    );
  }
}

/// 当前筛选下的成员。
List<Member> filteredMembers(WidgetRef ref) {
  final members = ref.watch(membersProvider).value ?? const <Member>[];
  final f = ref.watch(membersUiProvider).filter;
  return [
    for (final m in members)
      if (f == null || m.role == f) m,
  ];
}

String memberAccess(WidgetRef ref, Member m) => accessText(
  m,
  ref.watch(memberDevicesProvider(m.id)),
  ref.watch(deviceGroupsProvider).value ?? const [],
  ref.watch(devicesProvider).value ?? const [],
);

class MembersTableCard extends ConsumerWidget {
  const MembersTableCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final now = watchNowOf(ref);
    final rows = filteredMembers(ref);
    final admin =
        ref.watch(currentUserProvider).value?.role == MemberRole.admin;

    return AppCard(
      semanticLabel: '成员',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x2,
        vertical: AppSpacing.x1,
      ),
      child: AppDataTable(
        minWidth: 620,
        columns: const [
          AppDataColumn('成员', flex: 1.5),
          AppDataColumn('角色', flex: 1),
          AppDataColumn('可访问设备', flex: 1.6),
          AppDataColumn('有效期', flex: 1),
          AppDataColumn('', width: 60),
        ],
        rows: [
          for (final m in rows)
            AppDataRow(
              semanticLabel: '${m.name}，${m.role.label}',
              cells: [
                Row(
                  children: [
                    MemberAvatar(m.id, size: 30),
                    const SizedBox(width: AppSpacing.x3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.cardTitle.copyWith(color: c.label),
                          ),
                          Text(
                            '${m.handle} · ${lastSeenText(m, now)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.caption.copyWith(color: c.secondaryLabel),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Align(alignment: Alignment.centerLeft, child: RoleTag(m.role)),
                Text(
                  memberAccess(ref, m),
                  style: t.subhead.copyWith(color: c.tertiaryLabel),
                ),
                Text(
                  expiryText(m.expiresAt, now),
                  style: t.subhead.copyWith(
                    color: m.expired(now)
                        ? context.status.critical.fg
                        : c.secondaryLabel,
                  ),
                ),
                SecondaryButton(
                  label: '编辑',
                  expand: true,
                  onPressed: admin
                      ? () => showMemberDialog(context, ref, member: m)
                      : null,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _MobileMembers extends ConsumerWidget {
  const _MobileMembers();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = watchNowOf(ref);
    final admin =
        ref.watch(currentUserProvider).value?.role == MemberRole.admin;
    final rows = filteredMembers(ref);
    if (rows.isEmpty) {
      return const EmptyState(title: '没有该角色的成员', icon: AppIcons.members);
    }
    return InsetGroupedSection(
      dividerIndent: 60,
      children: [
        for (final m in rows)
          GroupedListRow(
            leading: MemberAvatar(m.id, size: 36),
            title: m.name,
            titleWeight: FontWeight.w600,
            titleTrailing: RoleTag(m.role),
            subtitle: '${m.handle} · ${lastSeenText(m, now)}',
            detail: '${memberAccess(ref, m)} · ${expiryText(m.expiresAt, now)}',
            onTap: admin
                ? () => showMemberDialog(context, ref, member: m)
                : null,
          ),
      ],
    );
  }
}

/// 角色权限矩阵（Roles.dc.html matrix）：筛选的角色列高亮。
class PermissionMatrixCard extends ConsumerWidget {
  const PermissionMatrixCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final filter = ref.watch(membersUiProvider).filter;

    Widget cell(Widget child, {required MemberRole role}) => Expanded(
      child: Container(
        margin: const EdgeInsets.only(left: AppSpacing.x1),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.half),
        decoration: BoxDecoration(
          color: role == filter ? c.windowBackground : null,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );

    final header = Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 18,
            child: Text(
              '权限',
              style: t.footnote.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final r in MemberRole.values)
            Expanded(
              flex: 10,
              child: Container(
                margin: const EdgeInsets.only(left: AppSpacing.x1),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.half),
                decoration: BoxDecoration(
                  color: r == filter ? context.status.of(roleTone(r)).bg : null,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                alignment: Alignment.center,
                child: Text(
                  r.label,
                  style: t.footnote.copyWith(
                    fontWeight: FontWeight.w600,
                    color: r == filter
                        ? context.status.of(roleTone(r)).fg
                        : c.label,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    Color symbolColor(Access a) => switch (a) {
      Access.all => c.accent,
      // 设计稿「—」为 #AEAEB2，对比度不足 4.5:1，与 ◐ 同用次要文字色，靠字形区分。
      Access.own || Access.none => c.secondaryLabel,
    };

    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        for (final p in RolePermission.matrix)
          Container(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.separatorSubtle)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 18,
                  child: Text(p.name, style: t.body.copyWith(color: c.label)),
                ),
                for (final r in MemberRole.values)
                  Expanded(
                    flex: 10,
                    child: Semantics(
                      label: '${p.name}，${r.label}：${p.of(r).label}',
                      excludeSemantics: true,
                      child: Row(
                        children: [
                          cell(
                            Text(
                              p.of(r).symbol,
                              style: t.headline.copyWith(
                                fontWeight: FontWeight.w400,
                                color: symbolColor(p.of(r)),
                              ),
                            ),
                            role: r,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    return AppCard(
      title: '角色权限',
      semanticLabel: '角色权限矩阵',
      trailing: Flexible(
        child: Text(
          [for (final a in Access.values) '${a.symbol} ${a.label}'].join('　'),
          textAlign: TextAlign.end,
          style: t.footnote.copyWith(color: c.secondaryLabel),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= 560) return table;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: 560, child: table),
          );
        },
      ),
    );
  }
}

class AuditLogCard extends ConsumerWidget {
  const AuditLogCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final now = watchNowOf(ref);
    final entries = ref.watch(auditProvider).value ?? const <AuditEntry>[];

    Future<void> export() async {
      final name = await ref.read(memberRepositoryProvider).exportAudit();
      ref
          .read(membersUiProvider.notifier)
          .notify(BannerKind.info, '已导出 ${entries.length} 条审计日志：$name');
    }

    return AppCard(
      title: '审计日志',
      semanticLabel: '审计日志',
      gap: AppSpacing.x1,
      trailing: SecondaryButton(label: '导出 CSV', onPressed: export),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in entries)
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.separatorSubtle)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.x1),
                    child: StatusDot(
                      StatusTone.offline,
                      size: 8,
                      color: auditDot(context, e.kind),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: e.actor,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(text: ' ${e.action}'),
                            ],
                          ),
                          style: t.body.copyWith(color: c.label),
                        ),
                        const SizedBox(height: AppSpacing.half),
                        Text(
                          '${auditTime(e.at, now)} · ${e.client}',
                          style: t.footnote.copyWith(color: c.secondaryLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
