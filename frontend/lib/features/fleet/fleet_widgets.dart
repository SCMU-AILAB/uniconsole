import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'fleet_page.dart';

/// 按预设发起联调（侧边栏「联调预设」与空状态页共用）：成功后进入会话页，
/// 有设备不可用时弹出提示（API：任一被占用则整体失败 409）。
Future<void> startFleetPreset(
  BuildContext context,
  WidgetRef ref,
  String presetId,
) async {
  try {
    final id = await ref
        .read(fleetRepositoryProvider)
        .start(presetId: presetId);
    if (context.mounted) context.go(Routes.fleet(id));
  } on FleetException catch (e) {
    if (!context.mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppAlert<void>(
        title: '无法发起联调',
        message: '${e.message}。处理后再试，或先在会话中去掉这些设备。',
        actions: const [AlertAction(label: '好', value: null)],
      ),
    );
  }
}

/// 参与设备的候选列表：不含离线设备；按会话预设的顺序，其余按设备顺序（Fleet.dc.html ALL）。
List<Device> fleetCandidates(WidgetRef ref, FleetSession s) {
  final devices = ref.watch(devicesProvider).value ?? const <Device>[];
  final presets = ref.watch(fleetPresetsProvider).value ?? const [];
  final order =
      presets.where((p) => p.id == s.presetId).firstOrNull?.deviceIds ??
      const <String>[];
  int rank(Device d) {
    final i = order.indexOf(d.id);
    if (i >= 0) return i;
    final j = s.deviceIds.indexOf(d.id);
    return j >= 0 ? 100 + j : 1000 + devices.indexOf(d);
  }

  return [
    for (final d in devices)
      if (d.status != DeviceStatus.offline) d,
  ]..sort((a, b) => rank(a).compareTo(rank(b)));
}

/// 设备不能加入会话的原因（与 mock / 服务器的检查一致）。
String? fleetBlocker(WidgetRef ref, Device d, FleetSession s) {
  switch (d.status) {
    case DeviceStatus.alert:
      return '告警';
    case DeviceStatus.charging:
      return '充电中';
    case DeviceStatus.offline:
      return '离线';
    case DeviceStatus.online || DeviceStatus.busy:
      break;
  }
  final lease = ref.watch(leaseProvider(d.id));
  if (lease == null || ref.watch(holdsLeaseProvider(d.id))) return null;
  if (lease.holderKind == LeaseHolderKind.session && lease.holderId == s.id) {
    return null;
  }
  return '${ref.watch(leaseHolderNameProvider(d.id)) ?? ''} 控制中';
}

// ---- 参与设备 ----

class ParticipantsCard extends ConsumerWidget {
  const ParticipantsCard({
    super.key,
    required this.session,
    required this.canOperate,
    required this.actions,
  });

