import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/layout/auto_grid.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repositories/repositories.dart';
import '../devices/device_widgets.dart';

/// 交给自动任务时的目标（`{"kind":"task","id":…}`）。
const schedulerTarget = LeaseTarget.task('scheduler');

/// 页面状态：选中设备、提示条、转移目标。
class LeasesUiState {
  const LeasesUiState({this.selected, this.notice, this.target});

  final String? selected;
  final (BannerKind, String)? notice;
  final LeaseTarget? target;

  LeasesUiState copyWith({
    String? selected,
    (BannerKind, String)? notice,
    bool clearNotice = false,
    LeaseTarget? target,
    bool clearTarget = false,
  }) => LeasesUiState(
    selected: selected ?? this.selected,
    notice: clearNotice ? null : notice ?? this.notice,
    target: clearTarget ? null : target ?? this.target,
  );
}

class LeasesUi extends Notifier<LeasesUiState> {
  @override
  LeasesUiState build() => const LeasesUiState();

  void select(String id) =>
      state = state.copyWith(selected: id, clearTarget: true);

  void target(LeaseTarget t) => state = state.copyWith(target: t);

  void notify(BannerKind kind, String text) =>
      state = state.copyWith(notice: (kind, text));
}

final leasesUiProvider = NotifierProvider.autoDispose<LeasesUi, LeasesUiState>(
  LeasesUi.new,
);

/// 表格行：每台可见的在线设备（`GET /leases`），按「成员 → 联调 → 空闲 → 任务」排列
/// （与 Lease.dc.html 的顺序一致）。
List<Device> leaseRows(WidgetRef ref) {
  final devices = ref.watch(devicesProvider).value ?? const <Device>[];
  int rank(Device d) => switch (ref.watch(leaseProvider(d.id))?.holderKind) {
    LeaseHolderKind.user => 0,
    LeaseHolderKind.session => 1,
    null => 2,
    LeaseHolderKind.task => 3,
  };
  final rows = [
    for (final d in devices)
      if (d.status != DeviceStatus.offline) d,
  ];
  // 稳定排序：同一类保持设备顺序。
  return [
    for (final r in [0, 1, 2, 3]) ...rows.where((d) => rank(d) == r),
  ];
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 租约剩余：进度（0–1）与文字（「4:18」「会话」「22:00」「—」）。
(double, String) leaseRemaining(Lease? l, DateTime now, Duration term) {
  if (l == null) return (0, '—');
  if (l.holderKind == LeaseHolderKind.session) return (1, '会话');
  final exp = l.expiresAt;
  if (exp == null) return (1, '任务');
  if (l.holderKind == LeaseHolderKind.task) return (1, _hm(exp));
  final left = exp.difference(now);
  return (
    (left.inMilliseconds / term.inMilliseconds).clamp(0.0, 1.0),
    formatCountdown(left),
  );
}

/// 控制权（Lease.dc.html）：租约表 + 当前持有者 + 申请队列 + 转移。
class LeasesPage extends ConsumerStatefulWidget {
  const LeasesPage({super.key});

  @override
  ConsumerState<LeasesPage> createState() => _LeasesPageState();
}

class _LeasesPageState extends ConsumerState<LeasesPage> {
  final _rulesKey = GlobalKey();
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  LeasesUi get _ui => ref.read(leasesUiProvider.notifier);

  Future<void> _run(Future<void> Function() f, String success) async {
    try {
      await f();
      _ui.notify(BannerKind.success, success);
    } on LeaseException catch (e) {
      _ui.notify(BannerKind.warning, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = leaseRows(ref);
    final ui = ref.watch(leasesUiProvider);
    final summary = ref.watch(fleetSummaryProvider);
    final selected =
        rows.where((d) => d.id == ui.selected).firstOrNull ?? rows.firstOrNull;
    final mobile = LayoutSize.ofContext(context).isMobile;

    if (selected == null) {
      return const AppPage(
        title: '控制权',
        children: [EmptyState(title: '没有在线设备', icon: AppIcons.lease)],
      );
    }

    final holds = ref.watch(holdsLeaseProvider(selected.id));
    final lease = ref.watch(leaseProvider(selected.id));
    final me = ref.watch(currentUserProvider).value;
    final queued = lease?.queue.any((r) => r.userId == me?.id) ?? false;

    Future<void> request() async {
      final r = await ref.read(leaseRepositoryProvider).acquire(selected.id);
      final holder = ref.read(leaseHolderNameProvider(selected.id));
      _ui.notify(
        BannerKind.success,
        r == LeaseRequestResult.granted
            ? '已获得 ${selected.name} 的控制权'
            : '已提交申请，等待 $holder 处理',
      );
    }

    final notice = Presence(
      child: ui.notice == null
          ? null
          : Padding(
              key: ValueKey(ui.notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
            ),
    );

    final table = mobile
        ? _LeaseList(rows: rows, selected: selected.id)
        : _LeaseTable(rows: rows, selected: selected.id);
    final rules = KeyedSubtree(key: _rulesKey, child: const _RulesCard());
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HolderCard(device: selected, run: _run, note: _note),
        const SizedBox(height: AppSpacing.x3),
        _RequestsCard(device: selected, run: _run),
        const SizedBox(height: AppSpacing.x3),
        _TransferCard(device: selected, note: _note),
      ],
    );

    return AppPage(
      title: '控制权',
      subtitle:
          '同一时刻每台设备只有一个控制者 · ${summary.activeLeases} 个活动租约 · ${summary.pendingLeaseRequests} 个待审批',
      actions: [
        SecondaryButton(
          label: '租约规则',
          onPressed: () {
            final ctx = _rulesKey.currentContext;
            if (ctx != null) {
              Scrollable.ensureVisible(
                ctx,
                duration: AppMotion.move(context, AppMotion.smooth),
                curve: AppMotion.smooth,
              );
            }
          },
        ),
        PrimaryButton(
          label: queued ? '已申请' : '申请控制权',
          onPressed:
              holds || queued || lease?.holderKind == LeaseHolderKind.session
              ? null
              : request,
        ),
      ],
      mobileActions: [
        AppIconButton(
          icon: AppIcons.plus,
          label: '申请 ${selected.name} 的控制权',
          style: IconButtonStyle.circle,
          onPressed: holds || queued ? null : request,
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            notice,
            FlexColumns(
              mainMin: 540,
              trailingWidth: 340,
              main: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  table,
                  const SizedBox(height: AppSpacing.x4),
                  rules,
                ],
              ),
              trailing: side,
            ),
          ],
        ),
      ],
    );
  }
}

