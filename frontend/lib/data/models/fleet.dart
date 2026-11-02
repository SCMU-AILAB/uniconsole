import 'package:flutter/foundation.dart';

enum Formation { line, column, v, grid }

/// 联调时间轴上的一个动作块。
@immutable
class TrackAction {
  const TrackAction({required this.deviceId, required this.start, required this.end, required this.action});

  final String deviceId;
  final Duration start;
  final Duration end;
  final String action;
}

/// HANDOFF.md §6 FleetSession。
@immutable
class FleetSession {
  const FleetSession({
    required this.id,
    required this.name,
    required this.deviceIds,
    required this.leaderId,
    required this.formation,
    required this.spacing,
    this.timeline = const [],
  });

  final String id;
  final String name;
  final List<String> deviceIds;
  final String leaderId;
  final Formation formation;

  /// 米。
  final double spacing;
  final List<TrackAction> timeline;
}
