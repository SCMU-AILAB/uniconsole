import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'mission_state.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// 「今天 07:12」「11 月 1 日 06:40」。
String mapUpdatedLabel(DateTime? t) {
  if (t == null) return '未建图';
  final n = DateTime.now();
  final today = t.year == n.year && t.month == n.month && t.day == n.day;
  return '${today ? '今天' : '${t.month} 月 ${t.day} 日'} ${_two(t.hour)}:${_two(t.minute)}';
}

ZoneKind zoneKind(ZoneType t) => switch (t) {
  ZoneType.ban || ZoneType.wall => ZoneKind.ban,
  ZoneType.slow => ZoneKind.slow,
  ZoneType.whitelist => ZoneKind.whitelist,
};

/// 地图编辑（Missions.dc.html）：墙体、禁行区、充电桩、设备、路线与点位。
///
/// 工具：选择（点选、拖动点位）、添加点位（追加到末尾）、绘制路线（插入到选中点位之后）、
/// 禁行区、充电桩、测距。
class MissionMap extends ConsumerStatefulWidget {
  const MissionMap({super.key});

  @override
  ConsumerState<MissionMap> createState() => _MissionMapState();
}

class _MissionMapState extends ConsumerState<MissionMap> {
  /// 拖动中的点位位置（松手后提交 `PATCH /missions/{id}`）。
  (int, Offset)? _drag;

  MissionsUi get _ui => ref.read(missionsUiProvider.notifier);

  Future<void> _setWaypoints(Mission m, List<Waypoint> wps) =>
      ref.read(missionRepositoryProvider).setWaypoints(m.id, wps);

