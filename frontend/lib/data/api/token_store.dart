import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 登录令牌与会话信息的本地保存（系统钥匙串 / Keystore / 凭据管理器）。
abstract interface class TokenStore {
  Future<Map<String, Object?>?> readSession();
  Future<void> writeSession(Map<String, Object?> session);
  Future<void> clearSession();

  /// 上次登录用的服务器地址（退出后保留，登录页预填）。
  Future<String?> readServer();
  Future<void> writeServer(String server);
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // 不用数据保护钥匙串：那需要签名团队与 keychain-access-groups 权限，
            // 未签名的开发版会失败（-34018）。正式签名后可以改回默认值。
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;
  static const _sessionKey = 'uniconsole.session';
  static const _serverKey = 'uniconsole.server';

  @override
  Future<Map<String, Object?>?> readSession() async {
    try {
      final raw = await _storage.read(key: _sessionKey);
      if (raw == null) return null;
      final v = jsonDecode(raw);
      return v is Map<String, Object?> ? v : null;
    } on Object {
      // 钥匙串不可用或内容损坏：当作未登录。
      return null;
    }
  }

  @override
  Future<void> writeSession(Map<String, Object?> session) =>
      _storage.write(key: _sessionKey, value: jsonEncode(session));

  @override
  Future<void> clearSession() async {
    try {
      await _storage.delete(key: _sessionKey);
    } on Object {
      // 删除失败不影响退出：内存里的会话已经清掉。
    }
  }

  @override
  Future<String?> readServer() async {
    try {
      return await _storage.read(key: _serverKey);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> writeServer(String server) =>
      _storage.write(key: _serverKey, value: server);
}

/// 内存保存（测试）。
class MemoryTokenStore implements TokenStore {
  Map<String, Object?>? session;
  String? server;

  @override
  Future<Map<String, Object?>?> readSession() async => session;

  @override
  Future<void> writeSession(Map<String, Object?> s) async => session = s;

  @override
  Future<void> clearSession() async => session = null;

  @override
  Future<String?> readServer() async => server;

  @override
  Future<void> writeServer(String s) async => server = s;
}
