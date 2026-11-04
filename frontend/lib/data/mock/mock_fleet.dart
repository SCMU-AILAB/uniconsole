import 'dart:math' as math;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';
import 'mock_repositories.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

/// 多机联调（API「多机联调」一节）。
///
/// - 加入会话即由会话持有该设备的租约（个人控制权被接管）；告警、充电中、离线或被他人
///   控制的设备不能加入。
/// - 只有发起人与平台管理员可以修改会话、下发同步指令；全体急停任何人都可以触发。
class MockFleetRepository implements FleetRepository {
  MockFleetRepository({required this.world});

  final MockWorld world;

  late final _sessions = MockStore<List<FleetSession>>([
    for (final s in MockData.sessions)
      FleetSession(
        id: s.id,
        number: s.number,
        title: s.title,
        presetId: s.presetId,
        initiatorId: s.initiatorId,
        startedAt: MockSeed.rebase(s.startedAt),
        deviceIds: s.deviceIds,
        formation: s.formation,
        spacing: s.spacing,
        timeline: MockSeed.timelineFor(s.deviceIds),
        lastReceipt: MockSeed.initialReceipt(s.deviceIds),
      ),
  ]);
  final _presets = MockStore<List<FleetPreset>>(MockData.presets);
  // 编号只增不减：会话结束后新会话仍用下一个编号。
  var _nextNumber =
      MockData.sessions.map((s) => s.number).fold(0, math.max) + 1;
  final _rnd = math.Random(12);

  List<FleetSession> get sessions => _sessions.value;

  FleetSession? session(String id) =>
      _sessions.value.where((s) => s.id == id).firstOrNull;

  /// 当前用户能否操作该会话：发起人或平台管理员。
  bool canOperate(FleetSession s) =>
      s.initiatorId == world.currentUserId || world.me.role == MemberRole.admin;

  /// 设备不能加入会话的原因；可以加入时为 null。
  String? blocker(String deviceId, String sessionId) {
    final d = world.devices.device(deviceId);
    if (d == null) return '不存在';
    switch (d.status) {
      case DeviceStatus.offline:
        return '离线';
      case DeviceStatus.alert:
        return '告警';
      case DeviceStatus.charging:
        return '充电中';
      case DeviceStatus.online || DeviceStatus.busy:
        break;
    }
    return world.leases.sessionBlocker(deviceId, sessionId);
  }

  @override
  Stream<List<FleetSession>> watchSessions() => _sessions.watch();

  @override
  Stream<List<FleetPreset>> watchPresets() => _presets.watch();

