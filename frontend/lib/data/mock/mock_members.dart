import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';
import 'mock_repositories.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

/// 成员、角色与审计日志。审计日志由各 mock 仓库在执行操作时写入（[log]），
/// 与 `GET /audit` 一样是全站唯一来源。
class MockMemberRepository implements MemberRepository {
  MockMemberRepository({required this.world});

  final MockWorld world;
  final _members = MockStore<List<Member>>(MockData.members);
  late final _audit = MockStore<List<AuditEntry>>(_seedAudit());
  var _seq = 0;

  List<Member> get members => _members.value;

  Member? member(String id) =>
      _members.value.where((m) => m.id == id).firstOrNull;

  /// 当前客户端，写入审计日志的「客户端」列（请求头 `X-Client`）。
  static String get client => switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.android => 'Android',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };

  /// 以当前用户（[actorId] 为空）或系统（`actorId: 'system'`）身份记一条审计日志。
  void log(
    String action, {
    AuditKind kind = AuditKind.config,
    String? actorId,
    String? target,
  }) {
    final id = actorId ?? world.currentUserId;
    final system = id == 'system';
    _audit.value = [
      AuditEntry(
        id: 'au${++_seq}',
        at: DateTime.now(),
        actor: system ? '系统' : world.nameOf(id),
        actorId: system ? null : id,
        action: action,
        target: target,
        kind: kind,
        client: system ? '服务端' : client,
      ),
      ..._audit.value,
    ];
  }

  void _requireAdmin() {
    if (world.me.role != MemberRole.admin) {
      throw const MemberException('forbidden', '只有平台管理员可以管理成员与角色');
    }
  }

  void _set(String id, Member Function(Member) f) {
    _members.value = [for (final m in _members.value) m.id == id ? f(m) : m];
  }

  static String expiryText(DateTime? at) =>
      at == null ? '长期有效' : '有效期至 ${at.month} 月 ${at.day} 日';

  @override
  Stream<List<Member>> watchMembers() => _members.watch();

  @override
  Stream<Member> watchCurrentUser() => _members.watch().map(
    (all) => all.firstWhere((m) => m.id == world.currentUserId),
  );

  @override
  Future<String> invite(MemberDraft d) async {
    _requireAdmin();
    final handle = d.handle.startsWith('@') ? d.handle : '@${d.handle}';
    if (d.name.trim().isEmpty || handle.length < 2) {
      throw const MemberException('bad_request', '请填写姓名和账号');
    }
    if (_members.value.any((m) => m.handle == handle)) {
      throw MemberException('conflict', '账号 $handle 已存在');
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final id = 'm${DateTime.now().microsecondsSinceEpoch}';
    _members.value = [
      ..._members.value,
      Member(
        id: id,
        name: d.name.trim(),
        handle: handle,
        role: d.role,
        expiresAt: d.expiresAt,
        grantedDeviceIds: d.grantedDeviceIds,
        videoOnly: d.videoOnly,
      ),
    ];
    log('邀请 ${d.name.trim()} 为${d.role.label}，${expiryText(d.expiresAt)}');
    return id;
  }

  @override
  Future<void> update(
    String id, {
    MemberRole? role,
    DateTime? expiresAt,
    bool clearExpiry = false,
    List<String>? grantedDeviceIds,
    bool? videoOnly,
    bool? disabled,
  }) async {
    _requireAdmin();
    final m = member(id);
    if (m == null) throw const MemberException('not_found', '成员不存在');
    if (id == world.currentUserId && role != null && role != m.role) {
      throw const MemberException('conflict', '不能修改自己的角色');
    }
    if (id == world.currentUserId && disabled == true) {
      throw const MemberException('conflict', '不能停用自己的账号');
    }
    final admins = _members.value.where(
      (x) => x.role == MemberRole.admin && !x.disabled,
    );
    if (m.role == MemberRole.admin &&
        admins.length == 1 &&
        ((role != null && role != MemberRole.admin) || disabled == true)) {
      throw const MemberException('conflict', '至少需要保留一名平台管理员');
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _set(
      id,
      (x) => x.copyWith(
        role: role,
        expiresAt: expiresAt,
        clearExpiry: clearExpiry,
        grantedDeviceIds: grantedDeviceIds,
        videoOnly: videoOnly,
        disabled: disabled,
      ),
    );
    final after = member(id)!;
    final changes = [
      if (role != null && role != m.role) '设为${role.label}',
      if (clearExpiry || (expiresAt != null && expiresAt != m.expiresAt))
        expiryText(after.expiresAt),
      if (grantedDeviceIds != null &&
          !setEquals(grantedDeviceIds.toSet(), m.grantedDeviceIds.toSet()))
        '授权设备改为 ${grantedDeviceIds.isEmpty ? '无' : grantedDeviceIds.map(world.deviceName).join('、')}',
      if (disabled != null && disabled != m.disabled)
        disabled ? '停用账号' : '恢复账号',
    ];
    if (changes.isNotEmpty) {
      log('将 ${m.name} ${changes.join('，')}', target: id);
    }
  }

  @override
  Future<void> remove(String id) async {
    _requireAdmin();
    final m = member(id);
    if (m == null) return;
    if (id == world.currentUserId) {
      throw const MemberException('conflict', '不能移除自己');
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _members.value = [
      for (final x in _members.value)
        if (x.id != id) x,
    ];
    log(m.guestLink ? '撤销临时访客链接（${m.name}）' : '移除成员 ${m.name}', target: id);
  }

  @override
  Stream<List<AuditEntry>> watchAudit() => _audit.watch();

  @override
  Future<String> exportAudit() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'audit-${n.year}${two(n.month)}${two(n.day)}.csv';
  }

  // Roles.dc.html audit[]。晚于设计稿「现在」14:32 的条目按其他页面的数据改写：
  // 周明确认 Charlie 告警是 14:31（告警时间线），联调会话 #12 是 2 台；
  // Kanade 批准林悦申请（14:36）改为林悦 14:30 提交的申请（控制权页仍待处理）。
  List<AuditEntry> _seedAudit() {
    final yesterday = DateTime(2026, 11, 1);
    AuditEntry e(
      String id,
      DateTime at,
      String actorId,
      String action,
      AuditKind kind,
      String client,
    ) => AuditEntry(
      id: id,
      at: MockSeed.rebase(at),
      actor: actorId == 'system' ? '系统' : world.nameOf(actorId),
      actorId: actorId == 'system' ? null : actorId,
      action: action,
      kind: kind,
      client: client,
    );
    return [
      e(
        's1',
        DateTime(2026, 11, 2, 14, 31, 48),
        'zhouming',
        '确认告警「Charlie 左后腿电机过热」',
        AuditKind.alert,
        'iOS',
      ),
      e(
        's2',
        DateTime(2026, 11, 2, 14, 30),
        'linyue',
        '申请 Alpha 的控制权（预计 20 分钟）',
        AuditKind.control,
        'Windows',
      ),
      e(
        's3',
        DateTime(2026, 11, 2, 14, 14),
        'zhouming',
        '发起联调会话 #12（2 台）',
        AuditKind.control,
        'macOS',
      ),
      e(
        's4',
        DateTime(2026, 11, 2, 13, 20),
        'kanade',
        '打开 Alpha 远程终端（已二次验证）',
        AuditKind.terminal,
        'macOS · 192.168.1.20',
      ),
      e(
        's5',
        yesterday.add(const Duration(hours: 17, minutes: 42)),
        'linyue',
        '修改围栏「台阶边缘」为禁止进入',
        AuditKind.config,
        'Windows',
      ),
      e(
        's6',
        yesterday.add(const Duration(hours: 10, minutes: 5)),
        'kanade',
        '将 陈一 设为使用者，有效期至 11 月 30 日',
        AuditKind.config,
        'macOS',
      ),
      e(
        's7',
        yesterday.add(const Duration(hours: 9, minutes: 41)),
        'system',
        '自动收回 Bravo 的空闲租约（10 分钟无输入）',
        AuditKind.system,
        '服务端',
      ),
      e(
        's8',
        yesterday.add(const Duration(hours: 9, minutes: 30)),
        'kanade',
        '创建临时访客链接（展厅 · 仅视频）',
        AuditKind.config,
        'macOS',
      ),
    ];
  }
}