  Future<void> _tapMap(Offset p, Mission? m, MapTool tool) async {
    final ui = ref.read(missionsUiProvider);
    switch (tool) {
      case MapTool.select:
        return;
      case MapTool.point || MapTool.path:
        if (m == null) {
          _ui.notify(BannerKind.info, '先在右侧选择任务，或点「新建任务」');
          return;
        }
        final at = tool == MapTool.path && ui.point != null
            ? ui.point! + 1
            : m.waypoints.length;
        final wp = Waypoint(
          name: '点位 ${m.waypoints.length + 1}',
          position: p,
          stay: const Duration(seconds: 5),
        );
        await _setWaypoints(m, [...m.waypoints]..insert(at, wp));
        _ui.point(at);
      case MapTool.zone:
        await ref
            .read(safetyRepositoryProvider)
            .addZone(
              ZoneType.ban,
              mapId: ui.mapId,
              rect: Rect.fromCenter(center: p, width: 12, height: 12),
            );
        _ui.notify(BannerKind.success, '已新建禁入区，路径规划会绕开它；在「安全策略」中可调整规则');
      case MapTool.dock:
        await ref.read(missionRepositoryProvider).addCharger(ui.mapId, p);
        _ui.notify(BannerKind.success, '已标注充电桩');
      case MapTool.ruler:
        _ui.ruler(ui.ruler.length == 1 ? [ui.ruler.first, p] : [p]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;
    final ui = ref.watch(missionsUiProvider);
    final map = ref.watch(selectedMapProvider);
    final m = ref.watch(selectedMissionProvider);
    final zones = ref.watch(mapZonesProvider(ui.mapId)).value ?? const <Zone>[];
    final devices = {
      for (final d in ref.watch(devicesProvider).value ?? const <Device>[])
        d.id: d,
    };
    final mobile = LayoutSize.ofContext(context).isMobile;
    if (map == null) return const SizedBox(height: 360);

    final wps = [
      for (final (i, w) in (m?.waypoints ?? const <Waypoint>[]).indexed)
        _drag?.$1 == i ? w.copyWith(position: _drag!.$2) : w,
    ];
    final deviceId = m?.assignee.deviceId;
    final robotAt = deviceId == null ? null : map.devicePositions[deviceId];
    final running = m?.state == MissionState.running;
    final done = running ? m!.completed.clamp(0, wps.length) : 0;

    final routes = [
      if (wps.length > 1)
        MapRoute([
          for (final w in wps) w.position,
          if (m!.loop && wps.length > 2) wps.first.position,
        ]),
      if (running && done > 0)
        MapRoute([
          for (final w in wps.take(done)) w.position,
          ?robotAt,
        ], done: true),
    ];

    final tools = MapOverlayPanel(
      child: Flex(
        direction: mobile ? Axis.horizontal : Axis.vertical,
        mainAxisSize: MainAxisSize.min,
        // 横排（手机）放在横向滚动里，高度不受约束，不能 stretch。
        crossAxisAlignment: mobile
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.stretch,
        children: [
          for (final tool in MapTool.values) ...[
            if (tool.index > 0)
              const SizedBox(width: AppSpacing.half, height: AppSpacing.half),
            _ToolButton(
              label: tool.label,
              selected: tool == ui.tool,
              onTap: () => _ui.tool(tool),
            ),
          ],
        ],
      ),
    );

    final info = m == null || map.id != m.mapId
        ? null
        : MapOverlayPanel(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            child: _RouteInfo(
              map: map,
              mission: m.copyWith(waypoints: wps),
            ),
          );

    final view = FloorMapView(
      semanticLabel: '地图 · ${map.shortName}',
      rooms: [
        for (final a in map.areas)
          MapRoom(a.rect, label: a.label, filled: !a.outline),
      ],
      zones: [
        for (final z in zones)
          MapZone.rect(
            z.rect,
            kind: zoneKind(z.type),
            label: '${z.type.label} · ${z.name}',
          ),
      ],
      routes: routes,
      chargers: map.chargers,
      robots: [
        for (final e in map.devicePositions.entries)
          if (devices[e.key] case final d?)
            MapRobot(d.name, e.value, heading: map.deviceHeadings[e.key] ?? 0),
      ],
      footer:
          '${map.shortName} · 分辨率 ${map.resolutionCm} cm · 更新于 ${mapUpdatedLabel(map.updatedAt)} · 当前工具：${ui.tool.label}',
      layer: (context, size) {
        Offset pct(Offset local) => Offset(
          (local.dx / size.width * 100).clamp(0, 100),
          (local.dy / size.height * 100).clamp(0, 100),
        );
        Offset px(Offset p) =>
            Offset(p.dx / 100 * size.width, p.dy / 100 * size.height);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: ui.tool == MapTool.select
                    ? HitTestBehavior.translucent
                    : HitTestBehavior.opaque,
                onTapUp: (d) => _tapMap(pct(d.localPosition), m, ui.tool),
                child: MouseRegion(
                  cursor: ui.tool == MapTool.select
                      ? MouseCursor.defer
                      : SystemMouseCursors.precise,
                ),
              ),
            ),
            if (ui.ruler.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RulerPainter([
                      for (final p in ui.ruler) px(p),
                    ], s.warning.dot),
                  ),
                ),
              ),
            if (ui.ruler.length == 2)
              Positioned(
                left: (px(ui.ruler[0]).dx + px(ui.ruler[1]).dx) / 2,
                top: (px(ui.ruler[0]).dy + px(ui.ruler[1]).dy) / 2,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -1.4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x2,
                      vertical: AppSpacing.half,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                      border: Border.all(color: s.warning.dot),
                    ),
                    child: Text(
                      '${map.distance(ui.ruler[0], ui.ruler[1]).toStringAsFixed(1)} m',
                      style: t.captionStrong.copyWith(
                        color: s.warning.fg,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
            for (final (i, w) in wps.indexed)
              Positioned(
                left: px(w.position).dx,
                top: px(w.position).dy,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -0.5),
                  child: _WaypointDot(
                    index: i,
                    name: w.name,
                    selected: i == ui.point,
                    done: i < done,
                    onTap: () => _ui.point(i),
                    onDrag: ui.tool == MapTool.select
                        ? (delta) {
                            final from = _drag?.$1 == i
                                ? _drag!.$2
                                : w.position;
                            setState(
                              () => _drag = (
                                i,
                                Offset(
                                  (from.dx + delta.dx / size.width * 100).clamp(
                                    0,
                                    100,
                                  ),
                                  (from.dy + delta.dy / size.height * 100)
                                      .clamp(0, 100),
                                ),
                              ),
                            );
                          }
                        : null,
                    onDragEnd: () async {
                      final d = _drag;
                      if (d == null || m == null) return;
                      _ui.point(i);
                      await _setWaypoints(m, [
                        for (final (j, x) in m.waypoints.indexed)
                          j == d.$1 ? x.copyWith(position: d.$2) : x,
                      ]);
                      if (mounted) setState(() => _drag = null);
                    },
                  ),
                ),
              ),
          ],
        );
      },
      overlays: [
        if (!mobile)
          Positioned(
            left: AppSpacing.x4,
            top: AppSpacing.x4,
            width: 96,
            child: tools,
          ),
        // 手机上地图太窄，路线信息放到地图下方，不遮挡点位。
        if (info != null && !mobile)
          Positioned(right: AppSpacing.x4, top: AppSpacing.x4, child: info),
      ],
    );

    final sized = SizedBox(height: mobile ? 360 : 520, child: view);
    if (!mobile) return sized;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        sized,
        if (info != null) ...[
          const SizedBox(height: AppSpacing.x3),
          info,
        ],
        const SizedBox(height: AppSpacing.x3),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: tools),
      ],
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      semanticLabel: '工具：$label',
      toggled: selected,
      focusRadius: AppRadius.xs,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        height: 30,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
        decoration: BoxDecoration(
          color: selected
              ? c.accentFill
              : st.pressed || st.hovered
              ? c.fillSecondary
              : c.mapOverlay.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: context.type.subhead.copyWith(
            color: selected ? c.onAccent : c.label,
          ),
        ),
      ),
    );
  }
}

