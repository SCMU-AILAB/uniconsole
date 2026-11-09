import 'dart:ui' show Offset, Rect;

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
  /// `GET /alerts`，之后由 WS `alert` 增量更新。新的在前。
  Stream<List<Alert>> watchAlerts();

  /// 触发前 30 分钟的指标曲线（`GET /devices/{id}/telemetry?from=&to=`）。
  Future<AlertHistory> history(String alertId);

  /// `PATCH /alerts/{id} {state: doing}`：当前用户确认并成为处理人。
  Future<void> acknowledge(String alertId);

  /// 指派给成员（状态变为处理中）。
  Future<void> assign(String alertId, String memberId);

  /// `PATCH /alerts/{id} {state: closed, note}`：关闭必须填写处理备注。
  Future<void> close(String alertId, {required String note});

  /// `PATCH /alerts/{id} {state: open}`。
  Future<void> reopen(String alertId);

  /// `POST /alerts/{id}/events {message}`。
  Future<void> addNote(String alertId, String message);

  /// 静默：期间不重复推送；[duration] 为 null 时取消静默。
  Future<void> silence(String alertId, Duration? duration);

  /// 远程趴下：经急停通道下发（不需要控制权，§8.1），并记入时间线。
  Future<void> remoteDown(String alertId);

  /// `GET /alert-rules`。
  Stream<List<AlertRule>> watchRules();

  /// `PATCH /alert-rules/{id} {enabled}`。
  Future<void> setRuleEnabled(String ruleId, {required bool enabled});

  /// `POST /alert-rules`，返回新规则 id。
  Future<String> addRule({
    required String name,
    required AlertMetric metric,
    required String op,
    required double threshold,
    required Duration duration,
    required AlertSeverity severity,
    String? autoAction,
  });

  Stream<List<NotifyChannel>> watchChannels();

  Stream<OnCallRoster> watchRoster();
}

abstract interface class MissionRepository {
  /// 建好的地图（Missions.dc.html 顶部地图切换）。
  Stream<List<SiteMap>> watchMaps();

  /// `GET /missions`。
  Stream<List<Mission>> watchMissions();

  /// 今日排期（各设备的任务、充电时段）。
  Stream<List<ScheduleBlock>> watchSchedule();

  /// `POST /missions`，返回新任务 id。
  Future<String> addMission(String name, String mapId);

  /// `PATCH /missions/{id} {state}`。
  Future<void> setState(String missionId, MissionState state);

  /// `PATCH /missions/{id} {waypoints}`：替换点位列表。
  Future<void> setWaypoints(String missionId, List<Waypoint> waypoints);

  /// 在地图上放置充电桩（重新建图时由机器人识别，这里允许手动标注）。
  Future<void> addCharger(String mapId, Offset position);

  /// 重新建图：由「地图更新」任务的设备执行，完成后更新地图时间。
  Future<void> remap(String mapId);
}

abstract interface class RecordingRepository {
  /// 录制库，新的在前。
  Stream<List<Recording>> watchRecordings();

  Stream<RecordingStorage> watchStorage();

  /// 回放用的曲线与轨迹。
  Future<RecordingSamples> samples(String recordingId);

  /// 剪辑片段：截取 [from]–[to] 另存为新录制，返回新 id。
  Future<String> clip(String recordingId, Duration from, Duration to);

  /// 导出，返回文件名。
  Future<String> export(String recordingId, ExportFormat format);

  /// 带时间点的分享链接。
  String shareLink(String recordingId, Duration at);
}

abstract interface class MaintenanceRepository {
  Stream<List<FirmwareStatus>> watchFirmware();

  Stream<FirmwareRelease> watchRelease();

  /// 灰度升级：先升级第一台，自检通过后其余并行；任务中的设备等任务结束，
  /// 离线设备上线后自动升级。
  Future<void> upgrade(List<String> deviceIds);

  /// 加入维护窗口。
  Future<void> schedule(List<String> deviceIds);

  /// 回滚到上一版本。
  Future<void> rollback(String deviceId);

  Future<void> reboot(String deviceId);

  Stream<List<BatteryHealth>> watchBattery();

  /// 各设备日志，新的在前。
  Stream<List<DeviceLogEntry>> watchLogs();

  Stream<MaintenanceWindow> watchWindow();

  Future<void> setWindow(MaintenanceWindow window);

  /// 导出诊断包，返回文件名。
  Future<String> exportDiagnostics(List<String> deviceIds);

  /// 远程终端（二次验证后；所有命令写入审计日志）。
  Future<List<TerminalLine>> run(String deviceId, String command);
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

  /// `GET /zones?map_id=`；[mapId] 为空时为安全策略页的地图。
  Stream<List<Zone>> watchZones({String? mapId});

  /// `POST /zones`，返回新围栏 id。[rect] 为空时放在地图中央。
  Future<String> addZone(ZoneType type, {String? mapId, Rect? rect});

  /// `PATCH /zones/{id}`。
  Future<void> updateZone(Zone zone);

  /// `DELETE /zones/{id}`。
  Future<void> deleteZone(String id);
}

