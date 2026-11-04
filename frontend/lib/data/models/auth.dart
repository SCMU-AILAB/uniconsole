import 'package:flutter/foundation.dart';

/// 登录会话（API `POST /auth/login` 的 `LoginResponse`）。
@immutable
class AuthSession {
  const AuthSession({
    required this.token,
    required this.sessionId,
    required this.memberId,
    required this.server,
    required this.expiresAt,
  });

  final String token;
  final String sessionId;
  final String memberId;

  /// 服务器地址（如 `console.example.com`），自托管部署各不相同。
  final String server;
  final DateTime expiresAt;
}

/// 邀请页信息（`GET /auth/invites/{token}`）。
@immutable
class InviteInfo {
  const InviteInfo({
    required this.token,
    required this.name,
    required this.handle,
    required this.expiresAt,
  });

  final String token;
  final String name;
  final String handle;
  final DateTime expiresAt;
}

/// 邀请成员的结果（`POST /members` 的 `invite_url`）：链接只能用一次。
@immutable
class MemberInvite {
  const MemberInvite({
    required this.memberId,
    required this.url,
    required this.expiresAt,
  });

  final String memberId;
  final String url;
  final DateTime expiresAt;
}

/// 登录与邀请的错误（API 错误表）。[message] 是给人看的中文，原样显示。
class AuthException implements Exception {
  const AuthException(this.code, this.message, {this.retryAfter});

  /// `unauthorized`、`two_factor_required`、`two_factor_invalid`、`forbidden`、
  /// `too_many_requests`、`bad_request`、`not_found`、`network`。
  final String code;
  final String message;

  /// 429 时多久后可以再试。
  final Duration? retryAfter;

  bool get needsCode => code == 'two_factor_required';

  @override
  String toString() => message;
}

/// 密码规则（API：8–128 个字符）。不满足时返回提示文字。
String? passwordProblem(String password) {
  if (password.length < 8) return '密码至少 8 位';
  if (password.length > 128) return '密码最多 128 位';
  return null;
}