/// 点位圆点：选中为强调色大圆 + 外圈；已完成为描边空心；未到达为深灰实心。
class _WaypointDot extends StatelessWidget {
  const _WaypointDot({
    required this.index,
    required this.name,
    required this.selected,
    required this.done,
    required this.onTap,
    this.onDrag,
    this.onDragEnd,
  });

  final int index;
  final String name;
  final bool selected;
  final bool done;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onDrag;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = selected ? 30.0 : 24.0;
    final (bg, fg, border) = selected
        ? (c.accentFill, c.onAccent, c.surface)
        : done
        ? (c.surface, c.secondaryLabel, c.decorativeGray)
        : (c.mapMarker, c.onAccent, c.surface);
    final dot = Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: '点位 ${index + 1} $name${done ? '，已完成' : ''}',
      focusRadius: d / 2 + 2,
      cursor: onDrag == null
          ? SystemMouseCursors.click
          : SystemMouseCursors.grab,
      builder: (context, st) => AnimatedContainer(
        // 阴影随选中切换，回弹曲线会把阴影插值成负值，这里用无回弹的 smooth。
        duration: AppMotion.move(context, AppMotion.smooth),
        curve: AppMotion.smooth,
        width: d,
        height: d,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 2),
          boxShadow: [
            if (selected) BoxShadow(color: c.accentRing, spreadRadius: 5),
            if (!selected)
              BoxShadow(
                color: c.shadow.withValues(alpha: 0.25),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
          ],
        ),
        child: Text(
          '${index + 1}',
          style: context.type.caption.copyWith(
            color: fg,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    );
    if (onDrag == null) return dot;
    return GestureDetector(
      onPanUpdate: (e) => onDrag!(e.delta),
      onPanEnd: (_) => onDragEnd?.call(),
      child: dot,
    );
  }
}

/// 右上角：路线名、点位数、全长、预计时长、图例。
class _RouteInfo extends StatelessWidget {
  const _RouteInfo({required this.map, required this.mission});

  final SiteMap map;
  final Mission mission;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final n = mission.waypoints.length;
    final len = routeLength(map, mission);
    final eta = routeDuration(map, mission);
    final style = t.footnote.copyWith(color: c.tertiaryLabel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          mission.name,
          style: t.footnoteMedium.copyWith(
            color: c.label,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.x1),
        Text(
          n == 0
              ? '还没有点位'
              : '$n 个点位 · 全长 ${len.round()} m · 预计 ${eta.inMinutes} 分钟',
          style: style,
        ),
        const SizedBox(height: AppSpacing.x1),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Legend(done: true),
            const SizedBox(width: AppSpacing.x1),
            Text('已走过', style: style),
            const SizedBox(width: AppSpacing.x2),
            _Legend(done: false),
            const SizedBox(width: AppSpacing.x1),
            Text('计划', style: style),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(14, 3),
    painter: _LegendPainter(context.colors.accent, done),
  );
}

class _LegendPainter extends CustomPainter {
  _LegendPainter(this.color, this.done);

  final Color color;
  final bool done;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = done ? 3 : 2;
    final y = size.height / 2;
    if (done) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    } else {
      canvas.drawLine(Offset(0, y), Offset(5, y), p);
      canvas.drawLine(Offset(9, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(_LegendPainter old) =>
      old.color != color || old.done != done;
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.points, this.color);

  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (final pt in points) {
      canvas.drawCircle(pt, 4, p);
    }
    if (points.length == 2) canvas.drawLine(points[0], points[1], p);
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.points != points;
}
