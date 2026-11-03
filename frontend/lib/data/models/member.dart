import 'package:flutter/foundation.dart';

enum MemberRole {
  admin('平台管理员'),
  owner('设备所有者'),
  user('使用者'),
  viewer('观察者');

  const MemberRole(this.label);

  final String label;
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
  });

  final String id;
  final String name;
  final String handle;
  final MemberRole role;

  /// 头像颜色 ARGB（API 成员字段 `color`）；为空时界面按名字取色。
  final int? color;

  /// 长期有效为 null。
  final DateTime? expiresAt;
}
