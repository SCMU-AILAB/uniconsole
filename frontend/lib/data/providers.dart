import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mock/mock_repositories.dart';
import 'models/models.dart';
import 'repositories/repositories.dart';

// ---- Repository（接真实后端时在 ProviderScope 里 override） ----

final deviceRepositoryProvider = Provider<DeviceRepository>(
  (ref) => MockDeviceRepository(),
);
final alertRepositoryProvider = Provider<AlertRepository>(
  (ref) => MockAlertRepository(),
);
final fleetRepositoryProvider = Provider<FleetRepository>(
  (ref) => MockFleetRepository(),
);
final leaseRepositoryProvider = Provider<LeaseRepository>(
  (ref) => MockLeaseRepository(),
);
final memberRepositoryProvider = Provider<MemberRepository>(
  (ref) => MockMemberRepository(),
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
final leasesProvider = StreamProvider<List<Lease>>(
  (ref) => ref.watch(leaseRepositoryProvider).watchLeases(),
);
final membersProvider = StreamProvider<List<Member>>(
  (ref) => ref.watch(memberRepositoryProvider).watchMembers(),
);
final currentUserProvider = StreamProvider<Member>(
  (ref) => ref.watch(memberRepositoryProvider).watchCurrentUser(),
);

/// 导航上的计数与统计，全部从同一数据源计算（HANDOFF.md §8.5）。
class FleetSummary {
  const FleetSummary({
    required this.total,
    required this.online,
    required this.openAlerts,
    required this.activeAlerts,
    required this.fleetSessions,
    required this.controlSessions,
    required this.pendingLeaseRequests,
    required this.groupCounts,
  });

  final int total;
  final int online;

  /// 未处理的告警（侧边栏、标签栏徽标）。
  final int openAlerts;

  /// 未关闭的告警（未处理 + 处理中）。
  final int activeAlerts;
  final int fleetSessions;

  /// 有人或会话持有控制权的设备数。
  final int controlSessions;
  final int pendingLeaseRequests;
  final Map<String, int> groupCounts;

  int get offline => total - online;

  static const empty = FleetSummary(
    total: 0,
    online: 0,
    openAlerts: 0,
    activeAlerts: 0,
    fleetSessions: 0,
    controlSessions: 0,
    pendingLeaseRequests: 0,
    groupCounts: {},
  );
}

final fleetSummaryProvider = Provider<FleetSummary>((ref) {
  final devices = ref.watch(devicesProvider).value ?? const [];
  final alerts = ref.watch(alertsProvider).value ?? const [];
  final sessions = ref.watch(fleetSessionsProvider).value ?? const [];
  final leases = ref.watch(leasesProvider).value ?? const [];
  final groups = <String, int>{};
  for (final d in devices) {
    groups.update(d.groupId, (n) => n + 1, ifAbsent: () => 1);
  }
  return FleetSummary(
    total: devices.length,
    online: devices.where((d) => d.status.isOnline).length,
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
    groupCounts: groups,
  );
});
