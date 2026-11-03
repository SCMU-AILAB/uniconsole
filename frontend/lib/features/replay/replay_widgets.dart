import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// 「00:12:41」。
String hms(Duration d) =>
    '${_two(d.inHours)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';

/// 录制库的时长「38:00」（超过 1 小时为「1:02:03」）。
String clipLength(Duration d) => d.inHours > 0
    ? '${d.inHours}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}'
    : '${_two(d.inMinutes)}:${_two(d.inSeconds % 60)}';

String gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';

String _storage(int bytes) => bytes >= 1e12
    ? '${(bytes / 1e12).toStringAsFixed(bytes % 1e12 == 0 ? 0 : 1)} TB'
    : '${(bytes / 1e9).round()} GB';

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 「今天」「昨天」「10 月 31 日」。
String dayLabel(DateTime t) {
  final now = DateTime.now();
  if (_sameDay(t, now)) return '今天';
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '昨天';
  return '${t.month} 月 ${t.day} 日';
}

String hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

StatusTone? tagTone(RecordingTag t) => switch (t) {
  RecordingTag.alert => StatusTone.critical,
  RecordingTag.patrol => StatusTone.busy,
  RecordingTag.fleet => StatusTone.action,
  RecordingTag.manual => null,
};

/// 「Charlie」或「2 台」。
String recordingDevices(WidgetRef ref, Recording r) => r.deviceIds.length == 1
    ? ref.watch(deviceProvider(r.deviceIds.first))?.name ?? r.deviceIds.first
    : '${r.deviceIds.length} 台';

/// 工具栏副标题：设备 · 日期 时段 · 大小 · 录制内容。
String recordingMeta(WidgetRef ref, Recording r) =>
    '${recordingDevices(ref, r)} · ${dayLabel(r.start)} ${hm(r.start)}–${hm(r.end)} · ${gb(r.sizeBytes)} · ${r.streams}';

// ---- 录制库 ----

/// 录制库（Replay.dc.html 左栏）：搜索、按日期分组、自动录制规则与存储用量。
class RecordingLibrary extends ConsumerStatefulWidget {
  const RecordingLibrary({
    super.key,
    required this.selected,
    required this.onSelect,
    this.mobile = false,
  });

  final String? selected;
  final ValueChanged<String> onSelect;
  final bool mobile;

  @override
  ConsumerState<RecordingLibrary> createState() => _RecordingLibraryState();
}

class _RecordingLibraryState extends ConsumerState<RecordingLibrary> {
  var _query = '';

  bool _matches(Recording r) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay = [
      r.name,
      recordingDevices(ref, r),
      for (final id in r.deviceIds) ref.read(deviceProvider(id))?.name ?? id,
      for (final t in r.tags) t.label,
      dayLabel(r.start),
      '${r.start.month}-${r.start.day}',
    ].join(' ').toLowerCase();
    return hay.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final all = ref.watch(recordingsProvider).value ?? const <Recording>[];
    final storage = ref.watch(recordingStorageProvider).value;
    final shown = all.where(_matches).toList();
    final days = <String>[];
    for (final r in shown) {
      final d = dayLabel(r.start);
      if (!days.contains(d)) days.add(d);
    }
    final footer = storage == null
        ? null
        : '自动录制：${storage.autoRules.join(' · ')} · 保留 ${storage.retention.inDays} 天（已用 ${_storage(storage.usedBytes)} / ${_storage(storage.totalBytes)}）';

    final search = SearchField(
      hint: '设备、标签、日期',
      semanticLabel: '搜索录制',
      mobile: widget.mobile,
      onChanged: (v) => setState(() => _query = v),
    );

    if (widget.mobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          search,
          const SizedBox(height: AppSpacing.x4),
          for (final d in days) ...[
            InsetGroupedSection(
              header: d,
              children: [
                for (final r in shown.where((r) => dayLabel(r.start) == d))
                  GroupedListRow(
                    title: r.name,
                    subtitle:
                        '${recordingDevices(ref, r)} · ${clipLength(r.duration)} · ${gb(r.sizeBytes)}',
                    onTap: () => widget.onSelect(r.id),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.x4),
          ],
          if (footer != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
              child: Text(
                footer,
                style: t.mobileFootnote.copyWith(color: c.secondaryLabel),
              ),
            ),
        ],
      );
    }

