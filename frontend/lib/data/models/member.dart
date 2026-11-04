import 'package:flutter/foundation.dart';

enum MemberRole {
  admin('平台管理员', '管理员'),
  owner('设备管理者', '管理者'),
  user('使用者', '使用者'),
  viewer('观察者', '观察者');

  const MemberRole(this.label, this.shortLabel);

  final String label;

  /// 筛选标签用的短名（Roles.dc.html roleTabs）。
  final String shortLabel;
}

/// HANDOFF.md §6 Member。
@immutable
class Member {
  const Member({
    required this.id,
    required this.name,
    required this.handle,
    required this.role,
    this.color,
    this.expiresAt,
    this.grantedDeviceIds = const [],
    this.videoOnly = false,
    this.guestLink = false,
    this.online = false,
    this.lastSeen,
    this.disabled = false,
    this.pendingInvite = false,
  });

  final String id;
  final String name;
  final String handle;
  final MemberRole role;

  /// 头像颜色 ARGB（API 成员字段 `color`）；为空时界面按名字取色。
  final int? color;

  /// 长期有效为 null。
  final DateTime? expiresAt;

  /// 额外授权的设备（`GET /members/{id}/devices`）。自己管理的设备由
  /// `Device.ownerId` 决定，不在这里重复；平台管理员可访问全部设备。
  final List<String> grantedDeviceIds;

  /// 只能看视频（观察者的临时访客链接）。
  final bool videoOnly;

  /// 临时访客链接，没有账号。
  final bool guestLink;

  final bool online;
  final DateTime? lastSeen;
  final bool disabled;

  /// 已邀请、尚未通过邀请链接设置密码（API `pending_invite`）。
  final bool pendingInvite;

  bool expired(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  Member copyWith({
    String? name,
    MemberRole? role,
    DateTime? expiresAt,
    bool clearExpiry = false,
    List<String>? grantedDeviceIds,
    bool? videoOnly,
    bool? online,
    DateTime? lastSeen,
    bool? disabled,
    bool? pendingInvite,
  }) => Member(
    id: id,
    name: name ?? this.name,
    handle: handle,
    role: role ?? this.role,
    color: color,
    expiresAt: clearExpiry ? null : expiresAt ?? this.expiresAt,
    grantedDeviceIds: grantedDeviceIds ?? this.grantedDeviceIds,
    videoOnly: videoOnly ?? this.videoOnly,
    guestLink: guestLink,
    online: online ?? this.online,
    lastSeen: lastSeen ?? this.lastSeen,
    disabled: disabled ?? this.disabled,
    pendingInvite: pendingInvite ?? this.pendingInvite,
  );
}

/// 邀请成员（`POST /members`，不传密码）：对方打开邀请链接后自己设置密码。
@immutable
class MemberDraft {
  const MemberDraft({
    required this.name,
    required this.handle,
    required this.role,
    this.expiresAt,
    this.grantedDeviceIds = const [],
    this.videoOnly = false,
  });

  final String name;
  final String handle;
  final MemberRole role;
  final DateTime? expiresAt;
  final List<String> grantedDeviceIds;
  final bool videoOnly;
}

/// 审计日志的类别，决定时间线圆点颜色（Roles.dc.html audit[].dot）。
enum AuditKind {
  /// 控制权、联调、智能体计划等操控相关。
  control,
  alert,

  /// 远程终端、固件等高危操作。
  terminal,

  /// 围栏、成员、规则等配置变更。
  config,

  /// 服务端自动执行。
  system,
}

/// HANDOFF.md §6 AuditEntry（`GET /audit`）。
@immutable
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.at,
    required this.actor,
    required this.action,
    required this.kind,
    required this.client,
    this.actorId,
    this.target,
  });

  final String id;
  final DateTime at;

  /// 显示名；系统操作为「系统」。
  final String actor;
  final String? actorId;

  /// 完整动作描述，如「确认告警「Charlie 左后腿电机过热」」。
  final String action;
  final String? target;
  final AuditKind kind;

  /// 客户端（请求头 `X-Client`），如 `macOS · 192.168.1.20`、`服务端`。
  final String client;
}

/// 权限矩阵里的取值：● 全部设备 / ◐ 仅自己管理或被授权的设备 / — 无。
enum Access {
  all('●', '全部设备'),
  own('◐', '仅自己管理或被授权的设备'),
  none('—', '无');

  const Access(this.symbol, this.label);

  final String symbol;
  final String label;
}

/// 角色权限矩阵的一行（Roles.dc.html P[]）。服务端按同一张表校验。
@immutable
class RolePermission {
  const RolePermission(
    this.name,
    this.admin,
    this.owner,
    this.user,
    this.viewer,
  );

  final String name;
  final Access admin, owner, user, viewer;

  Access of(MemberRole r) => switch (r) {
    MemberRole.admin => admin,
    MemberRole.owner => owner,
    MemberRole.user => user,
    MemberRole.viewer => viewer,
  };

  static const matrix = [
    RolePermission('查看设备状态', Access.all, Access.all, Access.own, Access.own),
    RolePermission('查看视频与传感器', Access.all, Access.all, Access.own, Access.own),
    RolePermission(
      '申请 / 持有控制权',
      Access.all,
      Access.own,
      Access.own,
      Access.none,
    ),
    RolePermission('发起多机联调', Access.all, Access.own, Access.none, Access.none),
    RolePermission(
      '编辑地图、任务与围栏',
      Access.all,
      Access.own,
      Access.none,
      Access.none,
    ),
    RolePermission(
      '固件升级与远程终端',
      Access.all,
      Access.own,
      Access.none,
      Access.none,
    ),
    RolePermission('分配使用者', Access.all, Access.own, Access.none, Access.none),
    RolePermission(
      '管理成员与角色',
      Access.all,
      Access.none,
      Access.none,
      Access.none,
    ),
    RolePermission(
      '急停（任何人可触发）',
      Access.all,
      Access.all,
      Access.all,
      Access.all,
    ),
  ];
}
