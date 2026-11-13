import 'package:flutter/foundation.dart';

/// 运动模式（API `set_mode`）。
enum MotionMode {
  stand('站立'),
  down('趴下'),
  balance('平衡站立'),
  walk('行走'),
  stairs('爬楼梯'),
  damp('阻尼'),
  recovery('恢复站立');

  const MotionMode(this.label);

  final String label;
}

/// 速度档位（API `set_speed`）。
enum SpeedLevel {
  slow('慢', 0.3),
  normal('标准', 0.8),
  fast('快', 1.5);

  const SpeedLevel(this.label, this.mps);

  final String label;

  /// 最大线速度 m/s。
  final double mps;
}

/// 下发给设备的指令（API `POST /devices/{id}/commands` 的 `command`）。
@immutable
sealed class DeviceCommand {
  const DeviceCommand();

  Map<String, Object?> toJson();

  /// 指令日志里的显示（与 Control.dc.html 的写法一致）。
  String get logText;

  /// 是否属于运动指令（急停中会被拒绝，§8.1）。
  bool get isMotion => true;
}

class MoveCommand extends DeviceCommand {
  const MoveCommand(this.vx, this.vy, this.wz);

  final double vx;
  final double vy;
  final double wz;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'move',
    'vx': vx,
    'vy': vy,
    'wz': wz,
  };

  @override
  String get logText => 'sport.Move(vx=${_n(vx)}, vy=${_n(vy)}, wz=${_n(wz)})';
}

class StopCommand extends DeviceCommand {
  const StopCommand();

  @override
  Map<String, Object?> toJson() => {'kind': 'stop'};

  @override
  String get logText => 'sport.StopMove()';

  @override
  bool get isMotion => false;
}

class SetModeCommand extends DeviceCommand {
  const SetModeCommand(this.mode);

  final MotionMode mode;

  @override
  Map<String, Object?> toJson() => {'kind': 'set_mode', 'mode': mode.name};

  @override
  String get logText => 'sport.SwitchGait(${mode.name})';

  /// 阻尼属于停止类指令；趴下仍需控制权且会被急停拒绝。
  @override
  bool get isMotion => mode != MotionMode.damp;
}

class SetSpeedCommand extends DeviceCommand {
  const SetSpeedCommand(this.level);

  final SpeedLevel level;

  @override
  Map<String, Object?> toJson() => {'kind': 'set_speed', 'level': level.name};

  @override
  String get logText => 'sport.SpeedLevel(${level.name}, ${level.mps} m/s)';
}

class ActionCommand extends DeviceCommand {
  const ActionCommand(this.name, [this.params = const {}, this.motion = true]);

  final String name;
  final Map<String, Object?> params;

  /// 是否会让设备运动（急停中拒绝）。语音播报、灯光等为 false。
  final bool motion;

  @override
  bool get isMotion => motion;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'action',
    'name': name,
    'params': params,
  };

  @override
  String get logText =>
      '$name(${params.entries.map((e) => '${e.key}=${e.value}').join(', ')})';
}

String _n(double v) => v.abs() < 0.005 ? '0' : v.toStringAsFixed(2);

/// 指令回执错误码（API 错误表）。
enum CommandError {
  forbidden('没有该设备的控制权（只读）'),
  estopActive('急停中，运动指令被拒绝'),
  robotOffline('设备不在线'),
  timeout('等待设备回执超时'),
  rejected('设备拒绝指令，详情见指令日志');

  const CommandError(this.message);

  final String message;
}

@immutable
class CommandResult {
  const CommandResult.ok() : error = null;

  const CommandResult.failed(CommandError this.error);

  final CommandError? error;

  bool get ok => error == null;
}

@immutable
class CommandLogEntry {
  const CommandLogEntry({
    required this.at,
    required this.text,
    this.ok = true,
    this.error,
  });

  final DateTime at;
  final String text;
  final bool ok;
  final String? error;
}

/// 设备事件（Main.dc.html「最近事件」；API `robot_event` / 状态变化）。
enum EventTone { info, success, warning, critical, neutral }

@immutable
class DeviceEvent {
  const DeviceEvent({
    required this.deviceId,
    required this.at,
    required this.text,
    required this.tone,
  });

  final String deviceId;
  final DateTime at;
  final String text;
  final EventTone tone;
}