    return Semantics(
      container: true,
      label: '录制库',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.x3),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            for (final d in days) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x1,
                  AppSpacing.x3,
                  AppSpacing.x1,
                  AppSpacing.x1,
                ),
                child: Semantics(
                  header: true,
                  child: Text(
                    d,
                    style: t.captionStrong.copyWith(color: c.secondaryLabel),
                  ),
                ),
              ),
              for (final r in shown.where((r) => dayLabel(r.start) == d))
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.half),
                  child: _RecordingRow(
                    recording: r,
                    selected: r.id == widget.selected,
                    onTap: () => widget.onSelect(r.id),
                  ),
                ),
            ],
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.x5),
                child: Text(
                  '没有符合条件的录制',
                  textAlign: TextAlign.center,
                  style: t.body.copyWith(color: c.secondaryLabel),
                ),
              ),
            if (footer != null) ...[
              const SizedBox(height: AppSpacing.x2),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.x1),
                child: Text(
                  footer,
                  style: t.footnote.copyWith(color: c.secondaryLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecordingRow extends ConsumerWidget {
  const _RecordingRow({
    required this.recording,
    required this.selected,
    required this.onTap,
  });

  final Recording recording;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final r = recording;
    final meta =
        '${recordingDevices(ref, r)} · ${clipLength(r.duration)} · ${gb(r.sizeBytes)}';
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: '${r.name}，$meta，${r.tags.map((t) => t.label).join('、')}',
      focusRadius: AppRadius.lg,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x3,
          vertical: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          color: selected
              ? c.rowSelected
              : st.pressed
              ? c.fillSecondary
              : c.surface.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.name, style: t.cardTitle.copyWith(color: c.label)),
            const SizedBox(height: AppSpacing.x1),
            Text(meta, style: t.footnote.copyWith(color: c.secondaryLabel)),
            const SizedBox(height: AppSpacing.x1),
            Wrap(
              spacing: AppSpacing.x1,
              children: [
                for (final tag in r.tags)
                  Tag(label: tag.label, tone: tagTone(tag)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- 四路同步视图 ----

/// 视频 / 点云 / 曲线 / 地图轨迹（Replay.dc.html 2 × 2 网格；窄时单列）。
class ReplayPanels extends ConsumerWidget {
  const ReplayPanels({
    super.key,
    required this.recording,
    required this.position,
  });

  final Recording recording;

  /// 0–1。
  final double position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final samples = ref.watch(recordingSamplesProvider(recording.id)).value;
    final time = hms(recording.duration * position);
    final map = recording.mapId == null
        ? null
        : ref
              .watch(mapsProvider)
              .value
              ?.where((m) => m.id == recording.mapId)
              .firstOrNull;

    Widget label(String text, {bool light = false}) => light
        ? Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x2,
              vertical: AppSpacing.half,
            ),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(AppRadius.xs),
              border: Border.all(color: c.separator),
            ),
            child: Text(text, style: t.caption.copyWith(color: c.label)),
          )
        : HudPanel(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x2,
              vertical: AppSpacing.half,
            ),
            child: Text(text, style: t.caption.copyWith(color: c.hudText)),
          );

    final video = VideoPanel(
      placeholder: '[录制画面 · $time]',
      showCrosshair: false,
      semanticLabel: '录制画面 · 前置 RGB · $time',
      topLeft: label('前置 RGB'),
    );

    final cloud = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: PointCloudView(
          points: samples?.cloud ?? const [],
          border: false,
          label: '点云',
          semanticLabel: '录制点云 · $time',
        ),
      ),
    );

    final chart = AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x3,
          vertical: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              samples?.chartTitle ?? '',
              style: t.footnote.copyWith(
                color: c.label,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.x1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => LineChart(
                  semanticLabel: '温度与速度曲线',
                  background: false,
                  showLegend: true,
                  // 图例占一行，其余给曲线。
                  height: math.max(0, box.maxHeight - 20),
                  minY: 0,
                  maxY: 100,
                  cursor: position,
                  series: [
                    ChartSeries(
                      values: samples?.temperature ?? const [],
                      color: s.warning.dot,
                      label: '温度',
                    ),
                    ChartSeries(
                      values: samples?.velocity ?? const [],
                      label: '速度',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final path = samples?.trajectory ?? const <Offset>[];
    final (traveled, at) = _along(path, position);
    final trajectory = AspectRatio(
      aspectRatio: 16 / 9,
      child: FloorMapView(
        semanticLabel: '地图轨迹${map == null ? '' : ' · ${map.shortName}'}',
        gridSize: 20,
        walls: [path],
        routes: [if (traveled.length > 1) MapRoute(traveled, done: true)],
        layer: (context, size) => Stack(
          children: [
            if (at != null)
              Positioned(
                left: at.dx / 100 * size.width - 8,
                top: at.dy / 100 * size.height - 8,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: c.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.surface, width: 2),
                    boxShadow: [
                      BoxShadow(color: c.accentRing, spreadRadius: 4),
                    ],
                  ),
                ),
              ),
          ],
        ),
        overlays: [
          Positioned(
            left: AppSpacing.x3,
            top: AppSpacing.x3,
            child: label('地图轨迹', light: true),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        final panels = [video, cloud, chart, trajectory];
        if (box.maxWidth < 400) {
          return Column(
            children: [
              for (final (i, p) in panels.indexed) ...[
                if (i > 0) const SizedBox(height: AppSpacing.x3),
                p,
              ],
            ],
          );
        }
        Widget pair(Widget a, Widget b) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: a),
            const SizedBox(width: AppSpacing.x3),
            Expanded(child: b),
          ],
        );
        return Column(
          children: [
            pair(video, cloud),
            const SizedBox(height: AppSpacing.x3),
            pair(chart, trajectory),
          ],
        );
      },
    );
  }

  /// 按路径长度比例取出已走过的部分和当前位置。
  static (List<Offset>, Offset?) _along(List<Offset> path, double f) {
    if (path.length < 2) return (path, path.firstOrNull);
    final lens = [
      for (var i = 1; i < path.length; i++) (path[i] - path[i - 1]).distance,
    ];
    final total = lens.fold(0.0, (a, b) => a + b);
    var left = total * f.clamp(0.0, 1.0);
    final out = [path.first];
    for (var i = 0; i < lens.length; i++) {
      if (left <= lens[i]) {
        final p = Offset.lerp(
          path[i],
          path[i + 1],
          lens[i] == 0 ? 0 : left / lens[i],
        )!;
        return ([...out, p], p);
      }
      left -= lens[i];
      out.add(path[i + 1]);
    }
    return (out, path.last);
  }
}

