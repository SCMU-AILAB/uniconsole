import 'package:flutter/foundation.dart';

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

@immutable
class AlertEvent {
  const AlertEvent({required this.at, required this.message});

  final DateTime at;
  final String message;
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
    this.events = const [],
  });

  final String id;
  final AlertSeverity severity;
  final AlertState state;
  final String title;
  final String deviceId;
  final String metric;
  final DateTime createdAt;
  final List<AlertEvent> events;
}