/// 登录与会话（API「认证」）。
///
/// 登录态由服务端会话管理：退出、被踢下线、停用账号都会让令牌立即失效，
/// 之后任何请求返回 401，此时实现应清掉会话（[watchSession] 推送 null），界面回到登录页。
abstract interface class AuthRepository {
  /// 当前会话；未登录为 null。启动时从系统钥匙串恢复。
  AuthSession? get session;

  Stream<AuthSession?> watchSession();

  /// 上次登录用的服务器地址，登录页预填。
  String get lastServer;

  /// `POST /auth/login {handle, password, code?, device_name?}`。
  /// 失败时抛 [AuthException]；`two_factor_required` 表示要带 [code] 再提交一次。
  Future<AuthSession> login({
    required String server,
    required String handle,
    required String password,
    String? code,
  });

  /// `POST /auth/logout`：吊销当前会话。
  Future<void> logout();

  /// `GET /auth/invites/{token}`；无效或过期抛 `not_found`。
  /// 邀请链接不带服务器地址，[server] 为空时用 [lastServer]。
  Future<InviteInfo> invite(String token, {String? server});

  /// `POST /auth/invites/{token}/accept {password}`：设置密码并直接登录。
  Future<AuthSession> acceptInvite(
    String token,
    String password, {
    String? server,
  });

  /// `POST /auth/register/code {email}`：向邮箱发 6 位验证码（10 分钟有效）。
  /// 返回多久之后可以重新获取。邮箱已注册抛 `conflict`，太频繁抛 `too_many_requests`。
  Future<Duration> requestRegisterCode({
    required String server,
    required String email,
  });

  /// `POST /auth/register`：校验验证码，创建观察者账号并直接登录。
  /// 角色由管理员之后在「成员与权限」里调整。
  Future<AuthSession> register({
    required String server,
    required RegisterDraft draft,
  });
}

/// 成员与权限（API §1 认证与成员）。违反规则时抛 [MemberException]。
abstract interface class MemberRepository {
  /// `GET /members`。
  Stream<List<Member>> watchMembers();

  /// 当前登录的成员（`GET /auth/me`）。
  Stream<Member> watchCurrentUser();

  /// `POST /members`（管理员，不传密码）→ 一次性邀请链接，7 天有效。
  Future<MemberInvite> invite(MemberDraft draft);

  /// `POST /members/{id}/invite`：重新生成邀请链接，旧链接作废。
  Future<MemberInvite> reissueInvite(String id);

  /// `PATCH /members/{id}` + `PUT /members/{id}/devices`。
  Future<void> update(
    String id, {
    MemberRole? role,
    DateTime? expiresAt,
    bool clearExpiry = false,
    List<String>? grantedDeviceIds,
    bool? videoOnly,
    bool? disabled,
  });

  /// `DELETE /members/{id}`。
  Future<void> remove(String id);

  /// `GET /audit`，按时间倒序。
  Stream<List<AuditEntry>> watchAudit();

  /// 导出审计日志 CSV → 文件名。
  Future<String> exportAudit();
}

class MemberException implements Exception {
  const MemberException(this.code, this.message);

  /// API 错误码：forbidden、conflict、bad_request。
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 智能体（Agent.dc.html）。服务端接口尚未定义，先按界面需要抽象：
/// 用户发送自然语言 → 智能体回复文字或执行计划；计划需确认后才执行（HANDOFF §8.3）。
abstract interface class AgentRepository {
  /// 当前对话。
  Stream<Conversation> watchConversation();

  /// 历史对话（不含消息正文以外的状态）。
  Stream<List<Conversation>> watchHistory();

  Future<void> openConversation(String id);
  Future<void> newConversation();

  Future<void> send(String text);

  /// 输入框上方的 @设备 / 地图标签。
  Future<void> setContext({List<String>? deviceIds, String? mapId});

  /// 确认执行计划。
  Future<void> runPlan(String planId);

  /// 中止计划并停止计划内的所有设备。
  Future<void> abortPlan(String planId);

  /// 放弃等待确认的计划。
  Future<void> cancelPlan(String planId);

  Stream<List<AgentSkill>> watchSkills();
  Future<void> setSkillMode(String name, SkillMode mode);
}

/// 实时对讲与文字转语音播报。
abstract interface class IntercomRepository {
  Stream<List<IntercomTarget>> watchTargets();
  Stream<IntercomState> watchState();
  Future<void> setTarget(String targetId);

  /// 按住说话：开始 / 结束上行音频。
  Future<void> startTalking();
  Future<void> stopTalking();
  Future<void> setListening(bool listening);

  /// 播报到当前对象，返回实际播放的设备数。
  Future<int> broadcast(String text);
}

/// 账户偏好与客户端信息（设置页）。
abstract interface class PreferencesRepository {
  Stream<Preferences> watchPreferences();
  Future<void> update(Preferences Function(Preferences) change);

  Stream<GamepadInfo?> watchGamepad();
  Stream<List<SignedInClient>> watchClients();
  Future<void> signOut(String clientId);
  Stream<List<ApiToken>> watchTokens();
  Future<void> revokeToken(String id);
}
