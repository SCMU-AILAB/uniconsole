import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// 一帧遥测（与 ../server/docs/API.md 的 WebSocket `telemetry` 消息字段一致）。
@immutable
class Telemetry {
  const Telemetry({
    required this.deviceId,
    required this.ts,
    this.latencyMs,
    this.battery,
    required this.vx,
    required this.vy,
    required this.wz,
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.jointTemps,
    required this.footForces,
    this.voltage,
    this.current,
    this.batteryTemp,
    this.pose = const Pose(0, 0, 0),
    this.mode,
    this.accel = const [0, 0, 9.8],
    this.locConfidence,
    this.unavailable = const {},
  });

  final String deviceId;
  final DateTime ts;
  final int? latencyMs;

  /// 0–100。
  final double? battery;

  /// m/s、m/s、rad/s。
  final double vx;
  final double vy;
  final double wz;

  /// 度。
  final double roll;
  final double pitch;
  final double yaw;

  /// 4 条腿（FL FR RL RR）× 3 个关节（hip thigh calf），°C。
  final List<List<double>> jointTemps;

  /// 4 个足端接触力（N），顺序同上。
  final List<double> footForces;

  /// V、A、°C。
  final double? voltage;
  final double? current;
  final double? batteryTemp;
  final Pose pose;

  /// 当前运动模式（[MotionMode] 的名字）。
  final String? mode;

  /// IMU 三轴加速度 m/s²（API `extra.acc`）。
  final List<double> accel;

  /// 定位置信度 0–1（API `extra.loc_confidence`）。
  final double? locConfidence;

  /// 机器人明确报告未接入的字段。
  final Set<String> unavailable;

  double? get maxJointTemp {
    final values = jointTemps.expand((l) => l);
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }

  double? jointTemp(int leg, int joint) =>
      leg < jointTemps.length && joint < jointTemps[leg].length
      ? jointTemps[leg][joint]
      : null;
  double? footForce(int leg) =>
      leg < footForces.length ? footForces[leg] : null;
}

@immutable
class Pose {
  const Pose(this.x, this.y, this.yaw);

  final double x;
  final double y;
  final double yaw;
}

/// 一帧点云：机器人坐标系下的点（米），+y 朝前、+x 朝右，机器人在原点。
@immutable
class PointCloudFrame {
  const PointCloudFrame({
    required this.ts,
    required this.points,
    this.available = true,
  });

  final DateTime ts;
  final List<Offset> points;
  final bool available;
}

enum SourceHealth { ok, degraded, idle }

/// 摄像头 / 话题等数据源的状态（Sensors.dc.html）。
@immutable
class SensorSource {
  const SensorSource({
    this.id,
    required this.name,
    required this.detail,
    required this.health,
    this.hz,
  });

  final String name;

  /// Robot-advertised stream id, e.g. `front`; labels are not capabilities.
  final String? id;

  /// 「1280×720 · 30 fps」或话题名。
  final String detail;
  final SourceHealth health;
  final double? hz;
}

@immutable
class SensorStatus {
  const SensorStatus({
    required this.cameras,
    required this.topics,
    required this.lidar,
  });

  final List<SensorSource> cameras;
  final List<SensorSource> topics;

  /// 「4D LiDAR · 360°×90° · 21,600 点/秒 · 10 Hz」
  final String lidar;

  int get liveCameras =>
      cameras.where((c) => c.health == SourceHealth.ok).length;
}
