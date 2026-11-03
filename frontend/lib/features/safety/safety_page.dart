import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/layout/auto_grid.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'zone_editor.dart';

/// 页面状态：选中围栏、拖动中的草稿、提示条。
class SafetyUiState {
  const SafetyUiState({this.selected = 'z1', this.draft, this.notice});

  final String? selected;

  /// 拖动角点时的临时围栏，松手后提交（`PATCH /zones/{id}`）。
  final Zone? draft;
  final (BannerKind, String)? notice;
}

class SafetyUi extends Notifier<SafetyUiState> {
  @override
  SafetyUiState build() => const SafetyUiState();

  void select(String? id) =>
      state = SafetyUiState(selected: id, notice: state.notice);

  void drag(Zone draft) => state = SafetyUiState(
    selected: state.selected,
    draft: draft,
    notice: state.notice,
  );

  void endDrag() =>
      state = SafetyUiState(selected: state.selected, notice: state.notice);

  void notify(BannerKind kind, String text) => state = SafetyUiState(
    selected: state.selected,
    draft: state.draft,
    notice: (kind, text),
  );
}

final safetyUiProvider = NotifierProvider.autoDispose<SafetyUi, SafetyUiState>(
  SafetyUi.new,
);

String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// 安全策略（Safety.dc.html）：电子围栏编辑、安全策略开关、全局急停。
class SafetyPage extends ConsumerWidget {
  const SafetyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final safety = ref.watch(safetyProvider).value ?? const SafetyState();
    final summary = ref.watch(fleetSummaryProvider);
    final canRelease = ref.watch(canReleaseGlobalEstopProvider);
    final ui = ref.watch(safetyUiProvider);
    final repo = ref.read(safetyRepositoryProvider);
    final mobile = LayoutSize.ofContext(context).isMobile;
    final estop = safety.globalEstop;

    final drill = safety.lastDrillAt;
    final status = estop
        ? '全局急停中 · 所有设备已停止'
        : '安全状态正常 · ${summary.zones} 个围栏生效${drill == null ? '' : ' · 上次急停演练 ${drill.month} 月 ${drill.day} 日'}';

    Future<void> toggleEstop() async {
      if (!estop) {
        // 触发不需要确认：急停永远可达（§8.1）。
        await repo.setGlobalEstop(active: true);
        return;
      }
      final ok = await confirmAction(
        context,
        title: '解除全局急停？',
        message: '设备会保持阻尼趴下，需要在各自的操控页重新站立；暂停的联调会话将恢复。',
        confirmLabel: '解除急停',
      );
      if (!ok) return;
      try {
        await repo.setGlobalEstop(active: false);
      } on LeaseException catch (e) {
        ref
            .read(safetyUiProvider.notifier)
            .notify(BannerKind.warning, e.message);
      }
    }

    Future<void> runDrill() async {
      final ok = await confirmAction(
        context,
        title: '开始急停演练？',
        message: '向 ${summary.online} 台在线设备下发演练急停信号并测量响应时间，设备不会真正停机。',
        confirmLabel: '开始演练',
      );
      if (!ok) return;
      final r = await repo.runDrill();
      ref
          .read(safetyUiProvider.notifier)
          .notify(
            BannerKind.success,
            '急停演练完成：${r.responses.length} 台在线设备均已响应，最慢 ${r.slowest.inMilliseconds} ms',
          );
    }

    final estopButton = EmergencyStopButton(
      label: '全局急停',
      releaseLabel: '解除全局急停',
      engaged: estop,
      compact: mobile,
      onPressed: estop && !canRelease ? null : toggleEstop,
    );

    final banner = Presence(
      child: estop
          ? Padding(
              key: const ValueKey('estop'),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: _EstopBanner(
                online: summary.online,
                by: safety.estopBy,
                at: safety.estopAt,
                canRelease: canRelease,
              ),
            )
          : ui.notice != null
          ? Padding(
              key: ValueKey(ui.notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
            )
          : null,
    );

    return AppPage(
      title: '安全策略',
      subtitle: status,
      toolbarTitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('安全策略', style: t.toolbarTitle.copyWith(color: c.label)),
          Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.caption.copyWith(
              color: estop ? s.critical.fg : c.secondaryLabel,
            ),
          ),
        ],
      ),
      actions: [
        SecondaryButton(label: '急停演练', onPressed: estop ? null : runDrill),
        estopButton,
      ],
      mobileActions: [estopButton],
      gap: AppSpacing.x4,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            banner,
            FlexColumns(
              mainMin: 560,
              trailingWidth: 320,
              main: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ZoneEditor(),
                  SizedBox(height: AppSpacing.x3),
                  ZoneDetailCard(),
                ],
              ),
              trailing: const _PolicyGroups(),
            ),
          ],
        ),
      ],
    );
  }
}

/// 全局急停红条（Safety.dc.html）：标题 + 影响范围 + 触发时间与触发人。
class _EstopBanner extends StatelessWidget {
  const _EstopBanner({
    required this.online,
    required this.by,
    required this.at,
    required this.canRelease,
  });

