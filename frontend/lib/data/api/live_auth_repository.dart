import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'api_client.dart';
import 'json_codec.dart';
import 'token_store.dart';

/// 真实后端的登录与会话（API「认证」）。
///
/// - 令牌和当前成员保存在系统钥匙串（[TokenStore]），启动时恢复，再用
///   `GET /auth/me` 校验；服务端返回 401 时清掉会话，路由守卫回到登录页。
/// - 网络不通时保留本地会话（离线也能打开应用），恢复连接后的请求再校验。
/// - 其他模块接后端时用 [api] 发请求：已带令牌，401 会自动退出。
class LiveAuthRepository implements AuthRepository {
  LiveAuthRepository._(this._store, this._client, this._lastServer);

  /// 从钥匙串恢复会话；过期的会话直接清掉。
  static Future<LiveAuthRepository> restore(
    TokenStore store, {
    http.Client? client,
  }) async {
    final repo = LiveAuthRepository._(
      store,
      client,
      await store.readServer() ?? '',
    );
    final saved = await store.readSession();
    final session = saved == null ? null : _sessionFromStore(saved);
    if (session != null && session.expiresAt.isAfter(DateTime.now())) {
      repo._set(session);
    } else if (saved != null) {
      await store.clearSession();
    }
    return repo;
  }

  final TokenStore _store;
  final http.Client? _client;
  String _lastServer;
  AuthSession? _session;
  ApiClient? _api;
  final _changes = StreamController<AuthSession?>.broadcast();

  @override
  AuthSession? get session => _session;

  @override
  Stream<AuthSession?> watchSession() async* {
    yield _session;
    yield* _changes.stream;
  }

  @override
  String get lastServer => _lastServer;

  /// 当前会话的 API 客户端；未登录为 null。
  ApiClient? get api => _api;

  void _set(AuthSession? s, {bool closeOld = true}) {
    if (closeOld) _api?.close();
    _session = s;
    _api = s == null
        ? null
        : ApiClient(
            base: apiBase(s.server)!,
            token: s.token,
            client: _client,
            onUnauthorized: _expired,
          );
    _changes.add(s);
  }

  /// 会话在服务端失效（退出、被踢下线、停用、过期）。
  void _expired() {
    if (_session == null) return;
    _set(null);
    unawaited(_store.clearSession());
  }

  /// 未登录的请求（登录、邀请），用完关闭。
  ApiClient _anonymous(Uri base) => ApiClient(base: base, client: _client);

  Uri _base(String server) {
    final base = apiBase(server);
    if (base == null) {
      throw const AuthException(
        'bad_request',
        '服务器地址无效，例如 console.example.com',
      );
    }
    return base;
  }

  static AuthException _auth(ApiException e) {
    Duration? retry;
    if (e.code == 'too_many_requests') {
      final n = RegExp(r'(\d+)\s*秒').firstMatch(e.message)?.group(1);
      retry = Duration(seconds: int.tryParse(n ?? '') ?? 60);
    }
    return AuthException(e.code, e.message, retryAfter: retry);
  }

  Future<AuthSession> _accept(String server, Object? json) async {
    if (json is! Map<String, Object?> || json['member'] is! Map) {
      throw const AuthException('error', '服务器返回的数据无法识别，请确认地址指向 UniConsole 服务');
    }
    final member = memberFromJson(json['member']! as Map<String, Object?>);
    final secs = (json['expires_in'] as num?)?.toInt() ?? 12 * 3600;
    final session = AuthSession(
      token: '${json['token']}',
      sessionId: '${json['session_id']}',
      memberId: member.id,
      server: server,
      expiresAt: DateTime.now().add(Duration(seconds: secs)),
      member: member,
    );
    _lastServer = server;
    await _store.writeServer(server);
    await _store.writeSession(_sessionToStore(session));
    _set(session);
    return session;
  }

  @override
  Future<AuthSession> login({
    required String server,
    required String handle,
    required String password,
    String? code,
  }) async {
    final host = server.trim();
    if (host.isEmpty) {
      throw const AuthException('bad_request', '请填写服务器地址');
    }
    if (handle.trim().isEmpty || password.isEmpty) {
      throw const AuthException('bad_request', '请填写账号和密码');
    }
    final api = _anonymous(_base(host));
    try {
      final json = await api.post('/auth/login', {
        'handle': handle.trim(),
        'password': password,
        if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
        'device_name': deviceName(),
      });
      return await _accept(host, json);
    } on ApiException catch (e) {
      throw _auth(e);
    } finally {
      api.close();
    }
  }

