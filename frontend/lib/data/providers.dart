import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mock/mock_repositories.dart';
import 'models/models.dart';
import 'repositories/repositories.dart';

// ---- Repository（接真实后端时在 ProviderScope 里 override） ----

/// mock 世界：所有 mock 仓库共享的状态。测试可 override 以调整遥测频率。
final mockWorldProvider = Provider<MockWorld>((ref) {
  final world = MockWorld();
  ref.onDispose(world.dispose);
  return world;
});

final deviceRepositoryProvider = Provider<DeviceRepository>(
  (ref) => ref.watch(mockWorldProvider).devices,
);
final alertRepositoryProvider = Provider<AlertRepository>(
  (ref) => ref.watch(mockWorldProvider).alerts,
);
final fleetRepositoryProvider = Provider<FleetRepository>(
  (ref) => ref.watch(mockWorldProvider).sessions,
);
final leaseRepositoryProvider = Provider<LeaseRepository>(
  (ref) => ref.watch(mockWorldProvider).leases,
);
final memberRepositoryProvider = Provider<MemberRepository>(
  (ref) => ref.watch(mockWorldProvider).members,
);
final telemetryRepositoryProvider = Provider<TelemetryRepository>(
  (ref) => ref.watch(mockWorldProvider).fleet,
);
final controlRepositoryProvider = Provider<ControlRepository>(
  (ref) => ref.watch(mockWorldProvider).fleet,
);
final sensorRepositoryProvider = Provider<SensorRepository>(
  (ref) => ref.watch(mockWorldProvider).fleet,
);
final safetyRepositoryProvider = Provider<SafetyRepository>(
  (ref) => ref.watch(mockWorldProvider).safety,
);
final missionRepositoryProvider = Provider<MissionRepository>(
  (ref) => ref.watch(mockWorldProvider).missions,
);
final recordingRepositoryProvider = Provider<RecordingRepository>(
  (ref) => ref.watch(mockWorldProvider).recordings,
);
final maintenanceRepositoryProvider = Provider<MaintenanceRepository>(
  (ref) => ref.watch(mockWorldProvider).maintenance,
);

// ---- 数据流 ----

final devicesProvider = StreamProvider<List<Device>>(
  (ref) => ref.watch(deviceRepositoryProvider).watchDevices(),
);
final deviceGroupsProvider = StreamProvider<List<DeviceGroup>>(
  (ref) => ref.watch(deviceRepositoryProvider).watchGroups(),
);
final alertsProvider = StreamProvider<List<Alert>>(
  (ref) => ref.watch(alertRepositoryProvider).watchAlerts(),
);
final fleetSessionsProvider = StreamProvider<List<FleetSession>>(
  (ref) => ref.watch(fleetRepositoryProvider).watchSessions(),
);
final fleetPresetsProvider = StreamProvider<List<FleetPreset>>(
  (ref) => ref.watch(fleetRepositoryProvider).watchPresets(),
);
final safetyProvider = StreamProvider<SafetyState>(
  (ref) => ref.watch(safetyRepositoryProvider).watchSafety(),
);
final siteMapProvider = StreamProvider<SiteMap>(
  (ref) => ref.watch(safetyRepositoryProvider).watchMap(),
);
final zonesProvider = StreamProvider<List<Zone>>(
  (ref) => ref.watch(safetyRepositoryProvider).watchZones(),
);
final alertRulesProvider = StreamProvider<List<AlertRule>>(
  (ref) => ref.watch(alertRepositoryProvider).watchRules(),
);
final notifyChannelsProvider = StreamProvider<List<NotifyChannel>>(
  (ref) => ref.watch(alertRepositoryProvider).watchChannels(),
);
final onCallRosterProvider = StreamProvider<OnCallRoster>(
  (ref) => ref.watch(alertRepositoryProvider).watchRoster(),
);
final mapsProvider = StreamProvider<List<SiteMap>>(
  (ref) => ref.watch(missionRepositoryProvider).watchMaps(),
);
final missionsProvider = StreamProvider<List<Mission>>(
  (ref) => ref.watch(missionRepositoryProvider).watchMissions(),
);
final scheduleProvider = StreamProvider<List<ScheduleBlock>>(
  (ref) => ref.watch(missionRepositoryProvider).watchSchedule(),
);
final recordingsProvider = StreamProvider<List<Recording>>(
  (ref) => ref.watch(recordingRepositoryProvider).watchRecordings(),
);
final recordingStorageProvider = StreamProvider<RecordingStorage>(
  (ref) => ref.watch(recordingRepositoryProvider).watchStorage(),
);
final firmwareProvider = StreamProvider<List<FirmwareStatus>>(
  (ref) => ref.watch(maintenanceRepositoryProvider).watchFirmware(),
);
final firmwareReleaseProvider = StreamProvider<FirmwareRelease>(
  (ref) => ref.watch(maintenanceRepositoryProvider).watchRelease(),
);
final batteryHealthProvider = StreamProvider<List<BatteryHealth>>(
  (ref) => ref.watch(maintenanceRepositoryProvider).watchBattery(),
);
final deviceLogsProvider = StreamProvider<List<DeviceLogEntry>>(
  (ref) => ref.watch(maintenanceRepositoryProvider).watchLogs(),
);
final maintenanceWindowProvider = StreamProvider<MaintenanceWindow>(
  (ref) => ref.watch(maintenanceRepositoryProvider).watchWindow(),
);
final leasesProvider = StreamProvider<List<Lease>>(
  (ref) => ref.watch(leaseRepositoryProvider).watchLeases(),
);
final membersProvider = StreamProvider<List<Member>>(
  (ref) => ref.watch(memberRepositoryProvider).watchMembers(),
);
final currentUserProvider = StreamProvider<Member>(
  (ref) => ref.watch(memberRepositoryProvider).watchCurrentUser(),
);