// ---- 租约表 ----

class _LeaseTable extends ConsumerWidget {
  const _LeaseTable({required this.rows, required this.selected});

  final List<Device> rows;
  final String selected;

  static const _flex = [11, 13, 10, 14];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final header = t.footnote.copyWith(color: c.secondaryLabel);

    Widget grid(List<Widget> cells) => Row(
      children: [
        for (final (i, cell) in cells.indexed) ...[
          if (i > 0) const SizedBox(width: AppSpacing.x3),
          i < 4
              ? Expanded(flex: _flex[i], child: cell)
              : SizedBox(width: 56, child: cell),
        ],
      ],
    );

    return Semantics(
      container: true,
      label: '设备租约',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x2,
          vertical: AppSpacing.x1,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        // 设计稿：表格最小宽 600，容器内横向滚动。
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth < 600 ? 600.0 : box.maxWidth;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: w,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.x3,
                        vertical: AppSpacing.x2,
                      ),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.separator)),
                      ),
                      child: grid([
                        Text('设备', style: header),
                        Text('持有者', style: header),
                        Text('来源', style: header),
                        Text('租约剩余', style: header),
                        Text('排队', style: header, textAlign: TextAlign.right),
                      ]),
                    ),
                    for (final d in rows)
                      _LeaseRow(
                        device: d,
                        selected: d.id == selected,
                        grid: grid,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HolderAvatar extends ConsumerWidget {
  const _HolderAvatar({required this.deviceId, this.size = 24});

  final String deviceId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(leaseProvider(deviceId));
    return switch (l?.holderKind) {
      null => Avatar(name: '—', size: size),
      LeaseHolderKind.user => MemberAvatar(l!.holderId, size: size),
      LeaseHolderKind.session => MemberAvatar(
        ref.watch(fleetSessionProvider(l!.holderId))?.initiatorId,
        size: size,
      ),
      LeaseHolderKind.task => Avatar(
        name: '任务调度',
        size: size,
        color: context.colors.decorativeGray,
      ),
    };
  }
}

class _LeaseRow extends ConsumerWidget {
  const _LeaseRow({
    required this.device,
    required this.selected,
    required this.grid,
  });