  final FleetSession session;
  final bool canOperate;
  final FleetActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final s = session;
    final candidates = fleetCandidates(ref, s);
    return AppCard(
      title: '参与设备',
      gap: AppSpacing.x2,
      trailing: Text(
        '${s.deviceIds.length} / ${candidates.length}',
        style: t.subhead.copyWith(
          color: c.secondaryLabel,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final d in candidates)
            _ParticipantRow(
              device: d,
              session: s,
              blocker: fleetBlocker(ref, d, s),
              canOperate: canOperate,
              onToggle: (v) => actions.toggle(d.id, v),
            ),
          const SizedBox(height: AppSpacing.x2),
          Text(
            '告警或充电中的设备不能加入。加入后，设备的个人控制权会被会话接管。',
            style: t.footnote.copyWith(color: c.secondaryLabel),
          ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends StatelessWidget {
  const _ParticipantRow({
    required this.device,
    required this.session,
    required this.blocker,
    required this.canOperate,
    required this.onToggle,
  });

  final Device device;
  final FleetSession session;
  final String? blocker;
  final bool canOperate;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final joined = session.deviceIds.contains(d.id);
    final leader = session.leaderId == d.id;
    final (StatusTone tone, String role) = blocker != null
        ? (StatusTone.warning, blocker!)
        : !joined
        ? (StatusTone.offline, '未加入')
        : leader
        ? (StatusTone.busy, '领队')
        : (StatusTone.online, '跟随');
    final enabled = canOperate && blocker == null;
    return Opacity(
      opacity: blocker != null ? 0.55 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onToggle(!joined) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x1,
            vertical: AppSpacing.x2,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.separatorSubtle)),
          ),
          child: Row(
            children: [
              AppCheckbox(
                value: joined && blocker == null,
                onChanged: enabled ? onToggle : null,
                semanticLabel: '${d.name}，$role',
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            d.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyMedium.copyWith(color: c.label),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        Tag(label: role, tone: tone),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.half),
                    Text(
                      '${d.model.replaceFirst('Unitree ', '')} · 电量 ${d.battery ?? '—'}%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.footnote.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                d.latencyMs == null ? '—' : '${d.latencyMs} ms',
                style: t.footnote.copyWith(
                  color: c.secondaryLabel,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- 编队地图 ----

class FormationMap extends ConsumerWidget {
  const FormationMap({
    super.key,
    required this.session,
    required this.canOperate,
    required this.actions,
  });

  final FleetSession session;
  final bool canOperate;
  final FleetActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final s = session;
    final ui = ref.watch(fleetUiProvider(s.id));
    final uiNotifier = ref.read(fleetUiProvider(s.id).notifier);
    final devices = {
      for (final d in ref.watch(devicesProvider).value ?? const <Device>[])
        d.id: d,
    };
    final leader = devices[s.leaderId]?.name;
    final mobile = LayoutSize.ofContext(context).isMobile;

    Offset positionOf(int i, String id) {
      final p =
          formationPosition(s.formation, i, s.deviceIds.length) +
          (ui.offsets[id] ?? Offset.zero);
      return Offset(p.dx.clamp(4, 96), p.dy.clamp(6, 94));
    }

    return SizedBox(
      height: mobile ? 340 : 420,
      child: FloorMapView(
        semanticLabel: '编队地图 · 展厅 1F',
        gridSize: 28,
        zoom: ui.zoom,
        rooms: const [
          MapRoom(Rect.fromLTRB(6, 10, 94, 92), filled: false),
          MapRoom(Rect.fromLTRB(76, 64, 94, 92)),
        ],
        walls: const [
          [Offset(6, 44), Offset(28, 44), Offset(28, 10)],
        ],
        labels: const [
          MapLabel(Offset(9, 14), '接待台'),
          MapLabel(Offset(78, 84), '展品区 · 禁入'),
          MapLabel(Offset(47, 87), '入口'),
        ],
        footer: canOperate ? '展厅 1F · 1:100 · 拖动设备可调整编队位置' : '展厅 1F · 1:100',
        layer: (context, size) => Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _AxisPainter(c.accent)),
            ),
            for (final (i, id) in s.deviceIds.indexed)
              _DraggableMarker(
                key: ValueKey(id),
                position: positionOf(i, id),
                mapSize: size,
                zoom: ui.zoom,
                name: devices[id]?.name ?? id,
                leader: i == 0,
                onDrag: canOperate
                    ? (delta) => uiNotifier.drag(id, delta)
                    : null,
              ),
          ],
        ),
        overlays: [
          Positioned(
            left: AppSpacing.x4,
            top: AppSpacing.x4,
            right: 64,
            child: Wrap(
              spacing: AppSpacing.x2,
              runSpacing: AppSpacing.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IgnorePointer(
                  ignoring: !canOperate,
                  child: SegmentedControl<Formation>(
                    semanticLabel: '编队队形',
                    value: s.formation,
                    onChanged: actions.setFormation,
                    options: [
                      for (final f in Formation.values)
                        SegmentOption(f, f.label),
                    ],
                  ),
                ),
                if (leader != null)
                  MapOverlayPanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x3,
                      vertical: AppSpacing.x2,
                    ),
                    child: Text(
                      '间距 ${s.spacing} m · 跟随领队 $leader',
                      style: t.subhead.copyWith(color: c.tertiaryLabel),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            right: AppSpacing.x4,
            top: AppSpacing.x4,
            child: _ZoomButtons(
              onZoomIn: ui.zoom < FleetUi.zoomLevels.last
                  ? () => uiNotifier.zoom(1)
                  : null,
              onZoomOut: ui.zoom > FleetUi.zoomLevels.first
                  ? () => uiNotifier.zoom(-1)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// 编队中轴（虚线，强调色 50%）。
class _AxisPainter extends CustomPainter {
  _AxisPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * 0.5;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 2;
    for (var y = size.height * 0.18; y < size.height * 0.76; y += 8) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, math.min(y + 4, size.height * 0.76)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_AxisPainter old) => old.color != color;
}

/// 编队里的设备标记：切换队形时以弹簧移到新位置，拖动时跟手。
class _DraggableMarker extends StatefulWidget {
  const _DraggableMarker({
    super.key,
    required this.position,
    required this.mapSize,
    required this.zoom,
    required this.name,
    required this.leader,
    required this.onDrag,
  });

  /// 百分比坐标。
  final Offset position;
  final Size mapSize;
  final double zoom;
  final String name;
  final bool leader;
  final ValueChanged<Offset>? onDrag;

  @override
  State<_DraggableMarker> createState() => _DraggableMarkerState();
}

class _DraggableMarkerState extends State<_DraggableMarker> {
  var _dragging = false;

  static const _box = Size(96, 56);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final w = widget.mapSize.width, h = widget.mapSize.height;
    final p = Offset(
      widget.position.dx / 100 * w,
      widget.position.dy / 100 * h,
    );
    final fill = widget.leader ? c.accentFill : c.mapMarker;
    return AnimatedPositioned(
      duration: _dragging
          ? Duration.zero
          : AppMotion.move(context, AppMotion.smooth),
      curve: AppMotion.smooth,
      // 标记圆心对齐到位置点。
      left: p.dx - _box.width / 2,
      top: p.dy - 16,
      width: _box.width,
      height: _box.height,
      child: Semantics(
        label: '${widget.name}${widget.leader ? '（领队）' : '（跟随）'}',
        child: GestureDetector(
          onPanStart: widget.onDrag == null
              ? null
              : (_) => setState(() => _dragging = true),
          onPanEnd: widget.onDrag == null
              ? null
              : (_) => setState(() => _dragging = false),
          onPanUpdate: widget.onDrag == null
              ? null
              : (d) => widget.onDrag!(
                  Offset(d.delta.dx / w * 100, d.delta.dy / h * 100) /
                      widget.zoom,
                ),
          child: MouseRegion(
            cursor: widget.onDrag == null
                ? MouseCursor.defer
                : _dragging
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab,
            child: Column(
              children: [
                AnimatedScale(
                  scale: _dragging && !AppMotion.reduced(context) ? 1.1 : 1,
                  duration: AppMotion.move(context, AppMotion.snappy),
                  curve: AppMotion.snappy,
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: fill,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: widget.leader
                              ? c.accentRing
                              : c.mapMarker.withValues(alpha: 0.12),
                          spreadRadius: 4,
                        ),
                        BoxShadow(
                          color: c.shadow.withValues(alpha: 0.2),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      widget.name.characters.first,
                      style: t.subheadStrong.copyWith(
                        color: c.onAccent,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.x1),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x1,
                    vertical: AppSpacing.half,
                  ),
                  decoration: BoxDecoration(
                    color: c.mapOverlay,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.name,
                    style: t.captionStrong.copyWith(color: c.label),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onZoomIn, required this.onZoomOut});

  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget button(String glyph, String label, VoidCallback? onTap) => Pressable(
      onTap: onTap,
      semanticLabel: label,
      tooltip: label,
      focusRadius: AppRadius.md,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        width: 30,
        height: 30,
        alignment: Alignment.center,
        color: st.pressed ? c.fillSecondary : c.surface.withValues(alpha: 0),
        child: Text(
          glyph,
          style: context.type.metric.copyWith(
            color: st.enabled ? c.label : c.decorativeGray,
            fontWeight: FontWeight.w400,
            height: 1,
          ),
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button('+', '放大', onZoomIn),
          Container(width: 30, height: 1, color: c.separator),
          button('−', '缩小', onZoomOut),
        ],
      ),
    );
  }
}

// ---- 同步指令 ----

class SyncCommandsCard extends ConsumerStatefulWidget {
  const SyncCommandsCard({
    super.key,
    required this.session,
    required this.canOperate,
    required this.estop,
    required this.actions,
  });

  final FleetSession session;
  final bool canOperate;

  /// 有设备处于急停：运动类指令禁用（§8.1）。
  final bool estop;
  final FleetActions actions;

  @override
  ConsumerState<SyncCommandsCard> createState() => _SyncCommandsCardState();
}

class _SyncCommandsCardState extends ConsumerState<SyncCommandsCard> {
  SyncCommand? _sending;

  Future<void> _send(SyncCommand cmd) async {
    setState(() => _sending = cmd);
    try {
      await widget.actions.send(context, cmd);
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.session.deviceIds.length;
    VoidCallback? onPressed(SyncCommand cmd) {
      if (!widget.canOperate || n == 0 || _sending != null) return null;
      if (widget.estop && !cmd.allowedInEstop) return null;
      return () => _send(cmd);
    }

    return AppCard(
      title: '同步指令',
      trailing: Text(
        _sending == null ? '发送给选中的 $n 台设备' : '正在发送「${_sending!.label}」…',
        style: context.type.subhead.copyWith(color: c.secondaryLabel),
      ),
      child: Wrap(
        spacing: AppSpacing.x2,
        runSpacing: AppSpacing.x2,
        children: [
          for (final cmd in SyncCommand.values)
            cmd == SyncCommand.stand
                ? PrimaryButton(
                    label: cmd.label,
                    size: ButtonSize.regular,
                    onPressed: onPressed(cmd),
                  )
                : SecondaryButton(
                    label: cmd.label,
                    size: ButtonSize.regular,
                    onPressed: onPressed(cmd),
                  ),
        ],
      ),
    );
  }
}

// ---- 动作编排时间轴 ----

class ChoreographyCard extends ConsumerStatefulWidget {
  const ChoreographyCard({super.key, required this.session});

  final FleetSession session;

  @override
  ConsumerState<ChoreographyCard> createState() => _ChoreographyCardState();
}

class _ChoreographyCardState extends ConsumerState<ChoreographyCard>
    with SingleTickerProviderStateMixin {
  late final _play = AnimationController(
    vsync: this,
    duration: widget.session.timelineLength,
    // 设计稿播放头停在 00:05.2。
    value: 5.2 / widget.session.timelineLength.inMilliseconds * 1000,
  );

  @override
  void dispose() {
    _play.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_play.isAnimating) {
      _play.stop();
    } else {
      if (_play.value >= 1) _play.value = 0;
      _play.forward();
    }
    setState(() {});
  }

  static String _stamp(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inMilliseconds % 60000 / 1000)
        .toStringAsFixed(1)
        .padLeft(4, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final s = widget.session;
    final devices = {
      for (final d in ref.watch(devicesProvider).value ?? const <Device>[])
        d.id: d,
    };
    final total = s.timelineLength.inMilliseconds;
    StatusTone tone(TrackActionKind k) => switch (k) {
      TrackActionKind.pose => StatusTone.online,
      TrackActionKind.move => StatusTone.busy,
      TrackActionKind.act => StatusTone.action,
    };
    final tracks = [
      for (final id in s.deviceIds)
        TimelineTrackData(
          name: devices[id]?.name ?? id,
          segments: [
            for (final a in s.timeline)
              if (a.deviceId == id)
                TimelineSegment(
                  a.start.inMilliseconds / total,
                  a.end.inMilliseconds / total,
                  label: a.action,
                  tone: tone(a.kind),
                ),
          ],
        ),
    ];

    return AppCard(
      title: '动作编排时间轴',
      trailing: AnimatedBuilder(
        animation: _play,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
              icon: _play.isAnimating ? AppIcons.pause : AppIcons.play,
              label: _play.isAnimating ? '暂停预览' : '播放预览',
              style: IconButtonStyle.circle,
              size: 30,
              iconSize: 12,
              onPressed: tracks.isEmpty ? null : _toggle,
            ),
            const SizedBox(width: AppSpacing.x2),
            Text(
              '${_stamp(s.timelineLength * _play.value)} / ${_stamp(s.timelineLength)}',
              style: t.subhead.copyWith(
                color: c.secondaryLabel,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
      child: tracks.isEmpty
          ? Text(
              '勾选参与设备后生成动作编排',
              style: t.subhead.copyWith(color: c.secondaryLabel),
            )
          : AnimatedBuilder(
              animation: _play,
              builder: (context, _) => TimelineTrack(
                tracks: tracks,
                ticks: const ['0s', '4s', '8s', '12s'],
                position: _play.value,
                positionLabel: _stamp(s.timelineLength * _play.value),
                onSeek: (v) {
                  _play.value = v;
                  if (_play.isAnimating) _play.forward();
                },
                trackHeight: 26,
                labelStyle: t.subheadMedium.copyWith(color: c.label),
              ),
            ),
    );
  }
}

// ---- 右栏 ----

String _hms(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

String _ackError(CommandError? e) => switch (e) {
  CommandError.estopActive => '急停中，未执行',
  CommandError.forbidden => '无控制权',
  CommandError.robotOffline => '离线',
  CommandError.timeout => '回执超时',
  CommandError.rejected => '设备拒绝',
  null => '失败',
};

class ReceiptCard extends ConsumerWidget {
  const ReceiptCard({super.key, required this.session});

  final FleetSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final r = session.lastReceipt;
    final names = {
      for (final d in ref.watch(devicesProvider).value ?? const <Device>[])
        d.id: d.name,
    };
    return AppCard(
      title: '上一条指令回执',
      gap: AppSpacing.x3,
      child: r == null
          ? Text('尚未下发同步指令', style: t.subhead.copyWith(color: c.secondaryLabel))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(r.label, style: t.bodyMedium.copyWith(color: c.label)),
                const SizedBox(height: AppSpacing.half),
                Text(
                  '${_hms(r.sentAt)} 发出 · 计划执行时刻 +${r.scheduleOffset.inMilliseconds} ms',
                  style: t.footnote.copyWith(color: c.secondaryLabel),
                ),
                const SizedBox(height: AppSpacing.x2),
                for (final a in r.acks)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x2,
                    ),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.separatorSubtle)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 16,
                          height: 16,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: a.ok ? s.online.dot : s.critical.dot,
                            shape: BoxShape.circle,
                          ),
                          child: AppIcon(
                            a.ok ? AppIcons.check : AppIcons.close,
                            size: 10,
                            color: c.onAccent,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        Expanded(
                          child: Text(
                            names[a.deviceId] ?? a.deviceId,
                            style: t.body.copyWith(color: c.label),
                          ),
                        ),
                        Text(
                          a.ok
                              ? '回执 ${a.latency?.inMilliseconds ?? 0} ms'
                              : _ackError(a.error),
                          style: t.footnote.copyWith(
                            color: a.ok ? c.secondaryLabel : s.critical.fg,
                            fontFeatures: const [FontFeature.tabularFigures()],
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

class SessionSettingsCard extends ConsumerWidget {
  const SessionSettingsCard({super.key, required this.session});

  final FleetSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final policies = ref.watch(safetyProvider).value?.policies;
    final rows = [
      ('控制模式', session.controlMode),
      ('时钟同步', session.clockSync),
      ('失联策略', session.lostLinkAction),
      // 最小间距来自安全策略「设备间最小距离」，同一数据源（§8.5）。
      ('最小间距', policies == null ? '—' : '${policies.minDistance} m'),
    ];
    return AppCard(
      title: '会话设置',
      gap: AppSpacing.x1,
      child: Column(
        children: [
          for (final (i, (k, v)) in rows.indexed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: c.separatorSubtle)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      k,
                      style: t.body.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                  Text(v, style: t.body.copyWith(color: c.label)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 告警设备自动移出候选的提示（Fleet.dc.html 右栏底部）。
class BlockedNotice extends ConsumerWidget {
  const BlockedNotice({super.key, required this.session});

  final FleetSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider).value ?? const <Alert>[];
    final alertDevices = fleetCandidates(
      ref,
      session,
    ).where((d) => d.status == DeviceStatus.alert);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final d in alertDevices)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.x3),
            child: AppBanner(
              kind: BannerKind.warning,
              message:
                  '${d.name} ${alerts.where((a) => a.deviceId == d.id && a.state != AlertState.closed).firstOrNull?.title ?? '告警中'}，已自动移出候选列表。处理后可重新加入。',
            ),
          ),
      ],
    );
  }
}

// ---- 没有会话 ----

class NoSessionPage extends ConsumerStatefulWidget {
  const NoSessionPage({super.key});

  @override
  ConsumerState<NoSessionPage> createState() => _NoSessionPageState();
}

class _NoSessionPageState extends ConsumerState<NoSessionPage> {
  String? _starting;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final presets = ref.watch(fleetPresetsProvider).value ?? const [];
    final devices = {
      for (final d in ref.watch(devicesProvider).value ?? const <Device>[])
        d.id: d.name,
    };
    return AppPage(
      title: '多机联调',
      children: [
        const EmptyState(
          icon: AppIcons.fleet,
          title: '没有进行中的联调会话',
          message: '从预设发起：会话会一次性获取所有设备的控制权，任一设备不可用则不会发起。',
        ),
        AppCard(
          title: '联调预设',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, p) in presets.indexed)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.x3),
                  decoration: BoxDecoration(
                    border: i == 0
                        ? null
                        : Border(top: BorderSide(color: c.separatorSubtle)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${p.name} · ${p.deviceIds.length} 台',
                              style: t.bodyMedium.copyWith(color: c.label),
                            ),
                            const SizedBox(height: AppSpacing.half),
                            Text(
                              '${p.formation.label} · ${p.deviceIds.map((id) => devices[id] ?? id).join('、')}',
                              style: t.footnote.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x3),
                      PrimaryButton(
                        label: _starting == p.id ? '发起中…' : '发起',
                        onPressed: _starting != null
                            ? null
                            : () async {
                                setState(() => _starting = p.id);
                                await startFleetPreset(context, ref, p.id);
                                if (mounted) setState(() => _starting = null);
                              },
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
