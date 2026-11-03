import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_alerts.dart';
import 'mock_data.dart';
import 'mock_fleet.dart';
import 'mock_leases.dart';
import 'mock_maintenance.dart';
import 'mock_missions.dart';
import 'mock_recordings.dart';
import 'mock_safety.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

export 'mock_alerts.dart';
export 'mock_fleet.dart';
export 'mock_leases.dart';
export 'mock_maintenance.dart';
export 'mock_missions.dart';
export 'mock_recordings.dart';
export 'mock_safety.dart';

/// 所有 mock 仓库的集合，彼此之间共享状态（控制指令 → 模拟机器人 → 遥测、事件；
/// 控制权 ↔ 联调会话 ↔ 全局急停）。
class MockWorld {
  MockWorld({this.telemetryHz = 10, this.currentUserId = 'kanade'}) {
    devices = MockDeviceRepository();
    leases = MockLeaseRepository(world: this);
    fleet = MockRobotFleet(world: this);
    sessions = MockFleetRepository(world: this);
    safety = MockSafetyRepository(world: this);
    alerts = MockAlertRepository(world: this);
    missions = MockMissionRepository(world: this);
    maintenance = MockMaintenanceRepository(world: this);
  }

  final int telemetryHz;
  final String currentUserId;
  late final MockDeviceRepository devices;
  late final MockLeaseRepository leases;
  late final MockRobotFleet fleet;
  late final MockFleetRepository sessions;
  late final MockSafetyRepository safety;
  late final MockAlertRepository alerts;
  late final MockMissionRepository missions;
  late final MockMaintenanceRepository maintenance;
  final recordings = MockRecordingRepository();
  final members = MockMemberRepository();

  Member get me => MockData.members.firstWhere((m) => m.id == currentUserId);

  String nameOf(String userId) =>
      MockData.members.where((m) => m.id == userId).firstOrNull?.name ?? userId;

  /// 停止 mock 内部的定时器（租约到期检查、固件升级进度、建图）。
  void dispose() {
    leases.dispose();
    missions.dispose();
    maintenance.dispose();
  }
}

class MockDeviceRepository implements DeviceRepository {
  final _devices = MockStore<List<Device>>(MockData.devices);
  final _groups = MockStore<List<DeviceGroup>>(MockData.groups);
  late final Map<String, MockStore<List<DeviceEvent>>> _events = {
    for (final d in MockData.devices)
      d.id: MockStore([
        for (final (ago, text, tone)
            in MockSeed.events[d.id] ?? const <(Duration, String, EventTone)>[])
          DeviceEvent(
            deviceId: d.id,
            at: MockSeed.ago(ago),
            text: text,
            tone: tone,
          ),
      ]),
  };

  Device? device(String id) =>
      _devices.value.where((d) => d.id == id).firstOrNull;

  void update(String id, Device Function(Device) f) {
    _devices.value = [for (final d in _devices.value) d.id == id ? f(d) : d];
  }

  void addEvent(String deviceId, String text, EventTone tone) {
    final store = _events[deviceId];
    if (store == null) return;
    store.value = [
      DeviceEvent(
        deviceId: deviceId,
        at: DateTime.now(),
        text: text,
        tone: tone,
      ),
      ...store.value,
    ];
  }

  @override
  Stream<List<Device>> watchDevices() => _devices.watch();

  @override
  Stream<List<DeviceGroup>> watchGroups() => _groups.watch();

  @override
  Stream<List<DeviceEvent>> watchEvents(String deviceId) =>
      _events[deviceId]?.watch() ?? Stream.value(const []);
}

class MockMemberRepository implements MemberRepository {
  final _members = MockStore<List<Member>>(MockData.members);

  @override
  Stream<List<Member>> watchMembers() => _members.watch();

  @override
  Stream<Member> watchCurrentUser() => _members.watch().map((m) => m.first);
}

/// 模拟的机器人：按 [MockWorld.telemetryHz] 推送遥测，响应移动 / 模式 / 急停指令。
///
/// 与真实机器人一致：300 ms 内收不到 `move` 即自动停止（API §2 看门狗）；
/// 任务中的设备在无人操控时按巡检路线自主行走。
class MockRobot {
  MockRobot(this.device, {required this.hz})
    : battery = device.battery.toDouble(),
      mode = MockSeed.modeFor(device.status),
      joints = MockSeed.jointsFor(device.id, device.maxMotorTemp ?? 40),
      _rnd = math.Random(device.id.hashCode);

  final Device device;
  final int hz;
  final math.Random _rnd;