  /// 启动后校验恢复的会话，并刷新当前成员（角色、名字可能已被修改）。
  Future<void> refresh() async {
    final api = _api;
    final s = _session;
    if (api == null || s == null) return;
    try {
      final json = await api.get('/auth/me');
      if (json is Map<String, Object?> && identical(_session, s)) {
        final updated = s.copyWith(member: memberFromJson(json));
        await _store.writeSession(_sessionToStore(updated));
        _session = updated;
        _changes.add(updated);
      }
    } on ApiException {
      // 401 已由 onUnauthorized 处理；网络错误时保留本地会话。
    }
  }

  @override
  Future<void> logout() async {
    final api = _api;
    if (_session == null) return;
    // 先清本地（界面立即回到登录页），再用旧令牌通知服务端吊销；
    // 网络不通也不影响退出。旧连接用完再关。
    _set(null, closeOld: false);
    await _store.clearSession();
    try {
      await api?.post('/auth/logout');
    } on ApiException {
      // 忽略
    } finally {
      api?.close();
    }
  }

  @override
  Future<InviteInfo> invite(String token, {String? server}) async {
    final host = (server ?? _lastServer).trim();
    if (host.isEmpty) {
      throw const AuthException('bad_request', '请填写服务器地址');
    }
    final api = _anonymous(_base(host));
    try {
      final json = await api.get('/auth/invites/${Uri.encodeComponent(token)}');
      if (json is! Map<String, Object?>) {
        throw const AuthException('error', '服务器返回的数据无法识别');
      }
      return inviteFromJson(token, json);
    } on ApiException catch (e) {
      throw _auth(e);
    } finally {
      api.close();
    }
  }

  @override
  Future<AuthSession> acceptInvite(
    String token,
    String password, {
    String? server,
  }) async {
    final problem = passwordProblem(password);
    if (problem != null) throw AuthException('bad_request', problem);
    final host = (server ?? _lastServer).trim();
    final api = _anonymous(_base(host));
    try {
      final json = await api.post(
        '/auth/invites/${Uri.encodeComponent(token)}/accept',
        {'password': password, 'device_name': deviceName()},
      );
      return await _accept(host, json);
    } on ApiException catch (e) {
      throw _auth(e);
    } finally {
      api.close();
    }
  }

  @override
  Future<Duration> requestRegisterCode({
    required String server,
    required String email,
  }) async {
    final host = server.trim();
    if (host.isEmpty) {
      throw const AuthException('bad_request', '请填写服务器地址');
    }
    final problem = emailProblem(email);
    if (problem != null) throw AuthException('bad_request', problem);
    final api = _anonymous(_base(host));
    try {
      final json = await api.post('/auth/register/code', {
        'email': email.trim(),
      });
      final secs = json is Map<String, Object?>
          ? (json['resend_after'] as num?)?.toInt()
          : null;
      return Duration(seconds: secs ?? 60);
    } on ApiException catch (e) {
      throw _auth(e);
    } finally {
      api.close();
    }
  }

  @override
  Future<AuthSession> register({
    required String server,
    required RegisterDraft draft,
  }) async {
    final host = server.trim();
    final problem =
        emailProblem(draft.email) ??
        handleProblem(draft.handle) ??
        passwordProblem(draft.password);
    if (problem != null) throw AuthException('bad_request', problem);
    final api = _anonymous(_base(host));
    try {
      final json = await api.post('/auth/register', {
        'email': draft.email.trim(),
        'code': draft.code.trim(),
        'handle': draft.handle.trim(),
        'name': draft.name.trim(),
        'password': draft.password,
        'device_name': deviceName(),
      });
      return await _accept(host, json);
    } on ApiException catch (e) {
      throw _auth(e);
    } finally {
      api.close();
    }
  }

  static Map<String, Object?> _sessionToStore(AuthSession s) => {
    'server': s.server,
    'token': s.token,
    'session_id': s.sessionId,
    'expires_at': s.expiresAt.toUtc().toIso8601String(),
    if (s.member != null) 'member': memberToJson(s.member!),
  };

  static AuthSession? _sessionFromStore(Map<String, Object?> j) {
    final server = j['server'];
    final token = j['token'];
    final expires = DateTime.tryParse('${j['expires_at']}');
    final member = j['member'];
    if (server is! String ||
        token is! String ||
        expires == null ||
        member is! Map<String, Object?> ||
        apiBase(server) == null) {
      return null;
    }
    final m = memberFromJson(member);
    return AuthSession(
      token: token,
      sessionId: '${j['session_id']}',
      memberId: m.id,
      server: server,
      expiresAt: expires.toLocal(),
      member: m,
    );
  }
}