  final int online;
  final String? by;
  final DateTime? at;
  final bool canRelease;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4,
          vertical: AppSpacing.x3,
        ),
        decoration: BoxDecoration(
          color: c.emergency,
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ),
        child: Wrap(
          spacing: AppSpacing.x3,
          runSpacing: AppSpacing.x1,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '全局急停已触发',
              style: t.headline.copyWith(
                color: c.onAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '$online 台在线设备已进入阻尼模式，所有任务、联调会话已暂停。${canRelease ? '解除需管理者确认。' : '需要管理者解除。'}',
              style: t.body.copyWith(color: c.onAccent),
            ),
            if (at != null)
              Text(
                '${_hms(at!)} · ${by ?? ''}',
                style: t.subhead.copyWith(color: c.onAccent),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- 安全策略开关 ----

class _PolicyGroups extends ConsumerWidget {
  const _PolicyGroups();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p =
        ref.watch(safetyProvider).value?.policies ?? const SafetyPolicies();
    final repo = ref.read(safetyRepositoryProvider);
    void set(SafetyPolicies next) => repo.updatePolicies(next);

    /// 关闭安全检测前先确认。
    Future<void> guarded(
      String name,
      bool on,
      SafetyPolicies Function(bool) next,
    ) async {
      if (!on) {
        final ok = await confirmAction(
          context,
          title: '关闭「$name」？',
          message: '关闭后所有设备不再执行这项保护，操作会写入审计日志。',
          confirmLabel: '关闭',
          destructive: true,
        );
        if (!ok) return;
      }
      set(next(on));
    }

    final groups = <(String, List<_PolicyRow>)>[
      (
        '电量',
        [
          _PolicyRow.toggle(
            '低电量自动回桩',
            '低于阈值时中止任务并返回最近充电桩',
            p.autoDock,
            (v) => set(p.copyWith(autoDock: v)),
          ),
          _PolicyRow.choice('回桩阈值', '低于 10% 时原地趴下等待救援', [
            for (final v in [10, 15, 20, 25, 30])
              (
                v == p.dockThreshold,
                '$v%',
                () => set(p.copyWith(dockThreshold: v)),
              ),
          ]),
        ],
      ),
      (
        '断联处理',
        [
          _PolicyRow.choice('心跳超时', '超过该时间判定为断联', [
            for (final ms in [1000, 1500, 2000, 3000])
              (
                ms == p.heartbeatTimeout.inMilliseconds,
                '${_num(ms / 1000)} 秒',
                () => set(
                  p.copyWith(heartbeatTimeout: Duration(milliseconds: ms)),
                ),
              ),
          ]),
          _PolicyRow.choice('断联后动作', '30 秒仍未恢复则趴下', [
            for (final a in LostLinkAction.values)
              (
                a == p.lostLinkAction,
                a.label,
                () => set(p.copyWith(lostLinkAction: a)),
              ),
          ]),
          _PolicyRow.choice('控制租约过期', '无人续约时', [
            for (final a in LeaseExpiryAction.values)
              (
                a == p.leaseExpiryAction,
                a.label,
                () => set(p.copyWith(leaseExpiryAction: a)),
              ),
          ]),
        ],
      ),
      (
        '速度与距离',
        [
          _PolicyRow.choice('全局限速', '所有设备和步态', [
            for (final v in [0.8, 1.0, 1.5, 2.0])
              (
                v == p.speedLimit,
                '${_num(v)} m/s',
                () => set(p.copyWith(speedLimit: v)),
              ),
          ]),
          _PolicyRow.toggle(
            '靠近行人自动停止',
            '视觉 + 雷达检测到 1 m 内有人',
            p.stopNearPeople,
            (v) => guarded('靠近行人自动停止', v, (v) => p.copyWith(stopNearPeople: v)),
          ),
          _PolicyRow.choice('设备间最小距离', '联调与编队时生效', [
            for (final v in [0.5, 0.8, 1.0, 1.5])
              (
                v == p.minDistance,
                '${_num(v)} m',
                () => set(p.copyWith(minDistance: v)),
              ),
          ]),
        ],
      ),
      (
        '检测与急停',
        [
          _PolicyRow.toggle(
            '跌倒检测',
            '自动尝试恢复站立并告警',
            p.fallDetection,
            (v) => guarded('跌倒检测', v, (v) => p.copyWith(fallDetection: v)),
          ),
          _PolicyRow.toggle(
            '碰撞检测',
            '关节力矩突变时停止',
            p.collisionDetection,
            (v) => guarded('碰撞检测', v, (v) => p.copyWith(collisionDetection: v)),
          ),
          _PolicyRow.toggle(
            '台阶与悬崖检测',
            '深度相机 + 雷达',
            p.cliffDetection,
            (v) => guarded('台阶与悬崖检测', v, (v) => p.copyWith(cliffDetection: v)),
          ),
          _PolicyRow.toggle(
            '急停解除需管理者确认',
            '已配对 ${p.hardwareRemotes} 个硬件急停遥控器',
            p.releaseNeedsManager,
            (v) => guarded(
              '急停解除需管理者确认',
              v,
              (v) => p.copyWith(releaseNeedsManager: v),
            ),
          ),
        ],
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, (title, rows)) in groups.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.x3),
          _PolicyGroup(title: title, rows: rows),
        ],
      ],
    );
  }
}

