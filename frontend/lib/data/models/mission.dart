import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

enum MissionState {
  running('运行中'),
  scheduled('已排期'),
  paused('已暂停');

  const MissionState(this.label);

  final String label;
}

/// 到达点位后执行的动作（Missions.dc.html「到达后动作」）。
@immutable
class WaypointAction {
  const WaypointAction(this.name, this.detail);

  final String name;
  final String detail;
}

/// HANDOFF.md §6 Waypoint。位置为地图百分比坐标。
@immutable
class Waypoint {
  const Waypoint({
    required this.name,
    required this.position,
    this.yaw = 0,
    this.stay = Duration.zero,
    this.actions = const [],
    this.retries = 2,
  });

  final String name;
  final Offset position;

  /// 到达朝向（度，0 = 地图正右方，逆时针为正）。
  final int yaw;
  final Duration stay;
  final List<WaypointAction> actions;

  /// 失败重试次数，仍失败则跳过并告警。
  final int retries;

  Waypoint copyWith({
    String? name,
    Offset? position,
    int? yaw,
    Duration? stay,
    List<WaypointAction>? actions,
  }) => Waypoint(
    name: name ?? this.name,
    position: position ?? this.position,
    yaw: yaw ?? this.yaw,
    stay: stay ?? this.stay,
    actions: actions ?? this.actions,
    retries: retries,
  );
}

/// 任务执行者：单台设备（可带替补）或联调预设。
@immutable
class MissionAssignee {
  const MissionAssignee.device(String this.deviceId, {this.backupDeviceId})
    : presetId = null;

  const MissionAssignee.preset(String this.presetId)
    : deviceId = null,
      backupDeviceId = null;

  final String? deviceId;
  final String? presetId;

  /// 主设备故障时的替补（「Charlie（故障时由 Delta 替补）」）。
  final String? backupDeviceId;
}

/// HANDOFF.md §6 Mission（`/missions`）。
@immutable
class Mission {
  const Mission({
    required this.id,
    required this.name,
    required this.mapId,
    required this.assignee,
    required this.schedule,
    required this.state,
    this.waypoints = const [],
    this.completed = 0,
    this.loop = true,
  });

  final String id;
  final String name;
  final String mapId;
  final MissionAssignee assignee;

  /// 排期说明，如「每天 09:00、14:00」。
  final String schedule;
  final MissionState state;
  final List<Waypoint> waypoints;

  /// 本轮已完成的点位数（运行中时显示「当前 3/8」）。
  final int completed;

  /// 路线是否闭合（最后一个点位回到起点）。
  final bool loop;

  Mission copyWith({
    String? name,
    MissionState? state,
    List<Waypoint>? waypoints,
    int? completed,
  }) => Mission(
    id: id,
    name: name ?? this.name,
    mapId: mapId,
    assignee: assignee,
    schedule: schedule,
    state: state ?? this.state,
    waypoints: waypoints ?? this.waypoints,
    completed: completed ?? this.completed,
    loop: loop,
  );
}

enum ScheduleKind { run, charge, other }

/// 今日排期上的一块（Missions.dc.html「今日排期」）。
@immutable
class ScheduleBlock {
  const ScheduleBlock({
    required this.deviceId,
    required this.start,
    required this.end,
    required this.label,
    required this.kind,
    this.missionId,
  });

  final String deviceId;
  final DateTime start;
  final DateTime end;
  final String label;
  final ScheduleKind kind;
  final String? missionId;
}