  final Device device;
  final bool selected;
  final Widget Function(List<Widget>) grid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final d = device;
    final l = ref.watch(leaseProvider(d.id));
    final holder = ref.watch(leaseHolderNameProvider(d.id)) ?? '—';
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final term =
        ref.watch(safetyProvider).value?.policies.leaseTerm ??
        const Duration(minutes: 5);
    final (pct, left) = leaseRemaining(l, now, term);
    final queue = l?.queue.length ?? 0;
    final tabular = const [FontFeature.tabularFigures()];

    return Pressable(
      onTap: () => ref.read(leasesUiProvider.notifier).select(d.id),
      selected: selected,
      semanticLabel: '${d.name}，持有者 $holder，剩余 $left，排队 $queue',
      focusRadius: AppRadius.md,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        padding: const EdgeInsets.all(AppSpacing.x3),
        decoration: BoxDecoration(
          color: selected
              ? c.rowSelected
              : st.pressed
              ? c.fillSecondary
              : c.rowSelected.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border(bottom: BorderSide(color: c.separatorSubtle)),
        ),
        child: grid([
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(d.name, style: t.cardTitle.copyWith(color: c.label)),
              Text(d.code, style: t.caption.copyWith(color: c.secondaryLabel)),
            ],
          ),
          Row(
            children: [
              _HolderAvatar(deviceId: d.id),
              const SizedBox(width: AppSpacing.x2),
              Flexible(
                child: Text(
                  holder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.body.copyWith(color: c.label),
                ),
              ),
            ],
          ),
          Text(
            l?.source ?? '空闲',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.subhead.copyWith(color: c.tertiaryLabel),
          ),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Container(
                    height: 5,
                    color: c.separator,
                    alignment: Alignment.centerLeft,
                    child: AnimatedFractionallySizedBox(
                      duration: AppMotion.move(context, AppMotion.smooth),
                      curve: AppMotion.smooth,
                      widthFactor: pct,
                      child: Container(
                        color: pct < 0.3 ? s.warning.dot : c.accent,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              SizedBox(
                width: 40,
                child: Text(
                  left,
                  textAlign: TextAlign.right,
                  style: t.subhead.copyWith(
                    color: c.tertiaryLabel,
                    fontFeatures: tabular,
                  ),
                ),
              ),
            ],
          ),
          Text(
            '$queue',
            textAlign: TextAlign.right,
            style: t.bodyMedium.copyWith(
              color: queue > 0 ? s.critical.fg : c.secondaryLabel,
              fontFeatures: tabular,
            ),
          ),
        ]),
      ),
    );
  }
}

/// 移动端：iOS 分组列表代替宽表格。
class _LeaseList extends ConsumerWidget {
  const _LeaseList({required this.rows, required this.selected});

  final List<Device> rows;
  final String selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final term =
        ref.watch(safetyProvider).value?.policies.leaseTerm ??
        const Duration(minutes: 5);
    return InsetGroupedSection(
      header: '设备租约',
      dividerIndent: 52,
      children: [
        for (final d in rows)
          Builder(
            builder: (context) {
              final l = ref.watch(leaseProvider(d.id));
              final holder = ref.watch(leaseHolderNameProvider(d.id)) ?? '无人控制';
              final queue = l?.queue.length ?? 0;
              return GroupedListRow(
                leading: _HolderAvatar(deviceId: d.id, size: 28),
                title: d.name,
                subtitle:
                    '$holder · ${l?.source ?? '空闲'}${queue > 0 ? ' · $queue 人排队' : ''}',
                value: leaseRemaining(l, now, term).$2,
                selected: d.id == selected,
                showChevron: false,
                onTap: () => ref.read(leasesUiProvider.notifier).select(d.id),
              );
            },
          ),
      ],
    );
  }
}

class _RulesCard extends ConsumerWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p =
        ref.watch(safetyProvider).value?.policies ?? const SafetyPolicies();
    return AppCard(
      title: '租约规则',
      gap: AppSpacing.x2,
      child: AutoGrid(
        minItemWidth: 220,
        children: [
          InfoTile(
            label: '租约时长',
            value: '${p.leaseTerm.inMinutes} 分钟 · 有操作时自动续期',
          ),
          InfoTile(
            label: '空闲释放',
            value: '${p.idleRelease.inMinutes} 分钟无输入自动释放',
          ),
          InfoTile(
            label: '断线宽限',
            value:
                '${p.disconnectStop.inSeconds} 秒后停止 · ${p.disconnectRelease.inSeconds} 秒后释放',
          ),
          const InfoTile(label: '优先级', value: '急停 > 管理者收回 > 联调 > 任务 > 手动'),
        ],
      ),
    );
  }
}

