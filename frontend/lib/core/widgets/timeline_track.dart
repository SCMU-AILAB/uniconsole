import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'pressable.dart';

class TimelineSegment {
  const TimelineSegment(this.start, this.end, {this.label, this.tone});

  /// 0–1 的起止位置。
  final double start;
  final double end;

  /// 有标签时画成排期块（Missions.dc.html 今日排期），否则为数据轨色块。
  final String? label;

  /// 覆盖所在轨道的 [TimelineTrackData.tone]（同一行不同类型的排期块）。
  final StatusTone? tone;
}

class TimelineTrackData {
  const TimelineTrackData({
    required this.name,
    required this.segments,
    this.color,
    this.tone,
  });

  final String name;
  final List<TimelineSegment> segments;

  /// 数据轨颜色（55% 不透明度）。
  final Color? color;

  /// 排期块配色（状态色三件套的 bg / fg）。
  final StatusTone? tone;
}

class TimelineEvent {
  const TimelineEvent({
    required this.position,
    required this.label,
    this.tone = StatusTone.busy,
  });

  final double position;
  final String label;
  final StatusTone tone;
}

/// 多轨时间轴（Replay.dc.html）：事件标记行 + 多条数据轨 + 红色播放头。
///
/// 点击或拖动轨道区域调用 [onSeek]；点击事件标记跳到对应位置。
class TimelineTrack extends StatelessWidget {
  const TimelineTrack({
    super.key,
    required this.tracks,
    required this.position,
    this.events = const [],
    this.ticks = const [],
    this.onSeek,
    this.labelWidth = 64,
    this.trackHeight = 16,
    this.positionLabel,
  });

  final List<TimelineTrackData> tracks;
  final List<TimelineEvent> events;

  /// 顶部时间刻度文字（等分）。
  final List<String> ticks;

  /// 播放头位置 0–1。
  final double position;
  final ValueChanged<double>? onSeek;
  final double labelWidth;

  /// 16（回放数据轨）或 22（排期）。
  final double trackHeight;

  /// 播放头位置的读屏文字，如「00:12:41」。
  final String? positionLabel;

  static const double _gap = 8;

  static bool _isBlock(TimelineTrackData tr) =>
      tr.tone != null ||
      tr.segments.any((g) => g.tone != null || g.label != null);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;

    Widget label(String text) => SizedBox(
      width: labelWidth,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: t.footnote.copyWith(color: c.secondaryLabel),
      ),
    );

    return LayoutBuilder(
      builder: (context, box) {
        final laneWidth = box.maxWidth - labelWidth - _gap;

        void seekAt(double dx) => onSeek?.call(
          ((dx - labelWidth - _gap) / laneWidth).clamp(0.0, 1.0),
        );

        final rows = <Widget>[
          if (ticks.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: labelWidth + _gap),
              child: Row(
                children: [
                  for (final tk in ticks)
                    Expanded(
                      child: Text(
                        tk,
                        style: t.micro.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                ],
              ),
            ),
          if (events.isNotEmpty)
            Row(
              children: [
                label('事件'),
                const SizedBox(width: _gap),
                Expanded(
                  child: SizedBox(
                    height: 26,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final e in events)
                          Positioned(
                            left: e.position * laneWidth,
                            top: 0,
                            child: FractionalTranslation(
                              translation: const Offset(-0.5, 0),
                              child: Pressable(
                                onTap: onSeek == null
                                    ? null
                                    : () => onSeek!(e.position),
                                semanticLabel: '跳到 ${e.label}',
                                focusRadius: AppRadius.xs,
                                builder: (context, st) => Container(
                                  height: 22,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.x2,
                                  ),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: s.of(e.tone).bg,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.xs,
                                    ),
                                  ),
                                  child: Text(
                                    e.label,
                                    style: t.microStrong.copyWith(
                                      color: s.of(e.tone).fg,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          for (final tr in tracks)
            Row(
              children: [
                label(tr.name),
                const SizedBox(width: _gap),
                Expanded(
                  child: Container(
                    height: trackHeight,
                    decoration: BoxDecoration(
                      color: _isBlock(tr)
                          ? c.windowBackground
                          : c.fillSecondary,
                      borderRadius: BorderRadius.circular(
                        trackHeight > 18 ? 5 : 4,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        for (final g in tr.segments)
                          Positioned(
                            left: g.start * laneWidth,
                            width: (g.end - g.start) * laneWidth,
                            top: _isBlock(tr) ? 3 : 0,
                            bottom: _isBlock(tr) ? 3 : 0,
                            child: _isBlock(tr)
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: AppSpacing.x1,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    decoration: BoxDecoration(
                                      color: s
                                          .of(
                                            g.tone ??
                                                tr.tone ??
                                                StatusTone.busy,
                                          )
                                          .bg,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      g.label ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.clip,
                                      softWrap: false,
                                      style: t.micro.copyWith(
                                        color: s
                                            .of(
                                              g.tone ??
                                                  tr.tone ??
                                                  StatusTone.busy,
                                            )
                                            .fg,
                                      ),
                                    ),
                                  )
                                : Opacity(
                                    opacity: 0.55,
                                    child: ColoredBox(
                                      color: tr.color ?? c.accent,
                                    ),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ];

        final spaced = <Widget>[];
        for (var i = 0; i < rows.length; i++) {
          if (i > 0) spaced.add(const SizedBox(height: AppSpacing.x1));
          spaced.add(rows[i]);
        }

        return Semantics(
          slider: onSeek != null,
          label: '时间轴',
          value: positionLabel ?? '${(position * 100).round()}%',
          increasedValue: onSeek == null
              ? null
              : '${((position + 0.02).clamp(0, 1) * 100).round()}%',
          decreasedValue: onSeek == null
              ? null
              : '${((position - 0.02).clamp(0, 1) * 100).round()}%',
          onIncrease: onSeek == null
              ? null
              : () => onSeek!((position + 0.02).clamp(0, 1)),
          onDecrease: onSeek == null
              ? null
              : () => onSeek!((position - 0.02).clamp(0, 1)),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: onSeek == null
                ? null
                : (d) => seekAt(d.localPosition.dx),
            onTapDown: onSeek == null
                ? null
                : (d) {
                    if (d.localPosition.dx > labelWidth) {
                      seekAt(d.localPosition.dx);
                    }
                  },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: spaced,
                ),
                Positioned(
                  left:
                      labelWidth +
                      _gap +
                      position.clamp(0.0, 1.0) * laneWidth -
                      1,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(width: 2, color: s.critical.dot),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