  double battery;
  MotionMode mode;
  SpeedLevel speed = SpeedLevel.normal;
  bool estop = false;
  final List<List<double>> joints;

  double _vx = 0, _vy = 0, _wz = 0;
  double _cvx = 0, _cvy = 0, _cwz = 0;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOperator = DateTime.fromMillisecondsSinceEpoch(0);
  double _t = 0, _yaw = 87.5, _x = 0, _y = 0;
  Timer? _timer;

  late final StreamController<Telemetry> _out =
      StreamController<Telemetry>.broadcast(
        onListen: _start,
        onCancel: _stopTimer,
      );

  bool get online => device.status.isOnline;

  Stream<Telemetry> get telemetry => _out.stream;

  /// 是否正在推送遥测（有订阅者）。用于检查离开页面后是否停止。
  bool get streaming => _timer != null;

  void move(double vx, double vy, double wz) {
    _lastOperator = DateTime.now();
    if (estop || !online) return;
    _cvx = vx;
    _cvy = vy;
    _cwz = wz;
    _lastMove = DateTime.now();
  }

  void stop() {
    _lastOperator = DateTime.now();
    _cvx = _cvy = _cwz = 0;
  }

  void _start() {
    if (!online) return;
    _timer ??= Timer.periodic(
      Duration(milliseconds: 1000 ~/ hz),
      (_) => _tick(),
    );
    _tick();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final dt = 1 / hz;
    _t += dt;
    final now = DateTime.now();

    // 看门狗：300 ms 内没有新的 move 即停止。
    if (now.difference(_lastMove) > const Duration(milliseconds: 300)) {
      _cvx = _cvy = _cwz = 0;
    }
    var tx = _cvx, ty = _cvy, tw = _cwz;
    // 任务中、且 2 秒内无人操控：沿巡检路线自主行走。
    final autonomous =
        device.status == DeviceStatus.busy &&
        now.difference(_lastOperator) > const Duration(seconds: 2);
    if (autonomous && !estop && mode == MotionMode.walk) {
      tx = 0.62 + 0.04 * math.sin(_t / 3);
      tw = -0.15 * math.cos(_t / 5);
    }
    if (estop || mode == MotionMode.damp || mode == MotionMode.down) {
      tx = ty = tw = 0;
    }
    // 一阶滞后：速度平滑跟随指令。
    const k = 0.35;
    _vx += (tx - _vx) * k;
    _vy += (ty - _vy) * k;
    _wz += (tw - _wz) * k;
    _yaw = (_yaw + _wz * dt * 180 / math.pi) % 360;
    final h = _yaw * math.pi / 180;
    _x += (_vx * math.cos(h) - _vy * math.sin(h)) * dt;
    _y += (_vx * math.sin(h) + _vy * math.cos(h)) * dt;

    final moving = _vx.abs() + _vy.abs() + _wz.abs() > 0.02;
    battery = math.max(0, battery - (moving ? 0.004 : 0.001) * dt);
    final speed = math.sqrt(_vx * _vx + _vy * _vy);

    // 对角小跑：两组对角腿交替着地（Sensors.dc.html 足端接触力）。
    final phase = math.sin(_t * 2 * math.pi * 2.1);
    final standing = mode == MotionMode.down || mode == MotionMode.damp
        ? 25.0
        : 62.0;
    final feet = moving
        ? [
            phase > 0 ? 118 + 8 * phase : 3.0,
            phase > 0 ? 2.0 : 126 - 8 * phase,
            phase > 0 ? 3.0 : 122 - 6 * phase,
            phase > 0 ? 126 + 6 * phase : 2.0,
          ]
        : [for (var i = 0; i < 4; i++) standing + _rnd.nextDouble() * 4];

    double n(double a) => (_rnd.nextDouble() - 0.5) * a;
    _out.add(
      Telemetry(
        deviceId: device.id,
        ts: now,
        latencyMs: (device.latencyMs ?? 20) + _rnd.nextInt(5) - 2,
        battery: battery,
        vx: _vx,
        vy: _vy,
        wz: _wz,
        roll: 1.2 + n(0.4) + (moving ? 0.8 * phase : 0),
        pitch: -3.4 + n(0.4),
        yaw: _yaw,
        jointTemps: [
          for (final leg in joints)
            [for (final j in leg) j + 0.3 * math.sin(_t / 7 + j) + speed * 0.5],
        ],
        footForces: feet,
        voltage: 25.0 + battery / 100 * 4.2 + n(0.05),
        current: moving ? 4.2 + speed * 1.5 + n(0.3) : 1.1 + n(0.1),
        batteryTemp: 34 + n(0.3),
        pose: Pose(_x, _y, _yaw),
        mode: mode.name,
        accel: [
          0.42 + (moving ? 0.6 * math.sin(_t * 3) : 0) + n(0.08),
          -0.08 + (moving ? 0.3 * math.sin(_t * 5 + 1) : 0) + n(0.06),
          9.79 + (moving ? 0.25 * math.sin(_t * 13.2) : 0) + n(0.04),
        ],
        locConfidence: device.id == 'go2-01' ? 0.54 + n(0.02) : 0.92 + n(0.02),
      ),
    );
  }

