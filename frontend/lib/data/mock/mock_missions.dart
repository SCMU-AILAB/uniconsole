import 'dart:async';
import 'dart:ui' show Offset;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';
import 'mock_data_ops.dart';
import 'mock_repositories.dart';
import 'mock_store.dart';

/// 地图与任务（API `/missions`）。
class MockMissionRepository implements MissionRepository {
  MockMissionRepository({required this.world});

  final MockWorld world;

  final _maps = MockStore<List<SiteMap>>([
    MockOpsData.mapB,
    MockData.siteMap,
    MockOpsData.mapC,
  ]);
  final _missions = MockStore<List<Mission>>(MockOpsData.missions);
  late final _schedule = MockStore<List<ScheduleBlock>>(MockOpsData.schedule());
  var _seq = 1;
  Timer? _remap;

  List<Mission> get missions => _missions.value;

  Mission? mission(String id) =>
      _missions.value.where((m) => m.id == id).firstOrNull;

  SiteMap? map(String id) => _maps.value.where((m) => m.id == id).firstOrNull;

  void _replace(String id, Mission Function(Mission) f) {
    _missions.value = [for (final m in _missions.value) m.id == id ? f(m) : m];
  }

  void dispose() => _remap?.cancel();

  @override
  Stream<List<SiteMap>> watchMaps() => _maps.watch();

  @override
  Stream<List<Mission>> watchMissions() => _missions.watch();

  @override
  Stream<List<ScheduleBlock>> watchSchedule() => _schedule.watch();

  @override
  Future<String> addMission(String name, String mapId) async {
    final id = 'm${_seq++}';
    _missions.value = [
      ..._missions.value,
      Mission(
        id: id,
        name: name.trim(),
        mapId: mapId,
        // 新任务默认由该地图上的巡检设备执行，之后可在排期里改。
        assignee: MissionAssignee.device(
          map(mapId)?.devicePositions.keys.firstOrNull ?? 'go2-02',
        ),
        schedule: '未排期',
        state: MissionState.paused,
      ),
    ];
    return id;
  }

  @override
  Future<void> setState(String missionId, MissionState state) async {
    _replace(missionId, (m) => m.copyWith(state: state));
  }

  @override
  Future<void> setWaypoints(String missionId, List<Waypoint> waypoints) async {
    _replace(
      missionId,
      (m) => m.copyWith(
        waypoints: waypoints,
        completed: m.completed.clamp(0, waypoints.length),
      ),
    );
  }

  @override
  Future<void> addCharger(String mapId, Offset position) async {
    _maps.value = [
      for (final m in _maps.value)
        m.id == mapId ? m.copyWith(chargers: [...m.chargers, position]) : m,
    ];
  }

  /// 由「B 区地图更新」这类建图任务执行：任务转为运行中，2 秒后建图完成并恢复原状态。
  @override
  Future<void> remap(String mapId) async {
    final task = _missions.value
        .where((m) => m.mapId == mapId && m.waypoints.isEmpty)
        .firstOrNull;
    if (task != null) await setState(task.id, MissionState.running);
    _remap?.cancel();
    _remap = Timer(const Duration(seconds: 2), () {
      _maps.value = [
        for (final m in _maps.value)
          m.id == mapId ? m.copyWith(updatedAt: DateTime.now()) : m,
      ];
      if (task != null) _replace(task.id, (m) => m.copyWith(state: task.state));
    });
  }
}