/// 单台设备。
final deviceProvider = Provider.family<Device?, String>(
  (ref, id) =>
      ref.watch(devicesProvider).value?.where((d) => d.id == id).firstOrNull,
);

final deviceEventsProvider = StreamProvider.autoDispose
    .family<List<DeviceEvent>, String>(
      (ref, id) => ref.watch(deviceRepositoryProvider).watchEvents(id),
    );

/// 实时遥测：只在页面订阅期间推送（离开页面即取消订阅，对应 WS `unsubscribe`）。
final telemetryProvider = StreamProvider.autoDispose.family<Telemetry, String>(
  (ref, id) => ref.watch(telemetryRepositoryProvider).watch(id),
);

/// 最近 10 秒遥测（图表用）。
final telemetryHistoryProvider = NotifierProvider.autoDispose
    .family<TelemetryHistory, List<Telemetry>, String>(TelemetryHistory.new);

class TelemetryHistory extends Notifier<List<Telemetry>> {
  TelemetryHistory(this.deviceId);

  final String deviceId;
  static const window = Duration(seconds: 10);
  final _buffer = Queue<Telemetry>();

  @override
  List<Telemetry> build() {
    ref.listen(telemetryProvider(deviceId), (_, next) {
      final t = next.value;
      if (t == null) return;
      _buffer.addLast(t);
      while (_buffer.isNotEmpty && t.ts.difference(_buffer.first.ts) > window) {
        _buffer.removeFirst();
      }
      state = List.unmodifiable(_buffer);
    });
    return const [];
  }
}

final pointCloudProvider = StreamProvider.autoDispose
    .family<PointCloudFrame, String>(
      (ref, id) => ref.watch(sensorRepositoryProvider).watchPointCloud(id),
    );

final sensorStatusProvider = StreamProvider.autoDispose
    .family<SensorStatus, String>(
      (ref, id) => ref.watch(sensorRepositoryProvider).watchStatus(id),
    );

final commandLogProvider = StreamProvider.autoDispose
    .family<List<CommandLogEntry>, String>(
      (ref, id) => ref.watch(controlRepositoryProvider).watchLog(id),
    );

