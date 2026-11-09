import '../models/models.dart';

/// API JSON（snake_case）→ 前端模型。字段见 ../server/docs/API.md。

DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// 服务端账号不带 @，前端统一显示为 `@handle`。
String displayHandle(Object? handle) {
  final h = '${handle ?? ''}';
  return h.startsWith('@') ? h : '@$h';
}

/// `#RRGGBB` → ARGB。
int? _color(Object? v) {
  if (v is int) return v;
  if (v is! String) return null;
  final hex = v.startsWith('#') ? v.substring(1) : v;
  final n = int.tryParse(hex, radix: 16);
  if (n == null) return null;
  return hex.length == 6 ? 0xFF000000 | n : n;
}

MemberRole _role(Object? v) =>
    MemberRole.values.where((r) => r.name == v).firstOrNull ??
    MemberRole.viewer;

Member memberFromJson(Map<String, Object?> j) => Member(
  id: '${j['id']}',
  name: '${j['name'] ?? ''}',
  handle: displayHandle(j['handle']),
  role: _role(j['role']),
  color: _color(j['color']),
  expiresAt: _time(j['expires_at']),
  grantedDeviceIds: [
    for (final id in (j['granted_device_ids'] as List?) ?? const []) '$id',
  ],
  videoOnly: j['video_only'] == true,
  guestLink: j['guest_link'] == true,
  online: j['online'] == true,
  lastSeen: _time(j['last_seen']),
  disabled: j['disabled'] == true,
  pendingInvite: j['pending_invite'] == true,
  email: j['email'] is String ? j['email']! as String : null,
);

/// 前端模型 → 本地保存用的 JSON（与 API 同形，读回时走 [memberFromJson]）。
Map<String, Object?> memberToJson(Member m) => {
  'id': m.id,
  'name': m.name,
  'handle': m.handle,
  'role': m.role.name,
  if (m.color != null)
    'color':
        '#${(m.color! & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
  'expires_at': m.expiresAt?.toUtc().toIso8601String(),
  'granted_device_ids': m.grantedDeviceIds,
  'video_only': m.videoOnly,
  'guest_link': m.guestLink,
  'online': m.online,
  'last_seen': m.lastSeen?.toUtc().toIso8601String(),
  'disabled': m.disabled,
  'pending_invite': m.pendingInvite,
  if (m.email != null) 'email': m.email,
};

InviteInfo inviteFromJson(String token, Map<String, Object?> j) => InviteInfo(
  token: token,
  name: '${j['name'] ?? ''}',
  handle: displayHandle(j['handle']),
  expiresAt:
      _time(j['expires_at']) ?? DateTime.now().add(const Duration(days: 7)),
);
