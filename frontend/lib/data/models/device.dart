import 'package:flutter/foundation.dart';

enum DeviceKind { dog, humanoid }

enum DeviceStatus {
  online('在线'),
  busy('任务中'),
  alert('告警'),
  charging('充电中'),
  offline('离线');

  const DeviceStatus(this.label);

  final String label;

  bool get isOnline => this != offline;
}

/// 设备分组（侧边栏「设备分组」）。[tone] 是 StatusTone 的名字，由界面层映射成颜色。
@immutable
class DeviceGroup {
  const DeviceGroup({required this.id, required this.name, required this.tone});

  final String id;
  final String name;
  final String tone;
}

/// HANDOFF.md §6 Device。
@immutable
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.code,
    required this.model,
    required this.kind,
    required this.status,
    required this.battery,
    required this.latencyMs,
    required this.location,
    required this.currentTask,
    required this.groupId,
    required this.ownerId,
    this.userId,
    required this.sn,
    required this.firmware,
    required this.ip,
    this.maxMotorTemp,
    this.uptime,
  });

  final String id;
  final String name;
  final String code;
  final String model;
  final DeviceKind kind;
  final DeviceStatus status;

  /// 0–100；离线时为最后一次上报值，未接入电池遥测时为 null。
  final int? battery;

  /// 离线时为 null。
  final int? latencyMs;
  final String location;
  final String currentTask;
  final String groupId;
  final String ownerId;

  /// 当前使用者（持有控制权的人），空闲时为 null。
  final String? userId;
  final String sn;
  final String firmware;
  final String ip;

  /// °C；离线时为 null。
  final int? maxMotorTemp;
  final Duration? uptime;

  Device copyWith({
    String? firmware,
    Duration? uptime,
    DeviceStatus? status,
    String? location,
    String? currentTask,
  }) => Device(
    id: id,
    name: name,
    code: code,
    model: model,
    kind: kind,
    status: status ?? this.status,
    battery: battery,
    latencyMs: latencyMs,
    location: location ?? this.location,
    currentTask: currentTask ?? this.currentTask,
    groupId: groupId,
    ownerId: ownerId,
    userId: userId,
    sn: sn,
    firmware: firmware ?? this.firmware,
    ip: ip,
    maxMotorTemp: maxMotorTemp,
    uptime: uptime ?? this.uptime,
  );
}