// ---- 右栏 ----

typedef _Run = Future<void> Function(Future<void> Function() f, String success);

class _HolderCard extends ConsumerWidget {
  const _HolderCard({
    required this.device,
    required this.run,
    required this.note,
  });

  final Device device;
  final _Run run;

  /// 「转移给」卡片里的附言。
  final TextEditingController note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final l = ref.watch(leaseProvider(d.id));
    final holder = ref.watch(leaseHolderNameProvider(d.id));
    final holds = ref.watch(holdsLeaseProvider(d.id));
    final canManage = ref.watch(canManageLeaseProvider(d.id));
    final canForce = ref.watch(canForceLeaseProvider(d.id));
    final target = ref.watch(leasesUiProvider).target ?? _defaultTarget(ref, l);
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final repo = ref.read(leaseRepositoryProvider);

    final since = switch (l?.holderKind) {
      null => '当前无人控制，可直接申请',
      LeaseHolderKind.session => '随${l!.source}',
      LeaseHolderKind.task => '${l!.source} · 任务开始前 10 分钟自动获取',
      LeaseHolderKind.user => () {
        final at = l!.acquiredAt;
        if (at == null) return l.source;
        final m = now.difference(at).inMinutes;
        return '自 ${_hm(at)} 起 · ${m < 1 ? '刚刚获得' : '已控制 $m 分钟'}';
      }(),
    };
    final transferable =
        l != null &&
        l.holderKind != LeaseHolderKind.session &&
        canManage &&
        target != null;
    final targetName = target == null
        ? ''
        : target.kind == LeaseHolderKind.user
        ? ref.watch(memberNameProvider(target.id)) ?? ''
        : '任务调度';
    final readonlyAfter = holds ? '，你的操控页面将切换为只读观看。' : '。';

    Future<void> forceRelease() async {
      final reason = await promptText(
        context,
        title: '强制收回 ${d.name} 的控制权？',
        message: '会立即停止设备、通知 $holder，并写入审计日志。',
        hint: '原因（必填）',
        confirmLabel: '强制收回',
        destructive: true,
      );
      if (reason == null) return;
      await run(
        () => repo.forceRelease(d.id, reason: reason),
        '已强制收回 $holder 对 ${d.name} 的控制权，已通知对方并写入审计日志。',
      );
    }