// ---- 播放控制 + 多轨时间轴 ----

class ReplayControls extends StatelessWidget {
  const ReplayControls({
    super.key,
    required this.recording,
    required this.position,
    required this.playing,
    required this.speed,
    required this.onToggle,
    required this.onSeek,
    required this.onSpeed,
    this.mobile = false,
  });

  final Recording recording;
  final double position;
  final bool playing;
  final double speed;
  final VoidCallback onToggle;
  final ValueChanged<double> onSeek;
  final ValueChanged<double> onSpeed;
  final bool mobile;

  static const speeds = [0.5, 1.0, 2.0, 4.0];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final total = recording.duration;
    final now = total * position;
    void jump(int seconds) {
      final ms = total.inMilliseconds;
      if (ms == 0) return;
      onSeek(((now.inMilliseconds + seconds * 1000) / ms).clamp(0.0, 1.0));
    }

    String speedLabel(double v) =>
        '${v == v.roundToDouble() ? v.toStringAsFixed(0) : v}×';

    return AppCard(
      semanticLabel: '播放控制',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.x3,
            runSpacing: AppSpacing.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SecondaryButton(
                    label: '−10 s',
                    filled: true,
                    onPressed: () => jump(-10),
                  ),
                  const SizedBox(width: AppSpacing.x3),
                  AppIconButton(
                    icon: playing ? AppIcons.pause : AppIcons.play,
                    label: playing ? '暂停' : '播放',
                    style: IconButtonStyle.primary,
                    onPressed: onToggle,
                  ),
                  const SizedBox(width: AppSpacing.x3),
                  SecondaryButton(
                    label: '+10 s',
                    filled: true,
                    onPressed: () => jump(10),
                  ),
                ],
              ),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: hms(now),
                      style: t.cardTitle.copyWith(color: c.label),
                    ),
                    TextSpan(
                      text: ' / ${hms(total)}',
                      style: t.body.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              SegmentedControl<double>(
                semanticLabel: '倍速',
                options: [
                  for (final v in speeds) SegmentOption(v, speedLabel(v)),
                ],
                value: speed,
                onChanged: onSpeed,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          TimelineTrack(
            position: position,
            positionLabel: hms(now),
            onSeek: onSeek,
            events: [
              for (final e in recording.events)
                TimelineEvent(
                  position: total.inMilliseconds == 0
                      ? 0
                      : e.offset.inMilliseconds / total.inMilliseconds,
                  label: e.label,
                  tone: switch (e.tone) {
                    EventTone.critical => StatusTone.critical,
                    EventTone.warning => StatusTone.warning,
                    _ => StatusTone.busy,
                  },
                ),
            ],
            tracks: [
              for (final tr in recording.tracks)
                TimelineTrackData(
                  name: tr.kind.label,
                  color: switch (tr.kind) {
                    TrackKind.video => c.accent,
                    TrackKind.pointCloud => c.cloudMid,
                    TrackKind.joints => s.online.dot,
                    TrackKind.commands => s.action.dot,
                  },
                  segments: [
                    for (final (a, b) in tr.segments) TimelineSegment(a, b),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
