import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/repositories/repositories.dart';

/// 登录与邀请：规则与 API「认证」一致。
void main() {
  late MockWorld world;
  late MockAuthRepository auth;
  setUp(() {
    world = MockWorld(telemetryHz: 50, signedIn: false);
    auth = world.auth..latency = Duration.zero;
  });
  tearDown(() => world.dispose());

  const server = MockAuthRepository.defaultServer;
  const pw = MockAuthRepository.demoPassword;

  Matcher fails(String code) =>
      throwsA(isA<AuthException>().having((e) => e.code, 'code', code));

  Future<AuthSession> login(String handle, {String? password, String? code}) =>
      auth.login(
        server: server,
        handle: handle,
        password: password ?? pw,
        code: code,
      );

  test('账号不区分大小写、可带 @；登录后切换当前成员并在线', () async {
    world.members.setOnline('linyue', online: false);
    final s = await login('@LinYue');
    expect(s.memberId, 'linyue');
    expect(auth.session, isNotNull);
    expect(world.me.name, '林悦');
    expect(world.me.online, isTrue);
  });

  test('账号不存在和密码错误返回同一句话', () async {
    await expectLater(login('nobody'), fails('unauthorized'));
    await expectLater(
      login('linyue', password: 'wrong-pass'),
      fails('unauthorized'),
    );
    try {
      await login('nobody');
    } on AuthException catch (e) {
      expect(e.message, '账号或密码错误');
    }
  });

  test('访客链接没有账号，不能用密码登录', () async {
    final guest = world.members.members.firstWhere((m) => m.guestLink);
    await expectLater(login(guest.handle), fails('unauthorized'));
  });

  test('开启二次验证的账号先要验证码，错误时提示', () async {
    await expectLater(login('kanade'), fails('two_factor_required'));
    await expectLater(
      login('kanade', code: '000000'),
      fails('two_factor_invalid'),
    );
    final s = await login('kanade', code: MockAuthRepository.demoCode);
    expect(s.memberId, 'kanade');
  });

  test('停用与过期的账号返回 403', () async {
    world.signIn('kanade');
    await world.members.update('linyue', disabled: true);
    await world.members.update(
      'chenyi',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    world.signOut();
    try {
      await login('linyue');
      fail('应当失败');
    } on AuthException catch (e) {
      expect((e.code, e.message), ('forbidden', '账号已停用'));
    }
    try {
      await login('chenyi');
      fail('应当失败');
    } on AuthException catch (e) {
      expect((e.code, e.message), ('forbidden', '账号已过期'));
    }
  });

  test('同一账号失败 5 次锁定，锁定期间密码正确也不能登录', () async {
    for (var i = 0; i < MockAuthRepository.maxFailures - 1; i++) {
      await expectLater(
        login('linyue', password: 'wrong-pass'),
        fails('unauthorized'),
      );
    }
    await expectLater(
      login('linyue', password: 'wrong-pass'),
      throwsA(
        isA<AuthException>()
            .having((e) => e.code, 'code', 'too_many_requests')
            .having((e) => e.retryAfter, 'retryAfter', isNotNull),
      ),
    );
    await expectLater(login('linyue'), fails('too_many_requests'));
  });

  test('退出登录清掉会话并标记离线', () async {
    await login('linyue');
    await auth.logout();
    expect(auth.session, isNull);
    expect(world.members.member('linyue')!.online, isFalse);
  });

  test('邀请：等待设置密码时不能登录；设置后直接登录，链接只能用一次', () async {
    world.signIn('kanade');
    final invite = await world.members.invite(
      const MemberDraft(name: '王五', handle: 'wangwu', role: MemberRole.user),
    );
    expect(invite.url, startsWith('uniconsole://invite/'));
    final token = invite.url.split('/').last;
    final m = world.members.member(invite.memberId)!;
    expect(m.pendingInvite, isTrue);
    await expectLater(login('wangwu'), fails('unauthorized'));

    final info = await auth.invite(token);
    expect((info.name, info.handle), ('王五', '@wangwu'));
    await expectLater(auth.acceptInvite(token, 'short'), fails('bad_request'));

    final s = await auth.acceptInvite(token, 'a-good-password');
    expect(s.memberId, invite.memberId);
    expect(world.members.member(invite.memberId)!.pendingInvite, isFalse);
    await expectLater(auth.invite(token), fails('not_found'));

    await auth.logout();
    final again = await login('@wangwu', password: 'a-good-password');
    expect(again.memberId, invite.memberId);
  });

  test('重新生成邀请链接后旧链接作废；已激活的成员不能再生成', () async {
    world.signIn('kanade');
    final first = await world.members.invite(
      const MemberDraft(name: '王五', handle: 'wangwu', role: MemberRole.user),
    );
    final second = await world.members.reissueInvite(first.memberId);
    await expectLater(
      auth.invite(first.url.split('/').last),
      fails('not_found'),
    );
    expect((await auth.invite(second.url.split('/').last)).name, '王五');
    await expectLater(
      world.members.reissueInvite('linyue'),
      throwsA(isA<MemberException>().having((e) => e.code, 'code', 'conflict')),
    );
  });

  test('演示邀请链接：接受时才建档', () async {
    final before = world.members.members.length;
    expect((await auth.invite('demo')).handle, '@wangning');
    await auth.acceptInvite('demo', 'a-good-password');
    expect(world.members.members.length, before + 1);
    expect(world.me.name, '王宁');
  });
}
