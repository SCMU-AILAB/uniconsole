import 'dart:ui';
import 'dart:math' as math;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'live_robot_repository.dart';

class LiveSafetyRepository implements SafetyRepository {
  LiveSafetyRepository(this.robot);
  final LiveRobotRepository robot;

  @override
  Stream<SafetyState> watchSafety() => robot.poll(() async {
    final j = jsonMap(await robot.api.get('/safety'));
    final p = jsonMap(j['policies']);
    return SafetyState(
      globalEstop: j['global_estop'] == true,
      estopBy: j['estop_by'],
      estopAt: jsonTime(j['estop_at']),
      lastDrillAt: jsonTime(j['last_drill_at']),
      policies: SafetyPolicies(
        autoDock: p['auto_dock'],
        dockThreshold: number(p['dock_threshold']).round(),
        heartbeatTimeout: Duration(milliseconds: p['heartbeat_timeout_ms']),
        lostLinkAction: LostLinkAction.values.byName(p['lost_link_action']),
        leaseExpiryAction: p['lease_expiry_action'] == 'stop_only'
            ? LeaseExpiryAction.stopOnly
            : LeaseExpiryAction.stopRelease,
        speedLimit: number(p['speed_limit']),
        stopNearPeople: p['stop_near_people'],
        minDistance: number(p['min_distance']),
        fallDetection: p['fall_detection'],
        collisionDetection: p['collision_detection'],
        cliffDetection: p['cliff_detection'],
        releaseNeedsManager: p['release_needs_manager'],
        hardwareRemotes: p['hardware_remotes'],
        leaseTerm: Duration(seconds: p['lease_term_secs']),
        idleRelease: Duration(seconds: p['idle_release_secs']),
        disconnectStop: Duration(seconds: p['disconnect_stop_secs']),
        disconnectRelease: Duration(seconds: p['disconnect_release_secs']),
      ),
    );
  }, events: {'estop', 'changed'});

  @override
  Future<void> setGlobalEstop({required bool active}) async {
    await robot.api.post('/safety/estop', {'active': active});
  }

  @override
  Future<void> updatePolicies(SafetyPolicies p) async {
    await robot.api.patch('/safety/policies', {
      'auto_dock': p.autoDock,
      'dock_threshold': p.dockThreshold,
      'heartbeat_timeout_ms': p.heartbeatTimeout.inMilliseconds,
      'lost_link_action': p.lostLinkAction.name,
      'lease_expiry_action': p.leaseExpiryAction == LeaseExpiryAction.stopOnly
          ? 'stop_only'
          : 'stop_release',
      'speed_limit': p.speedLimit,
      'stop_near_people': p.stopNearPeople,
      'min_distance': p.minDistance,
      'fall_detection': p.fallDetection,
      'collision_detection': p.collisionDetection,
      'cliff_detection': p.cliffDetection,
      'release_needs_manager': p.releaseNeedsManager,
    });
  }

  @override
  Future<DrillResult> runDrill() async {
    final j = jsonMap(await robot.api.post('/safety/drill'));
    final rows = jsonRows(j['responses']);
    if (rows.any((r) => r['ok'] != true)) {
      throw StateError('部分设备没有确认演练，请检查设备指令日志');
    }
    return DrillResult(
      at: DateTime.parse(j['at']).toLocal(),
      responses: {
        for (final r in rows) r['device_id']: Duration(milliseconds: r['ms']),
      },
    );
  }

  Future<Map<String, dynamic>> _map([String? id]) async {
    if (id != null) {
      return jsonMap(await robot.api.get('/maps/${Uri.encodeComponent(id)}'));
    }
    final maps = jsonRows(await robot.api.get('/maps'));
    if (maps.isEmpty) throw StateError('尚未配置地图');
    return maps.first;
  }

  Offset _percent(Map<String, dynamic> m, List p) {
    final origin = m['origin'] as List? ?? [0, 0];
    return Offset(
      (number(p[0]) - number(origin[0])) / number(m['width_m']) * 100,
      100 - (number(p[1]) - number(origin[1])) / number(m['height_m']) * 100,
    );
  }

