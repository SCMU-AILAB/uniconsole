import 'dart:math';

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_repositories.dart';
import 'mock_store.dart';

/// 登录与邀请（API「认证」）。规则与服务端一致：
/// - 账号不区分大小写、可带 `@`；账号不存在、尚未激活、密码错误都返回同一句「账号或密码错误」。
/// - 停用 / 过期返回 403；开启二次验证的账号先返回 `two_factor_required`。
/// - 同一账号 15 分钟内失败 5 次锁定 60 秒（429）。
///
/// 演示账号：示例成员（访客链接除外）的密码都是 [demoPassword]；
/// Kanade 开启了二次验证，验证码为 [demoCode]。
///
/// 邮箱注册：验证码固定为 [demoCode]，同一邮箱 [resendAfter] 内只能获取一次；
/// 注册后是观察者并直接登录，也可以用邮箱登录。
class MockAuthRepository implements AuthRepository {
  MockAuthRepository({required this.world, bool signedIn = true}) {
    // 模拟启动时从钥匙串恢复的会话。
    if (signedIn) _session.value = _issue(world.currentUserId, defaultServer);
    _invites['demo'] = _Invite(
      draft: const MemberDraft(
        name: '王宁',
        handle: '@wangning',
        role: MemberRole.user,
      ),
      expiresAt: DateTime.now().add(inviteTerm),
    );
  }

  final MockWorld world;

  static const defaultServer = 'console.uniconsole.local';
  static const demoPassword = 'uniconsole';
  static const demoCode = '123456';
  static const inviteTerm = Duration(days: 7);
  static const maxFailures = 5;
  static const failureWindow = Duration(minutes: 15);
  static const lockout = Duration(seconds: 60);
  static const resendAfter = Duration(seconds: 60);

  /// 网络与服务端处理的模拟耗时（测试里可设为 0）。
  Duration latency = const Duration(milliseconds: 350);

  final _session = MockStore<AuthSession?>(null);
  final _passwords = <String, String>{};
  final _twoFactor = <String>{'kanade'};
  final _invites = <String, _Invite>{};

  /// 已发验证码的邮箱 → 发送时间。
  final _codesSent = <String, DateTime>{};
  final _failures = <String, List<DateTime>>{};
  final _lockedUntil = <String, DateTime>{};
  final _random = Random();
  var _lastServer = defaultServer;

  @override
  AuthSession? get session => _session.value;

  @override
  Stream<AuthSession?> watchSession() => _session.watch();

  @override
  String get lastServer => _lastServer;

  String _password(Member m) => _passwords[m.id] ?? demoPassword;

  static String _normalize(String handle) {
    final h = handle.trim().toLowerCase();
    return h.startsWith('@') ? h.substring(1) : h;
  }

  String _token(int length) => [
    for (var i = 0; i < length; i++)
      '0123456789abcdefghijklmnopqrstuvwxyz'[_random.nextInt(36)],
  ].join();

  AuthSession _issue(String memberId, String server) => AuthSession(
    token: 'mock.${_token(24)}',
    sessionId: _token(12),
    memberId: memberId,
    server: server,
    expiresAt: DateTime.now().add(const Duration(hours: 12)),
  );

  void _signIn(String memberId, String server) {
    world.signIn(memberId);
    _lastServer = server;
    _session.value = _issue(memberId, server);
  }

  /// 记一次失败；达到上限时锁定并返回 429。
  AuthException _fail(String key) {
    final now = DateTime.now();
    final recent = [
      for (final t in _failures[key] ?? const <DateTime>[])
        if (now.difference(t) < failureWindow) t,
      now,
    ];
    _failures[key] = recent;
    if (recent.length >= maxFailures) {
      _failures.remove(key);
      _lockedUntil[key] = now.add(lockout);
      return _locked(lockout);
    }
    return const AuthException('unauthorized', '账号或密码错误');
  }

  static AuthException _locked(Duration left) => AuthException(
    'too_many_requests',
    '登录失败次数过多，请 ${left.inSeconds < 1 ? 1 : left.inSeconds} 秒后再试',
    retryAfter: left,
  );

  @override
  Future<AuthSession> login({
    required String server,
    required String handle,
    required String password,
    String? code,
  }) async {
    final host = server.trim();
    final key = _normalize(handle);
    if (host.isEmpty) {
      throw const AuthException('bad_request', '请填写服务器地址');
    }
    if (key.isEmpty || password.isEmpty) {
      throw const AuthException('bad_request', '请填写账号和密码');
    }
    await Future<void>.delayed(latency);

    final until = _lockedUntil[key];
    if (until != null) {
      final left = until.difference(DateTime.now());
      if (left > Duration.zero) throw _locked(left);
      _lockedUntil.remove(key);
    }

    final m = world.members.members
        .where((m) => _normalize(m.handle) == key || m.email == key)
        .firstOrNull;
    if (m == null ||
        m.guestLink ||
        m.pendingInvite ||
        _password(m) != password) {
      throw _fail(key);
    }
    if (m.disabled) throw const AuthException('forbidden', '账号已停用');
    if (m.expired(DateTime.now())) {
      throw const AuthException('forbidden', '账号已过期');
    }
    if (_twoFactor.contains(m.id)) {
      final c = code?.trim() ?? '';
      if (c.isEmpty) {
        throw const AuthException(
          'two_factor_required',
          '请输入验证器 App 中的 6 位验证码',
        );
      }
      if (c != demoCode) {
        throw const AuthException('two_factor_invalid', '二次验证码错误');
      }
    }
    _failures.remove(key);
    _signIn(m.id, host);
    return _session.value!;
  }

