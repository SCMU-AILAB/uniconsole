import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

/// 断联后动作（Safety.dc.html「断联处理」）。
enum LostLinkAction {
  stop('原地停止'),
  down('原地趴下'),
  dock('返回充电桩');

  const LostLinkAction(this.label);

  final String label;
}

/// 控制租约过期且无人续约时的处理。
enum LeaseExpiryAction {
  stopRelease('停止并释放'),
  stopOnly('仅停止');

  const LeaseExpiryAction(this.label);

  final String label;
}

/// `GET /safety` 的 `policies`；`PATCH /safety/policies` 局部更新。
@immutable
class SafetyPolicies {
  const SafetyPolicies({
    this.autoDock = true,
    this.dockThreshold = 20,
    this.heartbeatTimeout = const Duration(milliseconds: 1500),
    this.lostLinkAction = LostLinkAction.stop,
    this.leaseExpiryAction = LeaseExpiryAction.stopRelease,
    this.speedLimit = 1.5,
    this.stopNearPeople = true,
    this.minDistance = 0.8,
    this.fallDetection = true,
    this.collisionDetection = true,
    this.cliffDetection = true,
    this.releaseNeedsManager = true,
    this.hardwareRemotes = 2,
    this.leaseTerm = const Duration(minutes: 5),
    this.idleRelease = const Duration(minutes: 10),
    this.disconnectStop = const Duration(seconds: 3),
    this.disconnectRelease = const Duration(seconds: 60),
  });

  /// 低电量自动回桩。
  final bool autoDock;

  /// 回桩阈值（%）。
  final int dockThreshold;
  final Duration heartbeatTimeout;
  final LostLinkAction lostLinkAction;
  final LeaseExpiryAction leaseExpiryAction;

  /// 全局限速 m/s。
  final double speedLimit;
  final bool stopNearPeople;

  /// 设备间最小距离（米），联调与编队时生效。
  final double minDistance;
  final bool fallDetection;
  final bool collisionDetection;
  final bool cliffDetection;

  /// 急停解除需管理者确认。
  final bool releaseNeedsManager;

  /// 已配对的硬件急停遥控器数量。
  final int hardwareRemotes;

  // ---- 控制权规则（Lease.dc.html「租约规则」） ----
  final Duration leaseTerm;
  final Duration idleRelease;
  final Duration disconnectStop;
  final Duration disconnectRelease;

  SafetyPolicies copyWith({
    bool? autoDock,
    int? dockThreshold,
    Duration? heartbeatTimeout,
    LostLinkAction? lostLinkAction,
    LeaseExpiryAction? leaseExpiryAction,
    double? speedLimit,
    bool? stopNearPeople,
    double? minDistance,
    bool? fallDetection,
    bool? collisionDetection,
    bool? cliffDetection,
    bool? releaseNeedsManager,
  }) => SafetyPolicies(
    autoDock: autoDock ?? this.autoDock,
    dockThreshold: dockThreshold ?? this.dockThreshold,
    heartbeatTimeout: heartbeatTimeout ?? this.heartbeatTimeout,
    lostLinkAction: lostLinkAction ?? this.lostLinkAction,
    leaseExpiryAction: leaseExpiryAction ?? this.leaseExpiryAction,
    speedLimit: speedLimit ?? this.speedLimit,
    stopNearPeople: stopNearPeople ?? this.stopNearPeople,
    minDistance: minDistance ?? this.minDistance,
    fallDetection: fallDetection ?? this.fallDetection,
    collisionDetection: collisionDetection ?? this.collisionDetection,
    cliffDetection: cliffDetection ?? this.cliffDetection,
    releaseNeedsManager: releaseNeedsManager ?? this.releaseNeedsManager,
    hardwareRemotes: hardwareRemotes,
    leaseTerm: leaseTerm,
    idleRelease: idleRelease,
    disconnectStop: disconnectStop,
    disconnectRelease: disconnectRelease,
  );
}

/// `GET /safety`。
@immutable
class SafetyState {
  const SafetyState({
    this.globalEstop = false,
    this.estopBy,
    this.estopAt,
    this.lastDrillAt,
    this.policies = const SafetyPolicies(),
  });

  final bool globalEstop;

  /// 触发全局急停的成员名。
  final String? estopBy;
  final DateTime? estopAt;
  final DateTime? lastDrillAt;
  final SafetyPolicies policies;