  @override
  Future<String> start({
    String? presetId,
    List<String> deviceIds = const [],
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final preset = _presets.value.where((p) => p.id == presetId).firstOrNull;
    final running = _sessions.value
        .where((s) => presetId != null && s.presetId == presetId)
        .firstOrNull;
    if (running != null) return running.id;

    final id = 's$_nextNumber';
    final ids = preset?.deviceIds ?? deviceIds;
    final blocked = [
      for (final d in ids)
        if (blocker(d, id) case final reason?) (d, reason),
    ];
    if (blocked.isNotEmpty) {
      throw FleetException(
        '无法发起联调：${blocked.map((b) => '${world.devices.device(b.$1)?.name ?? b.$1} ${b.$2}').join('、')}',
        deviceIds: [for (final b in blocked) b.$1],
      );
    }
    final s = FleetSession(
      id: id,
      number: _nextNumber++,
      title: preset?.name ?? '临时联调',
      presetId: preset?.id,
      initiatorId: world.currentUserId,
      startedAt: DateTime.now(),
      deviceIds: ids,
      formation: preset?.formation ?? Formation.v,
      spacing: preset?.spacing ?? 1.2,
      timeline: MockSeed.timelineFor(ids),
    );
    for (final d in ids) {
      world.leases.assignSession(d, s);
      world.devices.addEvent(d, '加入${s.name}', EventTone.info);
    }
    _sessions.value = [..._sessions.value, s];
    world.log(
      '发起联调会话 #${s.number}（${ids.length} 台）',
      kind: AuditKind.control,
      target: id,
    );
    return id;
  }

  @override
  Future<void> setParticipant(
    String sessionId,
    String deviceId, {
    required bool joined,
  }) async {
    final s = _require(sessionId);
    if (joined == s.deviceIds.contains(deviceId)) return;
    if (joined) {
      final reason = blocker(deviceId, sessionId);
      if (reason != null) {
        throw FleetException(
          '${world.devices.device(deviceId)?.name ?? deviceId} $reason，不能加入',
          deviceIds: [deviceId],
        );
      }
      world.fleet.robot(deviceId)?.stop();
      world.leases.assignSession(deviceId, s);
      world.devices.addEvent(deviceId, '加入${s.name}', EventTone.info);
      _update(sessionId, (s) {
        final ids = [...s.deviceIds, deviceId];
        return s.copyWith(deviceIds: ids, timeline: MockSeed.timelineFor(ids));
      });
    } else {
      world.fleet.robot(deviceId)?.stop();
      world.leases.releaseSession(deviceId, sessionId);
      world.devices.addEvent(deviceId, '退出${s.name}', EventTone.neutral);
      _update(sessionId, (s) {
        final ids = [
          for (final d in s.deviceIds)
            if (d != deviceId) d,
        ];
        return s.copyWith(deviceIds: ids, timeline: MockSeed.timelineFor(ids));
      });
    }
  }

  @override
  Future<void> setFormation(String sessionId, Formation formation) async {
    _require(sessionId);
    _update(sessionId, (s) => s.copyWith(formation: formation));
  }

  @override
  Future<FleetReceipt> send(
    String sessionId,
    DeviceCommand command, {
    required String label,
  }) async {
    final s = _require(sessionId);
    final sentAt = DateTime.now();
    final acks = <FleetAck>[];
    var slowest = Duration.zero;
    for (final id in s.deviceIds) {
      final result = world.fleet.sendAsSession(sessionId, id, command);
      final base = world.devices.device(id)?.latencyMs ?? 20;
      final latency = Duration(
        milliseconds: (base * 0.6 + _rnd.nextInt(6)).round(),
      );
      if (latency > slowest) slowest = latency;
      acks.add(
        FleetAck(
          deviceId: id,
          ok: result.ok,
          latency: result.ok ? latency : null,
          error: result.error,
        ),
      );
    }
    await Future<void>.delayed(slowest);
    final receipt = FleetReceipt(label: label, sentAt: sentAt, acks: acks);
    _update(sessionId, (s) => s.copyWith(lastReceipt: receipt));
    return receipt;
  }

  @override
  Future<void> savePreset(String sessionId, String name) async {
    final s = _require(sessionId);
    final preset = FleetPreset(
      id: 'p-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      deviceIds: s.deviceIds,
      formation: s.formation,
      spacing: s.spacing,
    );
    _presets.value = [
      for (final p in _presets.value)
        if (p.name != name) p,
      preset,
    ];
  }

  @override
  Future<void> end(String sessionId) async {
    final s = _require(sessionId);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    for (final d in s.deviceIds) {
      world.fleet.robot(d)?.stop();
      world.leases.releaseSession(d, sessionId);
      world.devices.addEvent(d, '${s.name} 结束，已停止并释放控制权', EventTone.neutral);
    }
    _sessions.value = [
      for (final x in _sessions.value)
        if (x.id != sessionId) x,
    ];
    world.log(
      '结束联调会话 #${s.number}',
      kind: AuditKind.control,
      target: sessionId,
    );
  }

  /// 设备被强制收回时从会话中移出。
  void detach(String deviceId) {
    for (final s in _sessions.value) {
      if (!s.deviceIds.contains(deviceId)) continue;
      _update(s.id, (s) {
        final ids = [
          for (final d in s.deviceIds)
            if (d != deviceId) d,
        ];
        return s.copyWith(deviceIds: ids, timeline: MockSeed.timelineFor(ids));
      });
    }
  }

  /// 全局急停时暂停所有会话。
  void setPaused(bool paused) {
    _sessions.value = [
      for (final s in _sessions.value) s.copyWith(paused: paused),
    ];
  }

  FleetSession _require(String sessionId) {
    final s = session(sessionId);
    if (s == null) throw const FleetException('会话已结束');
    if (!canOperate(s)) {
      throw const FleetException('只有发起人和平台管理员可以操作该会话');
    }
    return s;
  }

  void _update(String id, FleetSession Function(FleetSession) f) {
    _sessions.value = [for (final s in _sessions.value) s.id == id ? f(s) : s];
  }
}
