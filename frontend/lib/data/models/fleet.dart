import 'package:flutter/foundation.dart';

import 'command.dart';

enum Formation {
  line('一字横排'),
  column('纵队'),
  v('V 字'),
  grid('方阵');

  const Formation(this.label);

  final String label;
}

/// 时间轴动作块的类别，决定配色（Fleet.dc.html：姿态绿、移动蓝、动作紫）。
enum TrackActionKind { pose, move, act }

/// 联调时间轴上的一个动作块。
@immutable
class TrackAction {
  const TrackAction({
    required this.deviceId,
    required this.start,
    required this.end,
    required this.action,
    this.kind = TrackActionKind.pose,
  });

  final String deviceId;
  final Duration start;
  final Duration end;
  final String action;
  final TrackActionKind kind;
}

/// 同步指令中单台设备的回执（`POST /fleet-sessions/{id}/commands` 的返回项）。
@immutable
class FleetAck {
  const FleetAck({
    required this.deviceId,
    required this.ok,
    this.latency,
    this.error,
  });

  final String deviceId;
  final bool ok;
  final Duration? latency;
  final CommandError? error;
}

/// 上一条同步指令及各设备回执（Fleet.dc.html「上一条指令回执」）。
@immutable
class FleetReceipt {
  const FleetReceipt({
    required this.label,
    required this.sentAt,
    required this.acks,
    this.scheduleOffset = const Duration(milliseconds: 200),
  });

  final String label;
  final DateTime sentAt;

  /// 计划执行时刻相对发出时刻的偏移（各设备在同一时刻执行）。
  final Duration scheduleOffset;
  final List<FleetAck> acks;
}

/// HANDOFF.md §6 FleetSession。领队是 [deviceIds] 的第一台。
@immutable
class FleetSession {
  const FleetSession({
    required this.id,
    required this.number,
    required this.title,
    required this.initiatorId,
    required this.startedAt,
    required this.deviceIds,
    required this.formation,
    required this.spacing,
    this.presetId,
    this.controlMode = '领队-跟随',
    this.clockSync = 'PTP · 局域网',
    this.lostLinkAction = '原地趴下',
    this.clockSkew = const Duration(milliseconds: 3),
    this.timeline = const [],
    this.timelineLength = const Duration(seconds: 16),
    this.lastReceipt,
    this.paused = false,
  });

  final String id;

  /// 会话编号（「联调会话 #12」）。
  final int number;

  /// 会话标题，通常取自预设（「展厅迎宾」）。
  final String title;
  final String initiatorId;
  final DateTime startedAt;
  final List<String> deviceIds;
  final Formation formation;

  /// 编队间距，米。
  final double spacing;
  final String? presetId;
  final String controlMode;
  final String clockSync;
  final String lostLinkAction;
  final Duration clockSkew;
  final List<TrackAction> timeline;
  final Duration timelineLength;
  final FleetReceipt? lastReceipt;

  /// 全局急停时所有会话暂停。
  final bool paused;

  String get name => '联调会话 #$number';
  String? get leaderId => deviceIds.firstOrNull;

  FleetSession copyWith({
    List<String>? deviceIds,
    Formation? formation,
    double? spacing,
    List<TrackAction>? timeline,
    FleetReceipt? lastReceipt,
    bool? paused,
  }) => FleetSession(
    id: id,
    number: number,
    title: title,
    initiatorId: initiatorId,
    startedAt: startedAt,
    deviceIds: deviceIds ?? this.deviceIds,
    formation: formation ?? this.formation,
    spacing: spacing ?? this.spacing,
    presetId: presetId,
    controlMode: controlMode,
    clockSync: clockSync,
    lostLinkAction: lostLinkAction,
    clockSkew: clockSkew,
    timeline: timeline ?? this.timeline,
    timelineLength: timelineLength,
    lastReceipt: lastReceipt ?? this.lastReceipt,
    paused: paused ?? this.paused,
  );
}

/// 联调预设（侧边栏「联调预设」）：设备组合 + 队形，可一键发起会话。
@immutable
class FleetPreset {
  const FleetPreset({
    required this.id,
    required this.name,
    required this.deviceIds,
    this.formation = Formation.v,
    this.spacing = 1.2,
  });

  final String id;
  final String name;
  final List<String> deviceIds;
  final Formation formation;
  final double spacing;
}

/// 发起或修改会话失败（API 409：设备被占用 / 不可加入）。
class FleetException implements Exception {
  const FleetException(this.message, {this.deviceIds = const []});

  final String message;

  /// 导致失败的设备。
  final List<String> deviceIds;

  @override
  String toString() => message;
}