final estopProvider = StreamProvider.autoDispose.family<bool, String>(
  (ref, id) => ref.watch(controlRepositoryProvider).watchEstop(id),
);

/// 设备当前的租约（无人控制时为 null）。
final leaseProvider = Provider.family<Lease?, String>(
  (ref, id) => ref
      .watch(leasesProvider)
      .value
      ?.where((l) => l.deviceId == id)
      .firstOrNull,
);

/// 当前用户是否持有该设备的控制权（§8.2：没有控制权时操控页只读）。
final holdsLeaseProvider = Provider.family<bool, String>((ref, id) {
  final lease = ref.watch(leaseProvider(id));
  final me = ref.watch(currentUserProvider).value;
  return lease != null &&
      me != null &&
      lease.holderKind == LeaseHolderKind.user &&
      lease.holderId == me.id;
});

/// 成员显示名。
final memberNameProvider = Provider.family<String?, String?>((ref, id) {
  if (id == null) return null;
  return ref
      .watch(membersProvider)
      .value
      ?.where((m) => m.id == id)
      .firstOrNull
      ?.name;
});

/// 单条告警。
final alertProvider = Provider.family<Alert?, String>(
  (ref, id) =>
      ref.watch(alertsProvider).value?.where((a) => a.id == id).firstOrNull,
);

/// 告警曲线（触发前 30 分钟）。
final alertHistoryProvider = FutureProvider.autoDispose
    .family<AlertHistory, String>(
      (ref, id) => ref.watch(alertRepositoryProvider).history(id),
    );

/// 某张地图上的围栏（地图与任务页）。
final mapZonesProvider = StreamProvider.autoDispose.family<List<Zone>, String>(
  (ref, mapId) => ref.watch(safetyRepositoryProvider).watchZones(mapId: mapId),
);

final recordingProvider = Provider.family<Recording?, String>(
  (ref, id) =>
      ref.watch(recordingsProvider).value?.where((r) => r.id == id).firstOrNull,
);

final recordingSamplesProvider = FutureProvider.autoDispose
    .family<RecordingSamples, String>(
      (ref, id) => ref.watch(recordingRepositoryProvider).samples(id),
    );

/// 每秒刷新一次的当前时间（租约倒计时、「已运行 18 分钟」）。
final clockProvider = StreamProvider.autoDispose<DateTime>(
  (ref) => Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()),
);

DateTime watchNow(Ref ref) => ref.watch(clockProvider).value ?? DateTime.now();

/// 单个联调会话。
final fleetSessionProvider = Provider.family<FleetSession?, String>(
  (ref, id) => ref
      .watch(fleetSessionsProvider)
      .value
      ?.where((s) => s.id == id)
      .firstOrNull,
);

/// 设备所在的联调会话。
final sessionOfDeviceProvider = Provider.family<FleetSession?, String>(
  (ref, deviceId) => ref
      .watch(fleetSessionsProvider)
      .value
      ?.where((s) => s.deviceIds.contains(deviceId))
      .firstOrNull,
);

/// 租约持有者的显示名：成员名、会话发起人或「任务调度」（Lease.dc.html「持有者」列）。
final leaseHolderNameProvider = Provider.family<String?, String>((ref, id) {
  final lease = ref.watch(leaseProvider(id));
  if (lease == null) return null;
  return switch (lease.holderKind) {
    LeaseHolderKind.user => ref.watch(memberNameProvider(lease.holderId)),
    LeaseHolderKind.session => ref.watch(
      memberNameProvider(
        ref.watch(fleetSessionProvider(lease.holderId))?.initiatorId,
      ),
    ),
    LeaseHolderKind.task => '任务调度',
  };
});

/// 当前用户能否处理该设备的控制权（转移、审批）：持有者、设备管理者或平台管理员。
final canManageLeaseProvider = Provider.family<bool, String>((ref, id) {
  final me = ref.watch(currentUserProvider).value;
  if (me == null) return false;
  if (me.role == MemberRole.admin) return true;
  if (ref.watch(deviceProvider(id))?.ownerId == me.id) return true;
  return ref.watch(holdsLeaseProvider(id));
});