/// 一行策略：开关或下拉值。
class _PolicyRow {
  _PolicyRow.toggle(this.name, this.desc, bool on, ValueChanged<bool> onChanged)
    : value = on,
      onToggle = onChanged,
      choices = const [];

  _PolicyRow.choice(this.name, this.desc, this.choices)
    : value = null,
      onToggle = null;

  final String name;
  final String desc;
  final bool? value;
  final ValueChanged<bool>? onToggle;

  /// (是否当前值, 文字, 选中回调)。
  final List<(bool, String, VoidCallback)> choices;
}

class _PolicyGroup extends StatelessWidget {
  const _PolicyGroup({required this.title, required this.rows});

  final String title;
  final List<_PolicyRow> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Semantics(
      container: true,
      label: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: t.subheadStrong.copyWith(color: c.secondaryLabel),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(AppRadius.tile),
              border: Border.all(color: c.separator),
            ),
            child: Column(
              children: [
                for (final (i, r) in rows.indexed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x3,
                    ),
                    decoration: BoxDecoration(
                      border: i == rows.length - 1
                          ? null
                          : Border(
                              bottom: BorderSide(color: c.separatorSubtle),
                            ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.name,
                                style: t.bodyMedium.copyWith(color: c.label),
                              ),
                              const SizedBox(height: AppSpacing.half),
                              Text(
                                r.desc,
                                style: t.footnote.copyWith(
                                  color: c.secondaryLabel,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x3),
                        if (r.value != null)
                          AppSwitch(
                            value: r.value!,
                            semanticLabel: r.name,
                            onChanged: r.onToggle,
                          )
                        else
                          _ValueMenu(name: r.name, choices: r.choices),
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

/// 灰底小胶囊 + 下拉箭头的取值按钮（Safety.dc.html「20% ⌄」）。
class _ValueMenu extends StatelessWidget {
  const _ValueMenu({required this.name, required this.choices});

  final String name;
  final List<(bool, String, VoidCallback)> choices;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final current =
        choices.where((ch) => ch.$1).firstOrNull?.$2 ?? choices.first.$2;
    return AppMenu<int>(
      options: [for (final (i, ch) in choices.indexed) MenuOption(i, ch.$2)],
      selected: choices.indexWhere((ch) => ch.$1),
      onSelected: (i) => choices[i].$3(),
      anchor: (context, toggle) => Pressable(
        onTap: toggle,
        semanticLabel: '$name：$current',
        focusRadius: AppRadius.sm,
        builder: (context, st) => AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
          decoration: BoxDecoration(
            color: st.pressed
                ? Color.lerp(c.fillSecondary, c.stateOverlay, 0.1)
                : c.fillSecondary,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                current,
                style: context.type.subheadMedium.copyWith(color: c.label),
              ),
              const SizedBox(width: AppSpacing.x1),
              AppIcon(AppIcons.chevronDown, size: 10, strokeWidth: 2.6),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中围栏的详情（Safety.dc.html 地图下方）。
class ZoneDetailCard extends ConsumerWidget {
  const ZoneDetailCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final ui = ref.watch(safetyUiProvider);
    final zones = ref.watch(zonesProvider).value ?? const <Zone>[];
    final map = ref.watch(siteMapProvider).value;
    final z = ui.draft?.id == ui.selected
        ? ui.draft
        : zones.where((z) => z.id == ui.selected).firstOrNull;
    if (z == null) {
      return AppCard(
        child: Text(
          '点击地图上的围栏查看详情，或用左下角工具新建围栏',
          style: t.subhead.copyWith(color: c.secondaryLabel),
        ),
      );
    }
    final area = map?.areaOf(z.rect);
    return AppCard(
      gap: AppSpacing.x3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: zoneColor(context, z.type),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    z.name,
                    style: t.headline.copyWith(color: c.label),
                  ),
                ),
              ),
              if (area != null)
                Text(
                  '${area.toStringAsFixed(1)} m²',
                  style: t.subhead.copyWith(
                    color: c.secondaryLabel,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              const SizedBox(width: AppSpacing.x3),
              AppIconButton(
                icon: AppIcons.close,
                label: '删除围栏「${z.name}」',
                onPressed: () async {
                  final ok = await confirmAction(
                    context,
                    title: '删除围栏「${z.name}」？',
                    message: '删除后立即对所有设备失效。',
                    confirmLabel: '删除',
                    destructive: true,
                  );
                  if (!ok) return;
                  await ref.read(safetyRepositoryProvider).deleteZone(z.id);
                  ref.read(safetyUiProvider.notifier).select(null);
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          AutoGrid(
            minItemWidth: 180,
            children: [
              InfoTile(label: '规则', value: z.rule),
              InfoTile(label: '生效设备', value: z.scope),
              InfoTile(label: '生效时间', value: z.schedule),
              InfoTile(label: '触发后', value: z.action),
            ],
          ),
        ],
      ),
    );
  }
}