  /// 机器人坐标系下的一帧点云（走廊 + 前方墙 + 障碍物），单位米。
  PointCloudFrame pointCloud(int seed) {
    final r = math.Random(device.id.hashCode ^ seed);
    double j(double a) => (r.nextDouble() - 0.5) * a;
    final pts = <Offset>[];
    void wall(double x0, double y0, double x1, double y1, int n) {
      for (var i = 0; i < n; i++) {
        final t = r.nextDouble();
        pts.add(
          Offset(x0 + (x1 - x0) * t + j(0.06), y0 + (y1 - y0) * t + j(0.06)),
        );
      }
    }

    wall(-1.6, -3.0, -1.6, 4.6, 170); // 左墙
    wall(1.6, -3.0, 1.6, 0.6, 70); // 右墙（门洞前）
    wall(1.6, 1.8, 1.6, 4.6, 70); // 右墙（门洞后）
    wall(1.6, 0.6, 4.4, 0.6, 40); // 门洞两侧
    wall(1.6, 1.8, 4.4, 1.8, 40);
    wall(-1.6, 4.6, 1.6, 4.6, 90); // 前方墙
    wall(0.5, 2.1, 1.1, 2.1, 30); // 前方障碍物（机柜）
    wall(0.5, 2.1, 0.5, 2.6, 18);
    wall(1.1, 2.1, 1.1, 2.6, 18);
    wall(-0.6, 0.9, -0.2, 0.9, 16); // 近处小障碍
    return PointCloudFrame(ts: DateTime.now(), points: pts);
  }
}

