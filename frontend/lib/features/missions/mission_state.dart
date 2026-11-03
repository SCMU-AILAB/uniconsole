import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 地图工具（Missions.dc.html 左上角）。
enum MapTool {
  select('选择'),
  point('添加点位'),
  path('绘制路线'),
  zone('禁行区'),
  dock('充电桩'),
  ruler('测距');

  const MapTool(this.label);

  final String label;
}

class MissionsUiState {
  const MissionsUiState({
    this.mapId = 'b-patrol',
    this.missionId,
    this.point = 2,
    this.tool = MapTool.select,
    this.ruler = const [],
    this.notice,
  });

  final String mapId;

  /// 用户选中的任务；为空时取当前地图上的第一个任务。
  final String? missionId;

  /// 选中的点位（0 起）。设计稿默认选中第 3 个。
  final int? point;
  final MapTool tool;

  /// 测距的两个点（百分比坐标）。
  final List<Offset> ruler;
  final (BannerKind, String)? notice;

  MissionsUiState copyWith({
    String? mapId,
    String? missionId,
    bool clearMission = false,
    int? point,
    bool clearPoint = false,
    MapTool? tool,
    List<Offset>? ruler,
    (BannerKind, String)? notice,
  }) => MissionsUiState(
    mapId: mapId ?? this.mapId,
    missionId: clearMission ? null : missionId ?? this.missionId,
    point: clearPoint ? null : point ?? this.point,
    tool: tool ?? this.tool,
    ruler: ruler ?? this.ruler,
    notice: notice ?? this.notice,
  );
}

class MissionsUi extends Notifier<MissionsUiState> {
  @override
  MissionsUiState build() => const MissionsUiState();

  /// 切换地图：选中该地图上的第一个任务。
  void map(String id) => state = state.copyWith(
    mapId: id,
    clearMission: true,
    point: 0,
    ruler: const [],
  );

  void mission(Mission m) => state = state.copyWith(
    mapId: m.mapId,
    missionId: m.id,
    point: m.waypoints.isEmpty ? null : 0,
    clearPoint: m.waypoints.isEmpty,
    ruler: const [],
  );

  void point(int? i) => state = i == null
      ? state.copyWith(clearPoint: true)
      : state.copyWith(point: i);

  void tool(MapTool t) => state = state.copyWith(tool: t, ruler: const []);

  void ruler(List<Offset> pts) => state = state.copyWith(ruler: pts);

  void notify(BannerKind kind, String text) =>
      state = state.copyWith(notice: (kind, text));
}

final missionsUiProvider =
    NotifierProvider.autoDispose<MissionsUi, MissionsUiState>(MissionsUi.new);

/// 当前地图上被选中的任务。
final selectedMissionProvider = Provider.autoDispose<Mission?>((ref) {
  final ui = ref.watch(missionsUiProvider);
  final missions = ref.watch(missionsProvider).value ?? const <Mission>[];
  final onMap = missions.where((m) => m.mapId == ui.mapId);
  return onMap.where((m) => m.id == ui.missionId).firstOrNull ??
      onMap.where((m) => m.waypoints.isNotEmpty).firstOrNull ??
      onMap.firstOrNull;
});

final selectedMapProvider = Provider.autoDispose<SiteMap?>((ref) {
  final id = ref.watch(missionsUiProvider).mapId;
  return ref.watch(mapsProvider).value?.where((m) => m.id == id).firstOrNull;
});

/// 巡检速度（m/s）与每个动作的平均耗时，用于估算路线时长。
const inspectSpeed = 0.3;
const actionCost = Duration(seconds: 80);

/// 路线全长（m）；闭合路线包括回到起点的一段。
double routeLength(SiteMap map, Mission m) {
  final pts = [
    for (final w in m.waypoints) w.position,
    if (m.loop && m.waypoints.length > 2) m.waypoints.first.position,
  ];
  var d = 0.0;
  for (var i = 1; i < pts.length; i++) {
    d += map.distance(pts[i - 1], pts[i]);
  }
  return d;
}

/// 预计时长：行走 + 停留 + 动作。
Duration routeDuration(SiteMap map, Mission m) {
  final walk = routeLength(map, m) / inspectSpeed;
  final stay = m.waypoints.fold(Duration.zero, (a, w) => a + w.stay);
  final actions = m.waypoints.fold(0, (a, w) => a + w.actions.length);
  return Duration(seconds: walk.round()) + stay + actionCost * actions;
}
