import 'package:flutter/foundation.dart';

import 'command.dart';

enum AlertSeverity {
  critical('严重'),
  warning('警告'),
  info('提示');

  const AlertSeverity(this.label);

  final String label;
}

enum AlertState {
  open('未处理'),
  doing('处理中'),
  closed('已关闭');

  const AlertState(this.label);

  final String label;
}

/// 处理时间线上的一条（`GET /alerts/{id}` 的 `events[]`）。
@immutable
class AlertEvent {
  const AlertEvent({
    required this.at,
    required this.message,
    this.tone = EventTone.neutral,
  });

  final DateTime at;
  final String message;

  /// 圆点颜色：触发为告警级别色，自动动作 / 通知为灰，人工处理为强调色。
  final EventTone tone;
}

/// HANDOFF.md §6 Alert。
@immutable
class Alert {
  const Alert({
    required this.id,
    required this.severity,
    required this.state,
    required this.title,
    required this.deviceId,
    required this.metric,
    required this.createdAt,
    this.location = '',
    this.events = const [],
    this.assigneeId,
    this.silencedUntil,
    this.recordingId,
  });

  final String id;
  final AlertSeverity severity;
  final AlertState state;
  final String title;
  final String deviceId;

  /// 曲线标题，如「RL_calf 电机温度（°C）」。
  final String metric;
  final DateTime createdAt;

  /// 触发位置（「C 区仓库」「联调会话 #11」）。
  final String location;
  final List<AlertEvent> events;

  /// 处理人（确认或被指派的成员）。
  final String? assigneeId;

  /// 静默到期时间：期间不再重复推送。
  final DateTime? silencedUntil;

  /// 自动录制的触发前后 60 秒（Replay.dc.html「自动录制：告警前后 60 秒」）。
  final String? recordingId;

  bool silencedAt(DateTime now) =>
      silencedUntil != null && silencedUntil!.isAfter(now);

  Alert copyWith({
    AlertState? state,
    List<AlertEvent>? events,
    String? assigneeId,
    DateTime? silencedUntil,
    bool clearSilence = false,
  }) => Alert(
    id: id,
    severity: severity,
    state: state ?? this.state,
    title: title,
    deviceId: deviceId,
    metric: metric,
    createdAt: createdAt,
    location: location,
    events: events ?? this.events,
    assigneeId: assigneeId ?? this.assigneeId,
    silencedUntil: clearSilence ? null : silencedUntil ?? this.silencedUntil,
    recordingId: recordingId,
  );
}

/// 告警曲线：触发前 30 分钟的指标采样（`GET /devices/{id}/telemetry?from=&to=`）。
@immutable
class AlertHistory {
  const AlertHistory({
    required this.values,
    required this.threshold,
    this.minY = 0,
    this.maxY = 100,
  });

  final List<double> values;
  final double threshold;
  final double minY;
  final double maxY;
}

/// HANDOFF.md §6 AlertRule（`/alert-rules`）。
@immutable
class AlertRule {
  const AlertRule({
    required this.id,
    required this.name,
    required this.condition,
    required this.severity,
    this.autoAction,
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 触发条件，如「> 60 °C 持续 10 秒」。
  final String condition;
  final AlertSeverity severity;

  /// 自动动作，如「自动降速」「自动回桩」。
  final String? autoAction;
  final bool enabled;

  /// Alerts.dc.html 规则行的副标题。
  String get summary => [condition, severity.label, ?autoAction].join(' · ');

  AlertRule copyWith({bool? enabled}) => AlertRule(
    id: id,
    name: name,
    condition: condition,
    severity: severity,
    autoAction: autoAction,
    enabled: enabled ?? this.enabled,
  );
}

/// 告警可用的指标（API.md「告警规则可用的 metric」）。
enum AlertMetric {
  motorTemp('max_motor_temp', '电机温度', '°C'),
  battery('battery', '电量', '%'),
  latency('latency_ms', '延迟', 'ms'),
  voltage('voltage', '电压', 'V'),
  pitch('pitch', '俯仰角', '°'),
  roll('roll', '横滚角', '°'),
  locConfidence('loc_confidence', '定位置信度', '');

  const AlertMetric(this.key, this.label, this.unit);

  final String key;
  final String label;
  final String unit;
}

/// 通知渠道（Alerts.dc.html「通知渠道」）。
@immutable
class NotifyChannel {
  const NotifyChannel(this.name, this.level);

  final String name;

  /// 推送哪些级别，如「警告及以上」。
  final String level;
}

/// 值班安排：本周值班人，未确认多久后升级给谁。
@immutable
class OnCallRoster {
  const OnCallRoster({
    required this.weeks,
    required this.escalateAfter,
    required this.escalateToId,
  });

  /// 按周轮值，第一项是本周。
  final List<String> weeks;
  final Duration escalateAfter;
  final String escalateToId;

  String get currentId => weeks.first;
}
