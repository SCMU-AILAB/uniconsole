import '../models/models.dart';

/// 数据访问接口。界面只依赖这些接口；接真实后端（../server/docs/API.md，
/// REST /api/v1 + WebSocket /api/v1/ws）时只替换实现。

abstract interface class DeviceRepository {
  Stream<List<Device>> watchDevices();

  Stream<List<DeviceGroup>> watchGroups();
}

abstract interface class AlertRepository {
  Stream<List<Alert>> watchAlerts();
}

abstract interface class FleetRepository {
  /// 正在进行的联调会话。
  Stream<List<FleetSession>> watchSessions();
}

abstract interface class LeaseRepository {
  Stream<List<Lease>> watchLeases();
}

abstract interface class MemberRepository {
  Stream<List<Member>> watchMembers();

  /// 当前登录的成员。
  Stream<Member> watchCurrentUser();
}
