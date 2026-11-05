import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/api/api_client.dart';
import 'package:uniconsole/data/api/live_auth_repository.dart';
import 'package:uniconsole/data/api/token_store.dart';
import 'package:uniconsole/data/models/models.dart';

/// 对真实服务端跑一遍登录流程。默认跳过；设置下面三个环境变量后运行：
///
/// ```
/// UNICONSOLE_E2E_SERVER=127.0.0.1:8080 UNICONSOLE_E2E_ADMIN=admin \
/// UNICONSOLE_E2E_PASSWORD=… flutter test test/e2e
/// ```
///
/// 会在服务端新建一个使用者账号（`e2e<时间戳>`），请用测试库。
void main() {
  final env = Platform.environment;
  final server = env['UNICONSOLE_E2E_SERVER'];
  final admin = env['UNICONSOLE_E2E_ADMIN'];
  final password = env['UNICONSOLE_E2E_PASSWORD'];
  final skip = server == null || admin == null || password == null
      ? '未设置 UNICONSOLE_E2E_SERVER / _ADMIN / _PASSWORD'
      : null;

  // flutter_test 默认拦截真实 HTTP 请求。
  setUpAll(() => HttpOverrides.global = null);

  test('登录、邀请设置密码、/auth/me、退出后令牌失效、失败锁定', () async {
    final adminAuth = await LiveAuthRepository.restore(MemoryTokenStore());
    final a = await adminAuth.login(
      server: server!,
      handle: '@${admin!.toUpperCase()}',
      password: password!,
    );
    expect(a.member!.role, MemberRole.admin);

    // 管理员邀请一个新成员（不设密码 → 邀请链接）。
    final handle = 'e2e${DateTime.now().millisecondsSinceEpoch}';
    final created = await adminAuth.api!.post('/members', {
      'handle': handle,
      'name': '端到端测试',
      'role': 'user',
    }) as Map;
    final url = '${created['invite_url']}';
    expect(url, startsWith('uniconsole://invite/'));
    final token = url.split('/').last;

    final userAuth = await LiveAuthRepository.restore(MemoryTokenStore());
    final info = await userAuth.invite(token, server: server);
    expect((info.name, info.handle), ('端到端测试', '@$handle'));
    await expectLater(
      userAuth.acceptInvite(token, 'short', server: server),
      throwsA(
        isA<AuthException>().having((e) => e.code, 'code', 'bad_request'),
      ),
    );
    final newPassword = 'pw-${DateTime.now().microsecondsSinceEpoch}';
    final u = await userAuth.acceptInvite(token, newPassword, server: server);
    expect(u.member!.handle, '@$handle');
    expect(u.member!.pendingInvite, isFalse);
    await expectLater(
      userAuth.invite(token, server: server),
      throwsA(isA<AuthException>().having((e) => e.code, 'code', 'not_found')),
    );

    await userAuth.refresh();
    expect(userAuth.session, isNotNull);

    // 退出后旧令牌立即失效。
    final oldToken = userAuth.session!.token;
    await userAuth.logout();
    final stale = ApiClient(base: apiBase(server)!, token: oldToken);
    await expectLater(
      stale.get('/auth/me'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
    stale.close();

    // 密码登录；错误密码；连续失败锁定。
    final again = await userAuth.login(
      server: server,
      handle: handle,
      password: newPassword,
    );
    expect(again.memberId, u.memberId);
    await userAuth.logout();
    AuthException? last;
    for (var i = 0; i < 6; i++) {
      try {
        await userAuth.login(
          server: server,
          handle: handle,
          password: 'wrong-password',
        );
      } on AuthException catch (e) {
        last = e;
        if (i == 0) expect(e.message, '账号或密码错误');
      }
    }
    expect(last!.code, 'too_many_requests');
    expect(last.retryAfter, isNotNull);

    await adminAuth.logout();
  }, skip: skip);
}
