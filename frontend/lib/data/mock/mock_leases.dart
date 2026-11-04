import 'dart:async';

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';
import 'mock_repositories.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

/// 控制权（API「控制权」一节）。规则：
/// - 同一时刻一台设备只有一个持有者；被占用时申请进入队列（§8.2）。
/// - 转移、批准 / 拒绝申请：当前持有者、设备管理者或平台管理员。
/// - 强制收回：设备管理者或平台管理员，必须填写原因。
/// - 租约到期且无人续约即释放（安全策略「控制租约过期 · 停止并释放」）。
///   其他成员的客户端在线操控时会自动续约，mock 里用定时器模拟。
class MockLeaseRepository implements LeaseRepository {
  MockLeaseRepository({required this.world});

  final MockWorld world;

  static const term = Duration(minutes: 5);

  String get currentUserId => world.currentUserId;

  final _leases = MockStore<List<Lease>>([
    for (final l in MockData.leases)
      Lease(
        deviceId: l.deviceId,
        holderKind: l.holderKind,
        holderId: l.holderId,
        source: l.source,
        acquiredAt: l.acquiredAt == null
            ? null
            : MockSeed.rebase(l.acquiredAt!),
        expiresAt: l.expiresAt == null
            ? null
            // 任务的排期是日历上的绝对时间（「22:00」），不随「现在」平移。
            : l.holderKind == LeaseHolderKind.task
            ? DateTime.now().copyWith(
                hour: l.expiresAt!.hour,
                minute: l.expiresAt!.minute,
                second: 0,
              )
            : MockSeed.rebase(l.expiresAt!),
        queue: [
          for (final r in l.queue)
            LeaseRequest(
              id: r.id,
              userId: r.userId,
              reason: r.reason,
              expectedDuration: r.expectedDuration,
              createdAt: MockSeed.rebase(r.createdAt),
            ),
        ],
      ),
  ]);
  var _requestSeq = 100;
  Timer? _ticker;

  Lease? lease(String deviceId) =>
      _leases.value.where((l) => l.deviceId == deviceId).firstOrNull;

  bool holds(String deviceId) {
    final l = lease(deviceId);
    return l != null &&
        l.holderKind == LeaseHolderKind.user &&
        l.holderId == currentUserId;
  }

  bool heldBySession(String deviceId, String sessionId) {
    final l = lease(deviceId);
    return l != null &&
        l.holderKind == LeaseHolderKind.session &&
        l.holderId == sessionId;
  }

  /// 能否处理该设备的控制权：持有者本人、设备管理者或平台管理员。
  bool canManage(String deviceId) {
    final me = world.me;
    if (me.role == MemberRole.admin) return true;
    if (world.devices.device(deviceId)?.ownerId == me.id) return true;
    return holds(deviceId);
  }