  Rect _rect(Map<String, dynamic> m, List polygon) {
    final pts = polygon.map((p) => _percent(m, p as List)).toList();
    return Rect.fromLTRB(
      pts.map((p) => p.dx).reduce(math.min),
      pts.map((p) => p.dy).reduce(math.min),
      pts.map((p) => p.dx).reduce(math.max),
      pts.map((p) => p.dy).reduce(math.max),
    );
  }

  List<List<double>> _polygon(Map<String, dynamic> m, Rect r) {
    final origin = m['origin'] as List? ?? [0, 0];
    return [
      for (final p in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft])
        [
          number(origin[0]) + p.dx / 100 * number(m['width_m']),
          number(origin[1]) + (1 - p.dy / 100) * number(m['height_m']),
        ],
    ];
  }

  @override
  Stream<SiteMap> watchMap() => robot.poll(() async {
    final m = await _map();
    return SiteMap(
      id: m['id'],
      name: m['name'],
      shortName: m['short_name'],
      widthMeters: number(m['width_m']),
      heightMeters: number(m['height_m']),
      resolutionCm: number(m['resolution_cm']).round(),
      updatedAt: jsonTime(m['updated_at']),
      areas: [
        for (final a in jsonRows(m['areas'] ?? []))
          MapArea(
            _rect(m, a['polygon']),
            label: a['label'],
            outline: a['outline'] == true,
          ),
      ],
      chargers: [for (final p in m['chargers'] as List? ?? []) _percent(m, p)],
    );
  }, events: {'changed'});
  @override
  Stream<List<Zone>> watchZones({String? mapId}) => robot.poll(() async {
    final m = await _map(mapId);
    return [
      for (final z in jsonRows(
        await robot.api.get('/zones', query: {'map_id': m['id']}),
      ))
        Zone(
          id: z['id'],
          mapId: z['map_id'],
          name: z['name'],
          type: ZoneType.values.byName(z['zone_type']),
          rect: _rect(m, z['polygon']),
          rule: z['rule'],
          scope: z['scope'],
          schedule: z['schedule'],
          action: z['action'],
        ),
    ];
  }, events: {'changed'});
  @override
  Future<String> addZone(ZoneType type, {String? mapId, Rect? rect}) async {
    final m = await _map(mapId);
    return jsonMap(
      await robot.api.post('/zones', {
        'map_id': m['id'],
        'name': type.label,
        'zone_type': type.name,
        'polygon': _polygon(m, rect ?? const Rect.fromLTWH(40, 40, 20, 20)),
        'rule': type == ZoneType.slow ? '限速 0.3 m/s' : '',
        'action': '停止并告警',
      }),
    )['id'];
  }

  @override
  Future<void> updateZone(Zone zone) async {
    final m = await _map(zone.mapId);
    // 当前编辑器只支持矩形；避免把任意多边形悄悄改成外包矩形。
    final rows = jsonRows(
      await robot.api.get('/zones', query: {'map_id': zone.mapId}),
    );
    final original =
        rows.firstWhere((z) => z['id'] == zone.id)['polygon'] as List;
    final bounds = _rect(m, original);
    final corners = [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomRight,
      bounds.bottomLeft,
    ];
    if (original.length != 4 ||
        original.any(
          (p) => !corners.any((c) => (c - _percent(m, p)).distance < 0.0001),
        )) {
      throw StateError('该围栏为多边形，当前编辑器仅支持矩形');
    }
    await robot.api.patch('/zones/${Uri.encodeComponent(zone.id)}', {
      'name': zone.name,
      'polygon': _polygon(m, zone.rect),
      'rule': zone.rule,
      'scope': zone.scope,
      'schedule': zone.schedule,
      'action': zone.action,
    });
  }

  @override
  Future<void> deleteZone(String id) async {
    await robot.api.delete('/zones/${Uri.encodeComponent(id)}');
  }
}