  @override
  Future<void> logout() async {
    if (_session.value == null) return;
    world.signOut();
    _session.value = null;
  }

  /// 生成邀请链接（`POST /members` / `POST /members/{id}/invite`）；旧链接作废。
  MemberInvite issueInvite(String memberId) {
    _invites.removeWhere((_, v) => v.memberId == memberId);
    final token = _token(20);
    final expiresAt = DateTime.now().add(inviteTerm);
    _invites[token] = _Invite(memberId: memberId, expiresAt: expiresAt);
    return MemberInvite(
      memberId: memberId,
      url: 'uniconsole://invite/$token',
      expiresAt: expiresAt,
    );
  }

  _Invite _requireInvite(String token) {
    final i = _invites[token];
    final m = i?.memberId == null ? null : world.members.member(i!.memberId!);
    final valid =
        i != null &&
        i.expiresAt.isAfter(DateTime.now()) &&
        (i.draft != null || (m != null && m.pendingInvite));
    if (!valid) {
      throw const AuthException('not_found', '邀请链接无效或已过期，请联系管理员重新邀请');
    }
    return i;
  }

  @override
  Future<InviteInfo> invite(String token, {String? server}) async {
    await Future<void>.delayed(latency);
    final i = _requireInvite(token);
    final m = i.memberId == null ? null : world.members.member(i.memberId!);
    return InviteInfo(
      token: token,
      name: m?.name ?? i.draft!.name,
      handle: m?.handle ?? i.draft!.handle,
      expiresAt: i.expiresAt,
    );
  }

  @override
  Future<AuthSession> acceptInvite(
    String token,
    String password, {
    String? server,
  }) async {
    final problem = passwordProblem(password);
    if (problem != null) throw AuthException('bad_request', problem);
    await Future<void>.delayed(latency);
    final i = _requireInvite(token);
    final id = i.memberId ?? world.members.addInvited(i.draft!);
    _invites.remove(token);
    _passwords[id] = password;
    world.members.activate(id);
    _signIn(id, _lastServer);
    return _session.value!;
  }

  bool _emailTaken(String email) =>
      world.members.members.any((m) => m.email == email);

  @override
  Future<Duration> requestRegisterCode({
    required String server,
    required String email,
  }) async {
    if (server.trim().isEmpty) {
      throw const AuthException('bad_request', '请填写服务器地址');
    }
    final problem = emailProblem(email);
    if (problem != null) throw AuthException('bad_request', problem);
    await Future<void>.delayed(latency);
    final key = email.trim().toLowerCase();
    if (_emailTaken(key)) {
      throw const AuthException('conflict', '该邮箱已注册，请直接登录');
    }
    final sent = _codesSent[key];
    if (sent != null) {
      final left = resendAfter - DateTime.now().difference(sent);
      if (left > Duration.zero) {
        final secs = (left.inMilliseconds / 1000).ceil();
        throw AuthException(
          'too_many_requests',
          '请 $secs 秒后再获取验证码',
          retryAfter: Duration(seconds: secs),
        );
      }
    }
    _codesSent[key] = DateTime.now();
    return resendAfter;
  }

  @override
  Future<AuthSession> register({
    required String server,
    required RegisterDraft draft,
  }) async {
    final problem =
        emailProblem(draft.email) ??
        handleProblem(draft.handle) ??
        passwordProblem(draft.password);
    if (problem != null) throw AuthException('bad_request', problem);
    if (draft.name.trim().isEmpty) {
      throw const AuthException('bad_request', '请填写 1–32 个字的名字');
    }
    await Future<void>.delayed(latency);
    final email = draft.email.trim().toLowerCase();
    final handle = _normalize(draft.handle);
    if (_emailTaken(email)) {
      throw const AuthException('conflict', '该邮箱已注册，请直接登录');
    }
    if (world.members.members.any((m) => _normalize(m.handle) == handle)) {
      throw AuthException('conflict', '账号 @$handle 已被使用');
    }
    if (!_codesSent.containsKey(email)) {
      throw const AuthException('bad_request', '验证码无效或已过期，请重新获取');
    }
    if (draft.code.trim() != demoCode) {
      throw const AuthException('bad_request', '验证码错误');
    }
    _codesSent.remove(email);
    final id = world.members.addRegistered(
      name: draft.name,
      handle: handle,
      email: email,
    );
    _passwords[id] = draft.password;
    _signIn(id, server.trim());
    return _session.value!;
  }
}

class _Invite {
  const _Invite({this.memberId, this.draft, required this.expiresAt});

  /// 已建档、等待设置密码的成员。
  final String? memberId;

  /// 演示链接：接受时才建档。
  final MemberDraft? draft;
  final DateTime expiresAt;
}
