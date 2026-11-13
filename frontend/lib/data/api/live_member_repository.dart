import 'dart:io';

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'api_client.dart';
import 'json_codec.dart';
import 'live_robot_repository.dart';

/// 设备详情与租约持有者使用同一份服务器成员数据。
class LiveMemberRepository implements MemberRepository {
  LiveMemberRepository(this.robot);
  final LiveRobotRepository robot;
  String _path(String id) => '/members/${Uri.encodeComponent(id)}';
  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on ApiException catch (e) {
      throw MemberException(e.code, e.message);
    }
  }

  @override
  Stream<List<Member>> watchMembers() => robot.poll(
    () async =>
        jsonRows(await robot.api.get('/members')).map(memberFromJson).toList(),
    events: {'changed'},
  );
  @override
  Stream<Member> watchCurrentUser() => robot.poll(
    () async => memberFromJson(jsonMap(await robot.api.get('/auth/me'))),
    events: {'changed'},
  );
  MemberInvite _invite(Map<String, dynamic> j, String id) => MemberInvite(
    memberId: id,
    url: j['invite_url'],
    expiresAt: DateTime.parse(j['invite_expires_at']).toLocal(),
  );
  @override
  Future<MemberInvite> invite(MemberDraft d) => _call(() async {
    final j = jsonMap(
      await robot.api.post('/members', {
        'name': d.name,
        'handle': d.handle.replaceFirst(RegExp(r'^@'), ''),
        'role': d.role.name,
        'expires_at': d.expiresAt?.toUtc().toIso8601String(),
        'device_ids': d.grantedDeviceIds,
        'video_only': d.videoOnly,
      }),
    );
    return _invite(j, j['member']['id']);
  });
  @override
  Future<MemberInvite> reissueInvite(String id) => _call(
    () async =>
        _invite(jsonMap(await robot.api.post('${_path(id)}/invite')), id),
  );
  @override
  Future<void> update(
    String id, {
    MemberRole? role,
    DateTime? expiresAt,
    bool clearExpiry = false,
    List<String>? grantedDeviceIds,
    bool? videoOnly,
    bool? disabled,
  }) => _call(() async {
    final patch = {
      if (role != null) 'role': role.name,
      if (expiresAt != null || clearExpiry)
        'expires_at': clearExpiry ? null : expiresAt?.toUtc().toIso8601String(),
      'video_only': ?videoOnly,
      'disabled': ?disabled,
    };
    if (patch.isNotEmpty) await robot.api.patch(_path(id), patch);
    if (grantedDeviceIds != null) {
      await robot.api.put('${_path(id)}/devices', {
        'device_ids': grantedDeviceIds,
      });
    }
  });
  @override
  Future<void> remove(String id) => _call(() async {
    await robot.api.delete(_path(id));
  });
  Future<List<AuditEntry>> _audit() async => [
    for (final j in jsonRows(
      await robot.api.get('/audit', query: {'limit': '500'}),
    ))
      AuditEntry(
        id: '${j['id']}',
        at: DateTime.parse(j['at']).toLocal(),
        actor: j['actor'],
        actorId: j['actor_id'],
        action: j['action'],
        target: j['target'],
        kind: AuditKind.values.byName(j['kind']),
        client: j['client'],
      ),
  ];
  @override
  Stream<List<AuditEntry>> watchAudit() =>
      robot.poll(_audit, events: {'changed'});
  @override
  Future<String> exportAudit() => _call(() async {
    // 导出当前可见的最近 500 条，与列表一致。
    String cell(Object? value) {
      var s = '${value ?? ''}';
      if (RegExp(r'^[=+@\-\t\r]').hasMatch(s)) s = "'$s";
      return '"${s.replaceAll('"', '""')}"';
    }

    final rows = await _audit();
    final csv = [
      '时间,操作人,动作,目标,客户端',
      for (final r in rows)
        [
          r.at.toIso8601String(),
          r.actor,
          r.action,
          r.target,
          r.client,
        ].map(cell).join(','),
    ].join('\r\n');
    final path =
        '${Directory.systemTemp.path}/uniconsole-audit-${DateTime.now().millisecondsSinceEpoch}.csv';
    await File(path).writeAsString('\uFEFF$csv');
    return path;
  });
}