  /// 能否强制收回：设备管理者或平台管理员。
  bool canForce(String deviceId) {
    final me = world.me;
    return me.role == MemberRole.admin ||
        world.devices.device(deviceId)?.ownerId == me.id;
  }

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  Stream<List<Lease>> watchLeases() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    return _leases.watch();
  }

  @override
  Future<LeaseRequestResult> acquire(String deviceId, {String? reason}) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final current = lease(deviceId);
    if (current == null) {
      _put(
        Lease(
          deviceId: deviceId,
          holderKind: LeaseHolderKind.user,
          holderId: currentUserId,
          source: '单机操控',
          acquiredAt: DateTime.now(),
          expiresAt: DateTime.now().add(term),
        ),
      );
      _event(deviceId, '${world.me.name} 获取控制权');
      return LeaseRequestResult.granted;
    }
    if (holds(deviceId)) return LeaseRequestResult.granted;
    if (current.queue.any((r) => r.userId == currentUserId)) {
      return LeaseRequestResult.queued;
    }
    _replace(
      deviceId,
      (l) => l.copyWith(
        queue: [
          ...l.queue,
          LeaseRequest(
            id: 'r${_requestSeq++}',
            userId: currentUserId,
            reason: reason ?? '申请单机操控',
            expectedDuration: const Duration(minutes: 20),
            createdAt: DateTime.now(),
          ),
        ],
      ),
    );
    world.log(
      '申请 ${world.deviceName(deviceId)} 的控制权',
      kind: AuditKind.control,
      target: deviceId,
    );
    return LeaseRequestResult.queued;
  }

  @override
  Future<void> release(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!holds(deviceId)) return;
    world.fleet.robot(deviceId)?.stop();
    _remove(deviceId);
    _event(deviceId, '${world.me.name} 释放控制权');
  }

  @override
  Future<void> forceRelease(String deviceId, {required String reason}) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!canForce(deviceId)) {
      throw const LeaseException('forbidden', '只有设备管理者和平台管理员可以强制收回');
    }
    final l = lease(deviceId);
    if (l == null) return;
    world.fleet.robot(deviceId)?.stop();
    if (l.holderKind == LeaseHolderKind.session) {
      world.sessions.detach(deviceId);
    }
    _remove(deviceId);
    _event(
      deviceId,
      '${world.me.name} 强制收回 ${holderName(l)} 的控制权：$reason',
      EventTone.warning,
    );
    world.log(
      '强制收回 ${holderName(l)} 对 ${world.deviceName(deviceId)} 的控制权：$reason',
      kind: AuditKind.control,
      target: deviceId,
    );
  }

  @override
  Future<void> renew(String deviceId) async {
    if (!holds(deviceId)) return;
    _replace(deviceId, (l) => l.copyWith(expiresAt: DateTime.now().add(term)));
  }

  @override
  Future<void> transfer(
    String deviceId,
    LeaseTarget target, {
    String? note,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final l = lease(deviceId);
    if (l == null) return;
    if (!canManage(deviceId)) {
      throw const LeaseException('forbidden', '只有持有者、设备管理者或平台管理员可以转移控制权');
    }
    if (l.holderKind == LeaseHolderKind.session) {
      throw const LeaseException('conflict', '设备由联调会话持有，结束会话或移出设备后才能转移');
    }
    if (l.holderKind == target.kind && l.holderId == target.id) return;
    final from = holderName(l);
    world.fleet.robot(deviceId)?.stop();
    _put(_transferred(l, target, from));
    final to = target.kind == LeaseHolderKind.user
        ? world.nameOf(target.id)
        : '任务调度';
    _event(
      deviceId,
      '控制权由 $from 转移给 $to${note == null || note.isEmpty ? '' : '：$note'}',
    );
    world.log(
      '将 ${world.deviceName(deviceId)} 的控制权由 $from 转移给 $to',
      kind: AuditKind.control,
      target: deviceId,
    );
  }

  @override
  Future<void> approve(String deviceId, String requestId) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final l = lease(deviceId);
    final r = l?.queue.where((q) => q.id == requestId).firstOrNull;
    if (l == null || r == null) {
      throw const LeaseException('conflict', '申请已处理');
    }
    if (!canManage(deviceId)) {
      throw const LeaseException('forbidden', '只有持有者、设备管理者或平台管理员可以审批');
    }
    world.fleet.robot(deviceId)?.stop();
    _put(_transferred(l, LeaseTarget.user(r.userId), holderName(l)));
    _event(
      deviceId,
      '${world.me.name} 批准 ${world.nameOf(r.userId)} 的申请，控制权已转移',
    );
    world.log(
      '批准了 ${world.nameOf(r.userId)} 对 ${world.deviceName(deviceId)} 的控制权申请',
      kind: AuditKind.control,
      target: deviceId,
    );
  }

  @override
  Future<void> deny(String deviceId, String requestId) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final l = lease(deviceId);
    final r = l?.queue.where((q) => q.id == requestId).firstOrNull;
    if (l == null || r == null) {
      throw const LeaseException('conflict', '申请已处理');
    }
    if (!canManage(deviceId)) {
      throw const LeaseException('forbidden', '只有持有者、设备管理者或平台管理员可以审批');
    }
    _replace(
      deviceId,
      (l) => l.copyWith(
        queue: [
          for (final q in l.queue)
            if (q.id != requestId) q,
        ],
      ),
    );
    _event(deviceId, '${world.me.name} 拒绝 ${world.nameOf(r.userId)} 的控制权申请');
    world.log(
      '拒绝了 ${world.nameOf(r.userId)} 对 ${world.deviceName(deviceId)} 的控制权申请',
      kind: AuditKind.control,
      target: deviceId,
    );
  }

  // ---- 联调会话 ----

  /// 设备能否交给会话：空闲，或由当前用户持有（个人控制权被会话接管）。
  String? sessionBlocker(String deviceId, String sessionId) {
    final l = lease(deviceId);
    if (l == null || holds(deviceId) || heldBySession(deviceId, sessionId)) {
      return null;
    }
    return '${holderName(l)} 控制中';
  }

  void assignSession(String deviceId, FleetSession session) {
    final l = lease(deviceId);
    _put(
      Lease(
        deviceId: deviceId,
        holderKind: LeaseHolderKind.session,
        holderId: session.id,
        source: session.name,
        acquiredAt: DateTime.now(),
        queue: l?.queue ?? const [],
      ),
    );
  }

  void releaseSession(String deviceId, String sessionId) {
    if (heldBySession(deviceId, sessionId)) _remove(deviceId);
  }

  /// 持有者显示名：成员名、会话发起人或「任务调度」（Lease.dc.html「持有者」列）。
  String holderName(Lease l) => switch (l.holderKind) {
    LeaseHolderKind.user => world.nameOf(l.holderId),
    LeaseHolderKind.session => world.nameOf(
      world.sessions.session(l.holderId)?.initiatorId ?? '',
    ),
    LeaseHolderKind.task => '任务调度',
  };

  // ---- 内部 ----

  Lease _transferred(Lease l, LeaseTarget target, String from) => Lease(
    deviceId: l.deviceId,
    holderKind: target.kind,
    holderId: target.id,
    source: target.kind == LeaseHolderKind.user ? '单机 · 由 $from 转移' : '自动任务',
    acquiredAt: DateTime.now(),
    expiresAt: target.kind == LeaseHolderKind.user
        ? DateTime.now().add(term)
        : null,
    queue: [
      for (final q in l.queue)
        if (!(target.kind == LeaseHolderKind.user && q.userId == target.id)) q,
    ],
  );

  void _tick() {
    final now = DateTime.now();
    var changed = false;
    final expired = <Lease>[];
    final next = <Lease>[];
    for (final l in _leases.value) {
      final exp = l.expiresAt;
      if (exp == null || l.holderKind != LeaseHolderKind.user) {
        next.add(l);
        continue;
      }
      final left = exp.difference(now);
      if (l.holderId != currentUserId && left < term ~/ 3) {
        // 其他成员的客户端在操控中，剩余 1/3 时自动续约。
        next.add(l.copyWith(expiresAt: now.add(term)));
        changed = true;
      } else if (left <= Duration.zero) {
        expired.add(l);
        changed = true;
      } else {
        next.add(l);
      }
    }
    if (!changed) return;
    _leases.value = next;
    for (final l in expired) {
      world.fleet.robot(l.deviceId)?.stop();
      _event(l.deviceId, '${holderName(l)} 的租约到期，已停止并释放控制权');
    }
  }

  void _put(Lease lease) {
    final exists = this.lease(lease.deviceId) != null;
    _leases.value = exists
        ? [
            for (final l in _leases.value)
              l.deviceId == lease.deviceId ? lease : l,
          ]
        : [..._leases.value, lease];
  }

  void _remove(String deviceId) {
    _leases.value = [
      for (final l in _leases.value)
        if (l.deviceId != deviceId) l,
    ];
  }

  void _replace(String deviceId, Lease Function(Lease) update) {
    _leases.value = [
      for (final l in _leases.value) l.deviceId == deviceId ? update(l) : l,
    ];
  }

  void _event(
    String deviceId,
    String text, [
    EventTone tone = EventTone.neutral,
  ]) => world.devices.addEvent(deviceId, text, tone);
}
