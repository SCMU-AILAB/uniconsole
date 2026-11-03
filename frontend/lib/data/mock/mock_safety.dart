import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';
import 'mock_repositories.dart';
import 'mock_store.dart';

/// 安全策略（API `/safety`、`/zones`）。
///
/// 全局急停：所有在线设备进入急停（阻尼），所有联调会话暂停。任何人可以触发；
/// 「急停解除需管理者确认」打开时只有平台管理员和设备管理者可以解除。
class MockSafetyRepository implements SafetyRepository {
  MockSafetyRepository({required this.world});

  final MockWorld world;

  final _state = MockStore(
    // 演练日期、任务排期是日历上的绝对时间，不随「现在」平移。
    SafetyState(lastDrillAt: MockData.lastDrillAt),
  );
  final _map = MockStore(MockData.siteMap);
  final _zones = MockStore<List<Zone>>(MockData.zones);
  var _zoneSeq = 5;
  final _rnd = math.Random(7);

  SafetyState get state => _state.value;

  /// 当前用户能否解除全局急停。
  bool get canRelease =>
      !state.policies.releaseNeedsManager ||
      world.me.role == MemberRole.admin ||
      world.me.role == MemberRole.owner;

  @override
  Stream<SafetyState> watchSafety() => _state.watch();

  @override
  Future<void> setGlobalEstop({required bool active}) async {
    if (active == state.globalEstop) return;
    if (!active && !canRelease) {
      throw const LeaseException('forbidden', '解除全局急停需要管理者确认');
    }
    final online = [
      for (final d in MockData.devices)
        if (d.status.isOnline) d.id,
    ];
    // 先停设备，再更新状态：界面看到「已触发」时设备已经进入阻尼。
    for (final id in online) {
      await world.fleet.setEstop(id, active: active, reason: '全局急停');
    }
    world.sessions.setPaused(active);
    _state.value = SafetyState(
      globalEstop: active,
      estopBy: active ? world.me.name : null,
      estopAt: active ? DateTime.now() : null,
      lastDrillAt: state.lastDrillAt,
      policies: state.policies,
    );
  }

  @override
  Future<void> updatePolicies(SafetyPolicies policies) async {
    _state.value = state.copyWith(policies: policies);
  }

  @override
  Future<DrillResult> runDrill() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final result = DrillResult(
      at: DateTime.now(),
      responses: {
        for (final d in MockData.devices)
          if (d.status.isOnline)
            d.id: Duration(
              milliseconds: (d.latencyMs ?? 20) * 2 + 40 + _rnd.nextInt(30),
            ),
      },
    );
    _state.value = state.copyWith(lastDrillAt: result.at);
    return result;
  }

  @override
  Stream<SiteMap> watchMap() => _map.watch();

  @override
  Stream<List<Zone>> watchZones() => _zones.watch();

  @override
  Future<String> addZone(ZoneType type) async {
    final n = _zones.value.where((z) => z.type == type).length + 1;
    final id = 'z${_zoneSeq++}';
    final zone = Zone(
      id: id,
      mapId: _map.value.id,
      name: '${type.label} $n',
      type: type,
      // 新围栏放在地图中央，用户再拖动角点调整。
      rect: type == ZoneType.wall
          ? const Rect.fromLTWH(30, 50, 24, 2)
          : const Rect.fromLTWH(38, 40, 18, 18),
      rule: switch (type) {
        ZoneType.ban => '禁止进入',
        ZoneType.slow => '限速 0.5 m/s',
        ZoneType.whitelist => '仅白名单设备',
        ZoneType.wall => '禁止穿越',
      },
      scope: '全部设备',
      schedule: '始终',
      action: switch (type) {
        ZoneType.ban => '在边界外 0.5 m 停止并告警',
        ZoneType.slow => '自动降速',
        ZoneType.whitelist => '非白名单设备拒绝路径规划',
        ZoneType.wall => '路径规划绕行',
      },
    );
    _zones.value = [..._zones.value, zone];
    return id;
  }

  @override
  Future<void> updateZone(Zone zone) async {
    _zones.value = [for (final z in _zones.value) z.id == zone.id ? zone : z];
  }

  @override
  Future<void> deleteZone(String id) async {
    _zones.value = [
      for (final z in _zones.value)
        if (z.id != id) z,
    ];
  }
}
