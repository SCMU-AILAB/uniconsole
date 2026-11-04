import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repositories/repositories.dart';

/// 角色标签配色（Roles.dc.html ROLES）：管理员紫、管理者蓝、使用者绿、观察者灰。
StatusTone roleTone(MemberRole r) => switch (r) {
  MemberRole.admin => StatusTone.action,
  MemberRole.owner => StatusTone.busy,
  MemberRole.user => StatusTone.online,
  MemberRole.viewer => StatusTone.offline,
};

class RoleTag extends StatelessWidget {
  const RoleTag(this.role, {super.key});

  final MemberRole role;

  @override
  Widget build(BuildContext context) =>
      Tag(label: role.label, tone: roleTone(role), large: true);
}

String _two(int v) => v.toString().padLeft(2, '0');

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 「在线」「3 小时前」「今天」「昨天」「10 月 31 日」。
String lastSeenText(Member m, DateTime now) {
  if (m.disabled) return '已停用';
  if (m.online) return '在线';
  final t = m.lastSeen;
  if (t == null) return '未登录';
  final d = now.difference(t);
  if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} 分钟前';
  if (_sameDay(t, now)) return d.inHours < 4 ? '${d.inHours} 小时前' : '今天';
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '昨天';
  return '${t.month} 月 ${t.day} 日';
}

/// 「长期」「今天 18:00 失效」「至 11 月 30 日」「已失效」。
String expiryText(DateTime? at, DateTime now) {
  if (at == null) return '长期';
  if (!at.isAfter(now)) return '已失效';
  final hm = '${_two(at.hour)}:${_two(at.minute)}';
  if (_sameDay(at, now)) return '今天 $hm 失效';
  if (_sameDay(at, now.add(const Duration(days: 1)))) return '明天 $hm 失效';
  return '至 ${at.month} 月 ${at.day} 日';
}

/// 「可访问设备」列（Roles.dc.html M[].devices），由设备归属与授权计算。
String accessText(
  Member m,
  MemberDevices access,
  List<DeviceGroup> groups,
  List<Device> devices,
) {
  if (access.all) return '全部 ${access.count} 台';
  String names(List<Device> ds) => ds.map((d) => d.name).join('、');
  String? groupLabel(List<Device> ds) {
    if (ds.length < 2) return null;
    final g = ds.first.groupId;
    if (ds.any((d) => d.groupId != g)) return null;
    final all = devices.where((d) => d.groupId == g).length;
    if (all != ds.length) return null;
    final name = groups.where((x) => x.id == g).firstOrNull?.name;
    return name == null ? null : '$name设备';
  }

  final parts = <String>[
    if (access.managed.isNotEmpty) '管理 ${names(access.managed)}',
    if (access.granted.isNotEmpty)
      access.managed.isNotEmpty
          ? '授权 ${names(access.granted)}'
          : groupLabel(access.granted) ?? names(access.granted),
  ];
  if (parts.isEmpty) return '无';
  if (m.videoOnly) parts.add('仅视频');
  return parts.join(' · ');
}

/// 审计日志圆点（Roles.dc.html audit[].dot）。
Color auditDot(BuildContext context, AuditKind kind) {
  final c = context.colors;
  final s = context.status;
  return switch (kind) {
    AuditKind.control => c.accent,
    AuditKind.alert => s.warning.dot,
    AuditKind.terminal => s.action.dot,
    AuditKind.config => c.secondaryLabel,
    AuditKind.system => c.decorativeGrayLight,
  };
}

/// 今天「14:31」，昨天「昨天 17:42」，更早「10 月 31 日 09:30」。
String auditTime(DateTime t, DateTime now) {
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  if (_sameDay(t, now)) return hm;
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '昨天 $hm';
  return '${t.month} 月 ${t.day} 日 $hm';
}

// ---- 页面状态 ----

class MembersUiState {
  const MembersUiState({this.filter, this.notice});

  /// 角色筛选；null 为全部。
  final MemberRole? filter;
  final (BannerKind, String)? notice;
}

class MembersUi extends Notifier<MembersUiState> {
  @override
  MembersUiState build() => const MembersUiState();

  void filter(MemberRole? role) =>
      state = MembersUiState(filter: role, notice: state.notice);

  void notify(BannerKind kind, String text) =>
      state = MembersUiState(filter: state.filter, notice: (kind, text));
}

final membersUiProvider = NotifierProvider<MembersUi, MembersUiState>(
  MembersUi.new,
);

/// 执行成员操作，失败时把 [MemberException] 显示为页面提示。
Future<bool> runMemberAction(
  WidgetRef ref,
  Future<void> Function(MemberRepository repo) action, {
  String? success,
}) async {
  final ui = ref.read(membersUiProvider.notifier);
  try {
    await action(ref.read(memberRepositoryProvider));
    if (success != null) ui.notify(BannerKind.success, success);
    return true;
  } on MemberException catch (e) {
    ui.notify(BannerKind.warning, e.message);
    return false;
  }
}
