import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import 'command.dart';

enum RecordingTag {
  alert('告警'),
  patrol('巡检'),
  fleet('联调'),
  manual('手动');

  const RecordingTag(this.label);

  final String label;
}

enum TrackKind {
  video('视频 ×3'),
  pointCloud('点云'),
  joints('关节状态'),
  commands('操控指令');

  const TrackKind(this.label);

  final String label;
}

/// 一条数据轨：有数据的时间段（0–1 的比例）。
@immutable
class RecordingTrack {
  const RecordingTrack(this.kind, this.segments);

  final TrackKind kind;
  final List<(double, double)> segments;
}

/// 时间轴上的事件标记。
@immutable
class RecordingEvent {
  const RecordingEvent(this.offset, this.label, {this.tone = EventTone.info});

  /// 距录制开始的时间。
  final Duration offset;
  final String label;
  final EventTone tone;
}

/// HANDOFF.md §6 Recording。
@immutable
class Recording {
  const Recording({
    required this.id,
    required this.name,
    required this.deviceIds,
    required this.start,
    required this.end,
    required this.sizeBytes,
    this.tags = const [],
    this.tracks = const [],
    this.events = const [],
    this.streams = '视频 3 路 / 点云 / 关节 / IMU / 指令 / 日志',
    this.mapId,
    this.sourceId,
  });

  final String id;
  final String name;
  final List<String> deviceIds;
  final DateTime start;
  final DateTime end;
  final int sizeBytes;
  final List<RecordingTag> tags;
  final List<RecordingTrack> tracks;
  final List<RecordingEvent> events;

  /// 录制内容说明。
  final String streams;

  /// 轨迹所在地图。
  final String? mapId;

  /// 剪辑片段的来源录制。
  final String? sourceId;

  Duration get duration => end.difference(start);
}

/// 回放的数据面板：曲线与地图轨迹（按录制时长等分采样）。
@immutable
class RecordingSamples {
  const RecordingSamples({
    required this.chartTitle,
    required this.temperature,
    required this.velocity,
    required this.trajectory,
    required this.cloud,
  });

  final String chartTitle;
  final List<double> temperature;
  final List<double> velocity;

  /// 地图上的轨迹（百分比坐标，按时间均匀分布）。
  final List<Offset> trajectory;

  /// 点云帧（机器人坐标系，米）。
  final List<Offset> cloud;
}

/// 录制存储（Replay.dc.html 录制库底部说明）。
@immutable
class RecordingStorage {
  const RecordingStorage({
    required this.usedBytes,
    required this.totalBytes,
    required this.retention,
    required this.autoRules,
  });

  final int usedBytes;
  final int totalBytes;
  final Duration retention;

  /// 自动录制规则，如「告警前后 60 秒」「所有联调会话」。
  final List<String> autoRules;
}

enum ExportFormat {
  mcap('MCAP', 'mcap'),
  rosbag('rosbag', 'bag');

  const ExportFormat(this.label, this.extension);

  final String label;
  final String extension;
}
