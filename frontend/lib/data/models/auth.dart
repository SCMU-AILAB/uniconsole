import 'package:flutter/foundation.dart';

import 'member.dart';

/// 登录会话（API `POST /auth/login` 的 `LoginResponse`）。
@immutable
class AuthSession {
  const AuthSession({
    required this.token,
    required this.sessionId,
    required this.memberId,
    required this.server,
    required this.expiresAt,
    this.member,
  });

  final String token;
  final String sessionId;
  final String memberId;

  /// 服务器地址（如 `console.example.com`），自托管部署各不相同。
  final String server;
  final DateTime expiresAt;

  /// 登录返回的当前成员（`LoginResponse.member` / `GET /auth/me`）。
  /// mock 会话为 null，当前成员由 mock 世界提供。
  final Member? member;

  AuthSession copyWith({Member? member}) => AuthSession(
    token: token,
    sessionId: sessionId,
    memberId: memberId,
    server: server,
    expiresAt: expiresAt,
    member: member ?? this.member,
  );
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

/// 邮箱注册（`POST /auth/register`）。
@immutable
class RegisterDraft {
  const RegisterDraft({
    required this.email,
    required this.code,
    required this.handle,
    required this.name,
    required this.password,
  });

  final String email;

  /// 邮件里的 6 位验证码。
  final String code;

  /// 账号，可带 @。
  final String handle;
  final String name;
  final String password;
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
  /// `too_many_requests`、`bad_request`、`not_found`、`conflict`、`network`、
  /// `upstream_unavailable`（验证邮件发送失败）。
  final String code;
  final String message;

  /// 429 时多久后可以再试。
  final Duration? retryAfter;

  bool get needsCode => code == 'two_factor_required';

  @override
  String toString() => message;
}

/// 邮箱格式（与服务端规则一致的粗查）。不满足时返回提示文字。
String? emailProblem(String email) {
  final e = email.trim();
  final at = e.indexOf('@');
  final ok =
      at > 0 &&
      at == e.lastIndexOf('@') &&
      e.length <= 254 &&
      !e.contains(RegExp(r'\s')) &&
      RegExp(r'^[^.]+(\.[^.]+)+$').hasMatch(e.substring(at + 1));
  return ok ? null : '邮箱格式不正确';
}

/// 账号规则（API：2–32 位小写字母、数字、_ . -，可带 @）。不满足时返回提示文字。
String? handleProblem(String handle) {
  var h = handle.trim().toLowerCase();
  if (h.startsWith('@')) h = h.substring(1);
  return RegExp(r'^[a-z0-9_.\-]{2,32}$').hasMatch(h)
      ? null
      : '账号只能包含 2–32 位小写字母、数字、_ . -';
}

/// 密码规则（API：8–128 个字符）。不满足时返回提示文字。
String? passwordProblem(String password) {
  if (password.length < 8) return '密码至少 8 位';
  if (password.length > 128) return '密码最多 128 位';
  return null;
}