  SafetyState copyWith({
    bool? globalEstop,
    String? estopBy,
    DateTime? estopAt,
    DateTime? lastDrillAt,
    SafetyPolicies? policies,
  }) => SafetyState(
    globalEstop: globalEstop ?? this.globalEstop,
    estopBy: estopBy ?? this.estopBy,
    estopAt: estopAt ?? this.estopAt,
    lastDrillAt: lastDrillAt ?? this.lastDrillAt,
    policies: policies ?? this.policies,
  );
}

/// API zone type。
enum ZoneType {
  ban('禁入区'),
  slow('限速区'),
  whitelist('白名单区'),
  wall('虚拟墙');

  const ZoneType(this.label);

  final String label;
}

/// HANDOFF.md §6 Zone。坐标为地图上 0–100 的百分比（与 FloorMapView 一致），
/// 目前只编辑矩形围栏；API 的 polygon 由 [polygon] 给出。
@immutable
class Zone {
  const Zone({
    required this.id,
    required this.mapId,
    required this.name,
    required this.type,
    required this.rect,
    required this.rule,
    required this.scope,
    required this.schedule,
    required this.action,
  });

  final String id;
  final String mapId;
  final String name;
  final ZoneType type;
  final Rect rect;
  final String rule;

  /// 生效设备。
  final String scope;

  /// 生效时间。
  final String schedule;

  /// 触发后。
  final String action;

  List<Offset> get polygon => [
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
  ];

  Zone copyWith({Rect? rect, String? name}) => Zone(
    id: id,
    mapId: mapId,
    name: name ?? this.name,
    type: type,
    rect: rect ?? this.rect,
    rule: rule,
    scope: scope,
    schedule: schedule,
    action: action,
  );
}

/// 平面地图的尺寸与名称（围栏面积按此换算）。
@immutable
class SiteMap {
  const SiteMap({
    required this.id,
    required this.name,
    String? shortName,
    required this.widthMeters,
    required this.heightMeters,
    this.devicePositions = const {},
    this.deviceHeadings = const {},
    this.areas = const [],
    this.chargers = const [],
    this.resolutionCm = 5,
    this.updatedAt,
  }) : shortName = shortName ?? name;

  final String id;
  final String name;

  /// 地图切换器上的短名（Missions.dc.html「B 区巡检层」）。
  final String shortName;
  final double widthMeters;
  final double heightMeters;

  /// 设备在该地图上的最新位置（百分比坐标，来自定位）。
  final Map<String, Offset> devicePositions;

  /// 设备朝向（弧度，0 = 朝上，π/2 = 朝右）。
  final Map<String, double> deviceHeadings;

  /// 外墙与房间（建图结果）。
  final List<MapArea> areas;

  /// 充电桩位置（百分比坐标）。
  final List<Offset> chargers;
  final int resolutionCm;

  /// 最近一次建图时间。
  final DateTime? updatedAt;

  /// 百分比坐标换算成米。
  Offset toMeters(Offset percent) =>
      Offset(percent.dx / 100 * widthMeters, percent.dy / 100 * heightMeters);

  /// 两点间的实际距离（m）。
  double distance(Offset a, Offset b) => (toMeters(a) - toMeters(b)).distance;

  SiteMap copyWith({List<Offset>? chargers, DateTime? updatedAt}) => SiteMap(
    id: id,
    name: name,
    shortName: shortName,
    widthMeters: widthMeters,
    heightMeters: heightMeters,
    devicePositions: devicePositions,
    deviceHeadings: deviceHeadings,
    areas: areas,
    chargers: chargers ?? this.chargers,
    resolutionCm: resolutionCm,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// 百分比矩形对应的面积（m²）。
  double areaOf(Rect percentRect) =>
      percentRect.width /
      100 *
      widthMeters *
      percentRect.height /
      100 *
      heightMeters;
}

/// 建图得到的墙体与房间（百分比矩形）：外墙只画边线，房间画成不可通行的灰底。
@immutable
class MapArea {
  const MapArea(this.rect, {this.label, this.outline = false});

  final Rect rect;
  final String? label;

  /// 只画墙体（外墙），不填充。
  final bool outline;
}

/// 急停演练结果：各设备从下发到确认停止的耗时。
@immutable
class DrillResult {
  const DrillResult({required this.at, required this.responses});

  final DateTime at;
  final Map<String, Duration> responses;

  Duration get slowest =>
      responses.values.fold(Duration.zero, (a, b) => a > b ? a : b);
}