/// 设备遥测、控制、感知的 mock 实现。
class MockRobotFleet
    implements TelemetryRepository, ControlRepository, SensorRepository {
  MockRobotFleet({required this.world});

  final MockWorld world;
  late final Map<String, MockRobot> _robots = {
    for (final d in MockData.devices) d.id: MockRobot(d, hz: world.telemetryHz),
  };
  late final Map<String, MockStore<bool>> _estop = {
    for (final d in MockData.devices) d.id: MockStore(false),
  };
  late final Map<String, MockStore<List<CommandLogEntry>>> _logs = {
    for (final d in MockData.devices)
      d.id: MockStore([
        if (d.id == 'go2-01')
          for (final (ago, text) in MockSeed.commandLog)
            CommandLogEntry(at: MockSeed.ago(ago), text: text),
      ]),
  };
  final Map<String, DateTime> _lastMoveLog = {};

  MockRobot? robot(String id) => _robots[id];

  void _log(String deviceId, String text, {CommandError? error}) {
    final store = _logs[deviceId];
    if (store == null) return;
    final entry = CommandLogEntry(
      at: DateTime.now(),
      text: text,
      ok: error == null,
      error: error?.message,
    );
    store.value = [entry, ...store.value.take(199)];
  }

  /// 指令检查顺序与服务器 `services::control::execute` 一致：在线 → 控制权 → 急停。
  /// [sessionId] 不为空时按联调会话的租约检查（会话代表发起人下发）。
  CommandError? _check(
    String deviceId,
    DeviceCommand command, {
    String? sessionId,
  }) {
    final r = _robots[deviceId];
    if (r == null || !r.online) return CommandError.robotOffline;
    final holds = sessionId == null
        ? world.leases.holds(deviceId)
        : world.leases.heldBySession(deviceId, sessionId);
    if (!holds) return CommandError.forbidden;
    if (r.estop && command.isMotion) return CommandError.estopActive;
    return null;
  }

  // ---- TelemetryRepository ----

  @override
  Stream<Telemetry> watch(String deviceId) {
    final r = _robots[deviceId];
    // 离线设备没有遥测：返回立即结束的空流，界面据此显示「离线」。
    if (r == null || !r.online) return const Stream.empty();
    return r.telemetry;
  }

  // ---- ControlRepository ----

  @override
  void move(String deviceId, double vx, double vy, double wz) {
    if (_check(deviceId, MoveCommand(vx, vy, wz)) != null) return;
    _robots[deviceId]!.move(vx, vy, wz);
    // 高频指令只每秒记一条日志。
    final last = _lastMoveLog[deviceId];
    if (last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 1)) {
      _lastMoveLog[deviceId] = DateTime.now();
      _log(deviceId, MoveCommand(vx, vy, wz).logText);
    }
  }

  @override
  void stop(String deviceId) {
    final r = _robots[deviceId];
    if (r == null || !r.online || !world.leases.holds(deviceId)) return;
    r.stop();
    _lastMoveLog.remove(deviceId);
    _log(deviceId, const StopCommand().logText);
  }

  @override
  Future<CommandResult> send(String deviceId, DeviceCommand command) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return _execute(deviceId, command);
  }

  /// 联调会话下发（`POST /fleet-sessions/{id}/commands` 的单台设备部分）。
  CommandResult sendAsSession(
    String sessionId,
    String deviceId,
    DeviceCommand command,
  ) {
    final number = world.sessions.session(sessionId)?.number;
    return _execute(
      deviceId,
      command,
      sessionId: sessionId,
      prefix: number == null ? '' : '[联调 #$number] ',
    );
  }

  CommandResult _execute(
    String deviceId,
    DeviceCommand command, {
    String? sessionId,
    String prefix = '',
  }) {
    final error = _check(deviceId, command, sessionId: sessionId);
    if (error != null) {
      _log(deviceId, '$prefix${command.logText}', error: error);
      return CommandResult.failed(error);
    }
    final r = _robots[deviceId]!;
    switch (command) {
      case SetModeCommand(:final mode):
        r.mode = mode;
      case SetSpeedCommand(:final level):
        r.speed = level;
      case MoveCommand(:final vx, :final vy, :final wz):
        r.move(vx, vy, wz);
      case StopCommand():
        r.stop();
      case ActionCommand():
        break;
    }
    _log(deviceId, '$prefix${command.logText} ✓');
    return const CommandResult.ok();
  }

  @override
  Stream<List<CommandLogEntry>> watchLog(String deviceId) =>
      _logs[deviceId]?.watch() ?? Stream.value(const []);

  @override
  Stream<bool> watchEstop(String deviceId) =>
      _estop[deviceId]?.watch() ?? Stream.value(false);

  /// [reason] 为空时是单机急停；全局急停传「全局急停」。
  @override
  Future<void> setEstop(
    String deviceId, {
    required bool active,
    String? reason,
  }) async {
    final r = _robots[deviceId];
    final store = _estop[deviceId];
    if (r == null || store == null) return;
    // 急停是安全操作：任何能看到设备的人都可以触发，不检查控制权（§8.1）。
    r.estop = active;
    if (active) {
      r.stop();
      r.mode = MotionMode.damp;
    }
    store.value = active;
    final who = world.me.name;
    final what = reason ?? '急停';
    _log(
      deviceId,
      active ? 'sport.Damp() · $what（$who）' : 'estop.Release() · 解除$what（$who）',
    );
    world.devices.addEvent(
      deviceId,
      active ? '$who 触发$what' : '$who 解除$what',
      active ? EventTone.critical : EventTone.neutral,
    );
  }

  // ---- SensorRepository ----

  @override
  Stream<PointCloudFrame> watchPointCloud(String deviceId) {
    final r = _robots[deviceId];
    if (r == null || !r.online) return const Stream.empty();
    late final StreamController<PointCloudFrame> c;
    Timer? timer;
    var seed = 0;
    c = StreamController<PointCloudFrame>(
      onListen: () {
        c.add(r.pointCloud(seed++));
        timer = Timer.periodic(
          const Duration(milliseconds: 200),
          (_) => c.add(r.pointCloud(seed++)),
        );
      },
      onCancel: () => timer?.cancel(),
    );
    return c.stream;
  }

  @override
  Stream<SensorStatus> watchStatus(String deviceId) {
    final r = _robots[deviceId];
    final online = r?.online ?? false;
    return Stream.value(
      SensorStatus(
        cameras: [
          for (final cam in MockSeed.cameras)
            online
                ? cam
                : SensorSource(
                    name: cam.name,
                    detail: '离线',
                    health: SourceHealth.idle,
                  ),
        ],
        topics: [
          for (final t in MockSeed.topics)
            online
                ? t
                : SensorSource(
                    name: t.name,
                    detail: t.detail,
                    health: SourceHealth.idle,
                  ),
        ],
        lidar: MockSeed.lidar,
      ),
    );
  }
}