    return Semantics(
      container: true,
      label: '当前持有者',
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _HolderAvatar(deviceId: d.id, size: 44),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${d.name} 的控制者',
                        style: t.subhead.copyWith(color: c.secondaryLabel),
                      ),
                      Text(
                        holder ?? '无人控制',
                        style: t.sectionTitle.copyWith(color: c.label),
                      ),
                      Text(
                        since,
                        style: t.subhead.copyWith(color: c.secondaryLabel),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.x4),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: '转移',
                    size: ButtonSize.regular,
                    expand: true,
                    onPressed: transferable
                        ? () => run(() async {
                            await repo.transfer(
                              d.id,
                              target,
                              note: note.text.trim(),
                            );
                            note.clear();
                          }, '已转移：${d.name} 的控制权已交给 $targetName$readonlyAfter')
                        : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: SecondaryButton(
                    label: '释放',
                    size: ButtonSize.regular,
                    expand: true,
                    onPressed: holds
                        ? () => run(
                            () => repo.release(d.id),
                            '已释放 ${d.name} 的控制权',
                          )
                        : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: DestructiveButton(
                    label: '强制收回',
                    size: ButtonSize.regular,
                    expand: true,
                    onPressed: l != null && canForce && !holds
                        ? forceRelease
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.x3),
            Text(
              '强制收回仅设备管理者和平台管理员可用，需要填写原因，会通知原持有者并写入审计日志。',
              style: t.footnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// 转移目标候选：除当前持有者外的成员，以及「任务调度」。
List<LeaseTarget> transferTargets(WidgetRef ref, Lease? l) {
  final members = ref.watch(membersProvider).value ?? const <Member>[];
  return [
    for (final m in members)
      if (!(l?.holderKind == LeaseHolderKind.user && l?.holderId == m.id) &&
          m.role != MemberRole.viewer)
        LeaseTarget.user(m.id),
    if (l?.holderKind != LeaseHolderKind.task) schedulerTarget,
  ];
}

LeaseTarget? _defaultTarget(WidgetRef ref, Lease? l) =>
    transferTargets(ref, l).firstOrNull;

class _RequestsCard extends ConsumerWidget {
  const _RequestsCard({required this.device, required this.run});

  final Device device;
  final _Run run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final l = ref.watch(leaseProvider(d.id));
    final requests = l?.queue ?? const <LeaseRequest>[];
    final canManage = ref.watch(canManageLeaseProvider(d.id));
    final holds = ref.watch(holdsLeaseProvider(d.id));
    final repo = ref.read(leaseRepositoryProvider);
    final now = ref.watch(clockProvider).value ?? DateTime.now();

    return Semantics(
      container: true,
      label: '申请队列',
      child: AppCard(
        title: '申请队列 · ${d.name}',
        gap: AppSpacing.x3,
        child: requests.isEmpty
            ? Text('暂无申请', style: t.subhead.copyWith(color: c.secondaryLabel))
            : Column(
                children: [
                  for (final (i, r) in requests.indexed) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.x2),
                    Builder(
                      builder: (context) {
                        final who =
                            ref.watch(memberNameProvider(r.userId)) ?? r.userId;
                        return Container(
                          padding: const EdgeInsets.all(AppSpacing.x3),
                          decoration: BoxDecoration(
                            color: c.windowBackground,
                            borderRadius: BorderRadius.circular(
                              AppRadius.group,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  MemberAvatar(r.userId, size: 28),
                                  const SizedBox(width: AppSpacing.x3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          who,
                                          style: t.cardTitle.copyWith(
                                            color: c.label,
                                          ),
                                        ),
                                        Text(
                                          '${relativeTime(r.createdAt, now: now)} · 预计使用 ${r.expectedDuration.inMinutes} 分钟',
                                          style: t.footnote.copyWith(
                                            color: c.secondaryLabel,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.x2),
                              Text(
                                '“${r.reason}”',
                                style: t.body.copyWith(color: c.tertiaryLabel),
                              ),
                              const SizedBox(height: AppSpacing.x2),
                              Row(
                                children: [
                                  Expanded(
                                    child: SecondaryButton(
                                      label: '拒绝',
                                      expand: true,
                                      onPressed: canManage
                                          ? () => run(
                                              () => repo.deny(d.id, r.id),
                                              '已拒绝 $who 的申请，并通知对方。',
                                            )
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.x2),
                                  Expanded(
                                    child: PrimaryButton(
                                      label: '批准并转移',
                                      expand: true,
                                      onPressed: canManage
                                          ? () => run(
                                              () => repo.approve(d.id, r.id),
                                              '已批准：${d.name} 的控制权已转移给 $who${holds ? '，你的操控页面将切换为只读观看。' : '。'}',
                                            )
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _TransferCard extends ConsumerWidget {
  const _TransferCard({required this.device, required this.note});

  final Device device;
  final TextEditingController note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final l = ref.watch(leaseProvider(device.id));
    final targets = transferTargets(ref, l);
    final selected = ref.watch(leasesUiProvider).target ?? targets.firstOrNull;
    final enabled =
        l != null &&
        l.holderKind != LeaseHolderKind.session &&
        ref.watch(canManageLeaseProvider(device.id));

    return Semantics(
      container: true,
      label: '转移控制权',
      child: AppCard(
        title: '转移给',
        gap: AppSpacing.x2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final target in targets)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
                child: Row(
                  children: [
                    Expanded(
                      child: AppRadio<LeaseTarget?>(
                        value: target,
                        groupValue: selected,
                        label: target.kind == LeaseHolderKind.user
                            ? ref.watch(memberNameProvider(target.id)) ??
                                  target.id
                            : '任务调度',
                        onChanged: enabled
                            ? (v) =>
                                  ref.read(leasesUiProvider.notifier).target(v!)
                            : null,
                      ),
                    ),
                    Text(
                      target.kind == LeaseHolderKind.user
                          ? '在线 · 已授权'
                          : '交给自动任务',
                      style: t.footnote.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.x1),
            AppTextField(
              hint: '附言（可选）',
              controller: note,
              minLines: 2,
              mobile: LayoutSize.ofContext(context).isMobile,
            ),
            if (l?.holderKind == LeaseHolderKind.session) ...[
              const SizedBox(height: AppSpacing.x2),
              Text(
                '设备由${l!.source}持有，结束会话或在联调页移出设备后才能转移。',
                style: t.footnote.copyWith(color: c.secondaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
