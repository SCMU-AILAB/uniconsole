import 'package:flutter/foundation.dart';

/// 固件升级状态（Maintenance.dc.html「状态」列）。
enum FirmwareState {
  available,

  /// 任务中，任务结束后升级。
  waitingTask,

  /// 离线，上线后自动升级。
  waitingOnline,

  /// 已排入维护窗口。
  scheduled,

  /// 灰度发布：等待第一台自检通过。
  queued,
  upgrading,
  failed,
  latest,
}

@immutable
class FirmwareStatus {
  const FirmwareStatus({
    required this.deviceId,
    required this.current,
    required this.target,
    required this.state,
    this.progress = 0,
    this.error,
  });

  final String deviceId;
  final String current;
  final String target;
  final FirmwareState state;

  /// 0–1，升级中有效。
  final double progress;

  /// 上次失败原因。
  final String? error;

  bool get upgradable =>
      current != target &&
      state != FirmwareState.upgrading &&
      state != FirmwareState.latest;

  FirmwareStatus copyWith({
    String? current,
    FirmwareState? state,
    double? progress,
    String? error,
  }) => FirmwareStatus(
    deviceId: deviceId,
    current: current ?? this.current,
    target: target,
    state: state ?? this.state,
    progress: progress ?? this.progress,
    error: error ?? this.error,
  );
}

/// 各型号的最新版本。
@immutable
class FirmwareRelease {
  const FirmwareRelease({
    required this.latest,
    required this.agentVersion,
    required this.notes,
  });

  /// 型号 → 最新机身固件。
  final Map<String, String> latest;
  final String agentVersion;
  final List<String> notes;
}

/// 电池健康（Maintenance.dc.html「电池健康」）。
@immutable
class BatteryHealth {
  const BatteryHealth({
    required this.deviceId,
    required this.cycles,
    required this.monthly,
  });

  final String deviceId;
  final int cycles;

  /// 近 6 个月的满充容量（%），最后一项为当前。
  final List<double> monthly;

  double get health => monthly.last;

  /// 按近 6 个月的平均下降速度，预计多少周后低于 [threshold]；不会低于时为 null。
  double? weeksUntil(double threshold) {
    if (health <= threshold || monthly.length < 2) return null;
    final perMonth = (monthly.first - monthly.last) / (monthly.length - 1);
    if (perMonth <= 0) return null;
    return (health - threshold) / perMonth * 52 / 12;
  }
}

enum LogSeverity { info, warn, error }

@immutable
class DeviceLogEntry {
  const DeviceLogEntry({
    required this.at,
    required this.level,
    required this.deviceId,
    required this.message,
  });

  final DateTime at;
  final LogSeverity level;
  final String deviceId;
  final String message;
}

/// 维护窗口：每天的起止时刻（距零点）。
@immutable
class MaintenanceWindow {
  const MaintenanceWindow(this.start, this.end);

  final Duration start;
  final Duration end;

  /// 跨零点的窗口（23:00 开始 4 小时）结束于次日 03:00。
  static String _hm(Duration d) =>
      '${(d.inHours % 24).toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

  String get label => '${_hm(start)}–${_hm(end)}';
  String get startLabel => _hm(start);
}

/// 远程终端的一行输出。
@immutable
class TerminalLine {
  const TerminalLine(this.text, {this.prompt, this.tone = TerminalTone.normal});

  final String text;

  /// 命令行的提示符（`unitree@go2-01:~`），输出行为 null。
  final String? prompt;
  final TerminalTone tone;
}

enum TerminalTone { normal, success, warning, error }
