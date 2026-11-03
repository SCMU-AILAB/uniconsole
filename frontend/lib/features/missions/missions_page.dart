import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'mission_map.dart';
import 'mission_state.dart';

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

/// 地图与任务（Missions.dc.html）：点位 / 路线编辑、点位动作、今日排期、任务列表。
class MissionsPage extends ConsumerWidget {
  const MissionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maps = ref.watch(mapsProvider).value ?? const <SiteMap>[];
    final missions = ref.watch(missionsProvider).value ?? const <Mission>[];
    final schedule =
        ref.watch(scheduleProvider).value ?? const <ScheduleBlock>[];
    final ui = ref.watch(missionsUiProvider);
    final uiNotifier = ref.read(missionsUiProvider.notifier);
    final map = ref.watch(selectedMapProvider);
    final size = LayoutSize.ofContext(context);
    final mobile = size.isMobile;
    // 900 宽以下工具栏放不下地图切换，改放在内容顶部。
    final inlinePicker = size.index <= LayoutSize.medium.index;
    final now = ref.watch(clockProvider).value ?? DateTime.now();

    // 今日已执行：开始时间已过的巡检排期块。
    final runs = schedule
        .where((b) => b.kind == ScheduleKind.run && !b.start.isAfter(now))
        .length;

    Future<void> newMission() async {
      final name = await promptText(
        context,
        title: '新建任务',
        message: '在「${map?.shortName ?? ''}」上新建巡检任务，之后在地图上放置点位。',
        hint: '任务名称',
        confirmLabel: '新建',
      );
      if (name == null) return;
      final id = await ref
          .read(missionRepositoryProvider)
          .addMission(name, ui.mapId);
      final m = ref
          .read(missionsProvider)
          .value
          ?.where((m) => m.id == id)
          .firstOrNull;
      if (m != null) uiNotifier.mission(m);
      uiNotifier.tool(MapTool.point);
      uiNotifier.notify(BannerKind.info, '已新建「$name」，在地图上点按放置点位');
    }

    Future<void> remap() async {
      final task = missions
          .where((m) => m.mapId == ui.mapId && m.waypoints.isEmpty)
          .firstOrNull;
      final who = task?.assignee.deviceId == null
          ? null
          : ref.read(deviceProvider(task!.assignee.deviceId!))?.name;
      final ok = await confirmAction(
        context,
        title: '重新建图「${map?.shortName ?? ''}」？',
        message: who == null
            ? '建图完成后地图自动更新，已有点位与禁行区保持不变。'
            : '由 $who 执行「${task!.name}」，完成后地图自动更新，已有点位与禁行区保持不变。',
        confirmLabel: '开始建图',
      );
      if (!ok) return;
      await ref.read(missionRepositoryProvider).remap(ui.mapId);
      uiNotifier.notify(
        BannerKind.success,
        '已开始重新建图${who == null ? '' : '（$who）'}，完成后自动更新',
      );
    }