/// 当前用户能否强制收回：设备管理者或平台管理员。
final canForceLeaseProvider = Provider.family<bool, String>((ref, id) {
  final me = ref.watch(currentUserProvider).value;
  if (me == null) return false;
  return me.role == MemberRole.admin ||
      ref.watch(deviceProvider(id))?.ownerId == me.id;
});

/// 当前用户能否操作联调会话：发起人或平台管理员。
final canOperateSessionProvider = Provider.family<bool, String>((ref, id) {
  final me = ref.watch(currentUserProvider).value;
  final s = ref.watch(fleetSessionProvider(id));
  if (me == null || s == null) return false;
  return s.initiatorId == me.id || me.role == MemberRole.admin;
});

/// 当前用户能否解除全局急停（安全策略「急停解除需管理者确认」）。
final canReleaseGlobalEstopProvider = Provider<bool>((ref) {
  final me = ref.watch(currentUserProvider).value;
  final policies = ref.watch(safetyProvider).value?.policies;
  if (me == null || policies == null) return false;
  return !policies.releaseNeedsManager ||
      me.role == MemberRole.admin ||
      me.role == MemberRole.owner;
});

/// 导航上的计数与统计，全部从同一数据源计算（HANDOFF.md §8.5）。
class FleetSummary {
  const FleetSummary({
    required this.total,
    required this.online,
    required this.alertDevices,
    required this.openAlerts,
    required this.activeAlerts,
    required this.fleetSessions,
    required this.controlSessions,
    required this.pendingLeaseRequests,
    required this.activeLeases,
    required this.groupCounts,
    required this.zones,
    required this.globalEstop,
  });

  final int total;
  final int online;

  /// 处于告警状态的设备（Main.dc.html「告警」统计卡）。
  final List<Device> alertDevices;

  /// 未处理的告警（侧边栏、标签栏徽标）。
  final int openAlerts;

  /// 未关闭的告警（未处理 + 处理中）。
  final int activeAlerts;
  final int fleetSessions;

  /// 有人正在使用的设备数（Main.dc.html「控制会话」）。
  final int controlSessions;
  final int pendingLeaseRequests;

  /// 由成员或联调会话持有的租约（Lease.dc.html「4 个活动租约」；任务待命的不计）。
  final int activeLeases;
  final Map<String, int> groupCounts;

  /// 生效中的围栏数。
  final int zones;
  final bool globalEstop;

  int get offline => total - online;
}

final fleetSummaryProvider = Provider<FleetSummary>((ref) {
  final devices = ref.watch(devicesProvider).value ?? const [];
  final alerts = ref.watch(alertsProvider).value ?? const [];
  final sessions = ref.watch(fleetSessionsProvider).value ?? const [];
  final leases = ref.watch(leasesProvider).value ?? const [];
  final zones = ref.watch(zonesProvider).value ?? const [];
  final safety = ref.watch(safetyProvider).value;
  final groups = <String, int>{};
  for (final d in devices) {
    groups.update(d.groupId, (n) => n + 1, ifAbsent: () => 1);
  }
  return FleetSummary(
    total: devices.length,
    online: devices.where((d) => d.status.isOnline).length,
    alertDevices: devices.where((d) => d.status == DeviceStatus.alert).toList(),
    openAlerts: alerts.where((a) => a.state == AlertState.open).length,
    activeAlerts: alerts.where((a) => a.state != AlertState.closed).length,
    fleetSessions: sessions.length,
    controlSessions: leases
        .where((l) => l.holderKind != LeaseHolderKind.task)
        .map(
          (l) =>
              l.holderKind == LeaseHolderKind.session ? l.holderId : l.deviceId,
        )
        .toSet()
        .length,
    pendingLeaseRequests: leases.fold(0, (n, l) => n + l.queue.length),
    activeLeases: leases
        .where((l) => l.holderKind != LeaseHolderKind.task)
        .length,
    groupCounts: groups,
    zones: zones.length,
    globalEstop: safety?.globalEstop ?? false,
  );
});
