import '../models/models.dart';

/// 数据访问接口。界面只依赖这些接口；接真实后端（../server/docs/API.md，
/// REST /api/v1 + WebSocket /api/v1/ws）时只替换实现。

abstract interface class DeviceRepository {
  /// `GET /devices`，之后由 WS `device_status` 增量更新。
  Stream<List<Device>> watchDevices();

  Stream<List<DeviceGroup>> watchGroups();

  /// 设备最近事件（WS `robot_event`、状态变化、控制权变化），新的在前。
  Stream<List<DeviceEvent>> watchEvents(String deviceId);
}

abstract interface class TelemetryRepository {
  /// WS 订阅 `{"type":"subscribe","device_ids":[id]}` 后的 `telemetry` 消息。
  /// 取消订阅即 `unsubscribe`。
  Stream<Telemetry> watch(String deviceId);
}

abstract interface class SensorRepository {
  /// 点云帧（第一版走 WebRTC 数据通道；API 未定，先按 10 Hz 推送）。
  Stream<PointCloudFrame> watchPointCloud(String deviceId);

  /// 摄像头与话题健康（`devices.meta` + 遥测统计）。
  Stream<SensorStatus> watchStatus(String deviceId);
}

abstract interface class ControlRepository {
  /// 高频移动（WS `move`，10–20 Hz）。不等回执。
  void move(String deviceId, double vx, double vy, double wz);

  /// WS `stop`。
  void stop(String deviceId);

  /// 普通指令（`POST /devices/{id}/commands`，等待回执）。
  Future<CommandResult> send(String deviceId, DeviceCommand command);

  /// `GET /devices/{id}/commands`，新的在前。
  Stream<List<CommandLogEntry>> watchLog(String deviceId);

  /// 单机急停状态（WS `estop` 事件）。
  Stream<bool> watchEstop(String deviceId);

  /// `POST /devices/{id}/estop {active}`。
  Future<void> setEstop(String deviceId, {required bool active});
}

abstract interface class AlertRepository {
  Stream<List<Alert>> watchAlerts();
}

abstract interface class FleetRepository {
  /// 正在进行的联调会话（`GET /fleet-sessions`）。
  Stream<List<FleetSession>> watchSessions();

  Stream<List<FleetPreset>> watchPresets();

  /// 按预设发起会话（`POST /fleet-sessions` + `/start`）：一次性获取所有设备的
  /// 租约，任一设备不可用则整体失败（抛出 [FleetException]）。返回会话 id。
  Future<String> start({String? presetId, List<String> deviceIds = const []});

  /// 加入 / 移出设备（`PATCH /fleet-sessions/{id}` 的 `device_ids`）。
  /// 加入时会话接管该设备的控制权；设备不可用时抛出 [FleetException]。
  Future<void> setParticipant(
    String sessionId,
    String deviceId, {
    required bool joined,
  });

  Future<void> setFormation(String sessionId, Formation formation);

  /// `POST /fleet-sessions/{id}/commands`：发给会话中的全部设备，返回各设备回执。
  Future<FleetReceipt> send(
    String sessionId,
    DeviceCommand command, {
    required String label,
  });

  /// 把当前设备组合与队形保存为预设。
  Future<void> savePreset(String sessionId, String name);

  /// `POST /fleet-sessions/{id}/stop`：全部停止并释放租约。
  Future<void> end(String sessionId);
}

enum LeaseRequestResult { granted, queued }

abstract interface class LeaseRepository {
  Stream<List<Lease>> watchLeases();

  /// `POST /devices/{id}/lease`：空闲时直接获得，否则进入申请队列。
  Future<LeaseRequestResult> acquire(String deviceId, {String? reason});

  /// `DELETE /devices/{id}/lease`。
  Future<void> release(String deviceId);

  /// `DELETE /devices/{id}/lease?force=true`：管理者强制收回，需填写原因。
  Future<void> forceRelease(String deviceId, {required String reason});

  /// `POST /devices/{id}/lease/renew`（剩余 1/3 时自动续约）。
  Future<void> renew(String deviceId);

  /// `POST /devices/{id}/lease/transfer`。
  Future<void> transfer(String deviceId, LeaseTarget target, {String? note});

  /// `POST /lease-requests/{id}/approve`：控制权转移给申请人。
  Future<void> approve(String deviceId, String requestId);

  /// `POST /lease-requests/{id}/deny`。
  Future<void> deny(String deviceId, String requestId);
}

abstract interface class SafetyRepository {
  /// `GET /safety`，之后由 WS `estop`（device_id 为 null）更新。
  Stream<SafetyState> watchSafety();

  /// `POST /safety/estop {active}`：任何人可触发；按策略解除需管理者。
  Future<void> setGlobalEstop({required bool active});

  /// `PATCH /safety/policies`。
  Future<void> updatePolicies(SafetyPolicies policies);

  /// 急停演练：向所有在线设备下发演练急停并测量响应时间（设备不会真正停机）。
  Future<DrillResult> runDrill();

  Stream<SiteMap> watchMap();

  /// `GET /zones?map_id=`。
  Stream<List<Zone>> watchZones();

  /// `POST /zones`，返回新围栏 id。
  Future<String> addZone(ZoneType type);

  /// `PATCH /zones/{id}`。
  Future<void> updateZone(Zone zone);

  /// `DELETE /zones/{id}`。
  Future<void> deleteZone(String id);
}

abstract interface class MemberRepository {
  Stream<List<Member>> watchMembers();

  /// 当前登录的成员。
  Stream<Member> watchCurrentUser();
}