    final mapPicker = SegmentedControl<String>(
      semanticLabel: '地图',
      options: [for (final m in maps) SegmentOption(m.id, m.shortName)],
      value: ui.mapId,
      expand: mobile,
      size: mobile ? SegmentedSize.mobile : SegmentedSize.small,
      onChanged: uiNotifier.map,
    );

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
      title: '地图与任务',
      subtitle: '${maps.length} 张地图 · ${missions.length} 个任务 · 今日已执行 $runs 次',
      actions: [
        if (!inlinePicker) mapPicker,
        SecondaryButton(label: '重新建图', onPressed: remap),
        PrimaryButton(label: '新建任务', onPressed: newMission),
      ],
      mobileActions: [
        AppIconButton(
          icon: AppIcons.plus,
          label: '新建任务',
          style: IconButtonStyle.circle,
          onPressed: newMission,
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        if (inlinePicker) mapPicker,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            notice,
            const FlexColumns(
              mainMin: 560,
              trailingWidth: 320,
              main: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MissionMap(),
                  SizedBox(height: AppSpacing.x4),
                  _ScheduleCard(),
                ],
              ),
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _WaypointCard(),
                  SizedBox(height: AppSpacing.x3),
                  _TasksCard(),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---- 点位详情 ----

/// 可加入点位的动作（Missions.dc.html「＋ 添加动作」）。
const _actionPresets = [
  WaypointAction('拍照', '前置 RGB'),
  WaypointAction('识别', '仪表读数'),
  WaypointAction('上报', '超出范围则告警'),
  WaypointAction('热成像', '温度 > 45 °C 告警'),
  WaypointAction('点云快照', '变化检测'),
  WaypointAction('播报', '语音提示'),
  WaypointAction('自检', '电量 ≥ 40%'),
];

class _WaypointCard extends ConsumerWidget {
  const _WaypointCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final ui = ref.watch(missionsUiProvider);
    final m = ref.watch(selectedMissionProvider);
    final map = ref.watch(selectedMapProvider);
    final i = ui.point;
    final w = m == null || i == null || i >= m.waypoints.length
        ? null
        : m.waypoints[i];

    if (m == null || map == null || w == null) {
      return AppCard(
        child: Text(
          m == null
              ? '这张地图上还没有任务，点「新建任务」开始'
              : '选择「添加点位」后在地图上点按，放置「${m.name}」的点位',
          style: t.subhead.copyWith(color: c.secondaryLabel),
        ),
      );
    }

    final repo = ref.read(missionRepositoryProvider);
    Future<void> update(Waypoint next) => repo.setWaypoints(m.id, [
      for (final (j, x) in m.waypoints.indexed) j == i ? next : x,
    ]);
    final meters = map.toMeters(w.position);

    Widget row(String label, Widget value, {bool last = false}) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: c.separator)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: t.body.copyWith(color: c.secondaryLabel)),
          ),
          value,
        ],
      ),
    );
    Text text(String v) => Text(
      v,
      style: t.body.copyWith(
        color: c.label,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    Widget menu<T>(
      String name,
      T value,
      List<(T, String)> options,
    ) => AppMenu<T>(
      options: [for (final (v, l) in options) MenuOption(v, l)],
      selected: value,
      onSelected: (v) => update(switch (v) {
        final int yaw => w.copyWith(yaw: yaw),
        final Duration stay => w.copyWith(stay: stay),
        _ => w,
      }),
      anchor: (context, toggle) => Pressable(
        onTap: toggle,
        semanticLabel:
            '$name：${options.firstWhere((o) => o.$1 == value, orElse: () => options.first).$2}',
        focusRadius: AppRadius.xs,
        builder: (context, st) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            text(
              options
                  .firstWhere(
                    (o) => o.$1 == value,
                    orElse: () => (value, '$value'),
                  )
                  .$2,
            ),
            const SizedBox(width: AppSpacing.x1),
            AppIcon(AppIcons.chevronDown, size: 10, strokeWidth: 2.6),
          ],
        ),
      ),
    );

    String stayLabel(Duration d) =>
        d == Duration.zero ? '—' : '${d.inSeconds} 秒';

    return AppCard(
      semanticLabel: '点位详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${i! + 1}',
                  style: t.subheadStrong.copyWith(
                    color: c.onAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    w.name,
                    style: t.headline.copyWith(color: c.label),
                  ),
                ),
              ),
              AppIconButton(
                icon: AppIcons.close,
                label: '删除点位 ${i + 1}',
                onPressed: () async {
                  final ok = await confirmAction(
                    context,
                    title: '删除点位「${w.name}」？',
                    message: '后面的点位会依次前移。',
                    confirmLabel: '删除',
                    destructive: true,
                  );
                  if (!ok) return;
                  await repo.setWaypoints(m.id, [...m.waypoints]..removeAt(i));
                  ref
                      .read(missionsUiProvider.notifier)
                      .point(
                        m.waypoints.length > 1 ? (i - 1).clamp(0, 99) : null,
                      );
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          Container(
            decoration: BoxDecoration(
              color: c.windowBackground,
              borderRadius: BorderRadius.circular(AppRadius.group),
            ),
            child: Column(
              children: [
                row(
                  '坐标',
                  text(
                    '(${meters.dx.toStringAsFixed(1)} m, ${meters.dy.toStringAsFixed(1)} m)',
                  ),
                ),
                row(
                  '到达朝向',
                  menu('到达朝向', w.yaw, [
                    for (final y in const [0, 90, 180, 270]) (y, '$y°'),
                  ]),
                ),
                row(
                  '停留',
                  menu('停留', w.stay, [
                    for (final s in const [0, 3, 5, 10, 30])
                      (Duration(seconds: s), stayLabel(Duration(seconds: s))),
                  ]),
                ),
                row('失败重试', text('${w.retries} 次，仍失败则跳过并告警'), last: true),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          Text(
            '到达后动作',
            style: t.subheadStrong.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppSpacing.x2),
          for (final (k, a) in w.actions.indexed) ...[
            Container(
              padding: const EdgeInsets.only(
                left: AppSpacing.x3,
                right: AppSpacing.x1,
              ),
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: c.separator),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    child: Text(
                      '${k + 1}',
                      style: t.caption.copyWith(
                        color: c.secondaryLabel,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: Text(a.name, style: t.body.copyWith(color: c.label)),
                  ),
                  Text(
                    a.detail,
                    style: t.footnote.copyWith(color: c.secondaryLabel),
                  ),
                  AppIconButton(
                    icon: AppIcons.close,
                    label: '移除动作「${a.name}」',
                    iconSize: 11,
                    size: 24,
                    onPressed: () => update(
                      w.copyWith(actions: [...w.actions]..removeAt(k)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
          ],
          AppMenu<int>(
            options: [
              for (final (k, a) in _actionPresets.indexed)
                MenuOption(k, '${a.name} · ${a.detail}'),
            ],
            onSelected: (k) =>
                update(w.copyWith(actions: [...w.actions, _actionPresets[k]])),
            anchor: (context, toggle) => _AddActionButton(onTap: toggle),
          ),
        ],
      ),
    );
  }
}

/// 虚线框「＋ 添加动作」。
class _AddActionButton extends StatelessWidget {
  const _AddActionButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      semanticLabel: '添加动作',
      focusRadius: AppRadius.md,
      builder: (context, st) => CustomPaint(
        painter: _DashedBorderPainter(c.decorativeGrayLight),
        child: AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: st.pressed
                ? c.fillSecondary
                : c.surface.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Text(
            '＋ 添加动作',
            style: context.type.subhead.copyWith(color: c.link),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          const Radius.circular(AppRadius.md),
        ),
      );
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke;
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 7) {
        canvas.drawPath(m.extractPath(d, d + 4), p);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

// ---- 任务列表 ----

StatusTone? _stateTone(MissionState s) => switch (s) {
  MissionState.running => StatusTone.busy,
  MissionState.scheduled => null,
  MissionState.paused => StatusTone.warning,
};

class _TasksCard extends ConsumerWidget {
  const _TasksCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final missions = ref.watch(missionsProvider).value ?? const <Mission>[];
    final selected = ref.watch(selectedMissionProvider);
    final presets = ref.watch(fleetPresetsProvider).value ?? const [];
    String device(String? id) =>
        id == null ? '' : ref.watch(deviceProvider(id))?.name ?? id;

    String who(Mission m) {
      final a = m.assignee;
      if (a.presetId != null) {
        final p = presets.where((p) => p.id == a.presetId).firstOrNull;
        return '联调预设 · ${p?.deviceIds.length ?? 0} 台';
      }
      final backup = a.backupDeviceId == null
          ? ''
          : '（故障时由 ${device(a.backupDeviceId)} 替补）';
      return '${device(a.deviceId)}$backup';
    }

    String when(Mission m) =>
        m.state == MissionState.running && m.waypoints.isNotEmpty
        ? '${m.schedule} · 当前 ${m.completed}/${m.waypoints.length}'
        : m.schedule;

    final repo = ref.read(missionRepositoryProvider);
    return AppCard(
      title: '任务',
      gap: AppSpacing.x1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in missions)
            Pressable(
              onTap: () => ref.read(missionsUiProvider.notifier).mission(m),
              selected: m.id == selected?.id,
              semanticLabel: '${m.name}，${m.state.label}，${who(m)}，${when(m)}',
              focusRadius: AppRadius.md,
              builder: (context, st) => AnimatedContainer(
                duration: AppMotion.fade(pressed: st.pressed),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x2,
                  vertical: AppSpacing.x3,
                ),
                decoration: BoxDecoration(
                  color: m.id == selected?.id
                      ? c.rowSelected
                      : st.pressed
                      ? c.fillSecondary
                      : c.surface.withValues(alpha: 0),
                  border: Border(top: BorderSide(color: c.separatorSubtle)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            m.name,
                            style: t.cardTitle.copyWith(color: c.label),
                          ),
                        ),
                        Tag(label: m.state.label, tone: _stateTone(m.state)),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.x1),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${who(m)} · ${when(m)}',
                            style: t.subhead.copyWith(color: c.secondaryLabel),
                          ),
                        ),
                        if (m.id == selected?.id) ...[
                          const SizedBox(width: AppSpacing.x2),
                          m.state == MissionState.running
                              ? SecondaryButton(
                                  label: '暂停',
                                  onPressed: () =>
                                      repo.setState(m.id, MissionState.paused),
                                )
                              : SecondaryButton(
                                  label: '立即执行',
                                  onPressed: m.waypoints.isEmpty
                                      ? null
                                      : () => repo.setState(
                                          m.id,
                                          MissionState.running,
                                        ),
                                ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- 今日排期 ----

class _ScheduleCard extends ConsumerWidget {
  const _ScheduleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final blocks = ref.watch(scheduleProvider).value ?? const <ScheduleBlock>[];
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    double frac(DateTime t) =>
        (t.difference(day).inSeconds / Duration.secondsPerDay).clamp(0.0, 1.0);

    final order = <String>[];
    for (final b in blocks) {
      if (!order.contains(b.deviceId)) order.add(b.deviceId);
    }
    String name(String id) => ref.watch(deviceProvider(id))?.name ?? id;

    return AppCard(
      title: '今日排期',
      trailing: Text(
        '${now.month} 月 ${now.day} 日 周${_weekdays[now.weekday - 1]}',
        style: context.type.subhead.copyWith(color: c.secondaryLabel),
      ),
      child: TimelineTrack(
        position: frac(now),
        positionLabel:
            '现在 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
        trackHeight: 22,
        ticks: const ['00:00', '06:00', '12:00', '18:00'],
        labelStyle: context.type.subheadMedium.copyWith(color: c.label),
        tracks: [
          for (final id in order)
            TimelineTrackData(
              name: name(id),
              segments: [
                for (final b in blocks.where((b) => b.deviceId == id))
                  TimelineSegment(
                    frac(b.start),
                    frac(b.end),
                    label: b.label,
                    tone: switch (b.kind) {
                      ScheduleKind.run => StatusTone.busy,
                      ScheduleKind.charge => StatusTone.online,
                      ScheduleKind.other => StatusTone.action,
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
