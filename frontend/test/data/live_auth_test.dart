import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uniconsole/data/api/api_client.dart';
import 'package:uniconsole/data/api/live_auth_repository.dart';
import 'package:uniconsole/data/api/token_store.dart';
import 'package:uniconsole/data/models/models.dart';

/// 真实后端登录：请求格式、错误映射、钥匙串保存与会话失效（HTTP 用 MockClient 模拟）。
void main() {
  const member = {
    'id': '3f2c',
    'handle': 'linyue',
    'name': '林悦',
    'role': 'owner',
    'color': '#FF2D55',
    'expires_at': null,
    'disabled': false,
    'granted_device_ids': ['go2-01'],
    'video_only': false,
    'guest_link': false,
    'online': true,
    'last_seen': '2026-11-04T06:30:00Z',
    'two_factor': false,
    'pending_invite': false,
    'created_at': '2026-10-01T00:00:00Z',
  };

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response error(int status, String code, String message) => json({
    'error': {'code': code, 'message': message},
  }, status);

  Map<String, Object?> loginOk([Map<String, Object?> m = member]) => {
    'token': 'jwt-1',
    'expires_in': 43200,
    'session_id': 's-1',
    'member': m,
  };

  group('服务器地址', () {
    test('没写协议时局域网用 http，其余用 https，并补上 /api/v1', () {
      expect(
        '${apiBase('192.168.1.5:8080')}',
        'http://192.168.1.5:8080/api/v1',
      );
      expect('${apiBase('localhost:8080')}', 'http://localhost:8080/api/v1');
      expect('${apiBase('robot.local')}', 'http://robot.local/api/v1');
      expect(
        '${apiBase('console.example.com')}',
        'https://console.example.com/api/v1',
      );
      expect(
        '${apiBase('https://example.com/uni/')}',
        'https://example.com/uni/api/v1',
      );
      expect(
        '${apiBase('http://example.com/api/v1')}',
        'http://example.com/api/v1',
      );
      expect(apiBase(''), isNull);
      expect(apiBase('ftp://x'), isNull);
    });
  });

  group('登录', () {
    late MemoryTokenStore store;
    setUp(() => store = MemoryTokenStore());

    test('请求格式正确；成功后保存令牌、服务器和当前成员', () async {
      late http.Request sent;
      final client = MockClient((req) async {
        sent = req;
        return json(loginOk());
      });
      final auth = await LiveAuthRepository.restore(store, client: client);
      final s = await auth.login(
        server: '192.168.1.5:8080',
        handle: '@LinYue',
        password: 'pw-12345678',
      );

      expect(sent.method, 'POST');
      expect('${sent.url}', 'http://192.168.1.5:8080/api/v1/auth/login');
      expect(sent.headers['X-Client'], endsWith(' $appVersion'));
      // dart:io 只接受 ASCII 请求头。
      expect(sent.headers['X-Client']!.codeUnits.every((c) => c < 128), isTrue);
      final body = jsonDecode(sent.body) as Map;
      expect(body['handle'], '@LinYue');
      expect(body['password'], 'pw-12345678');
      expect(body.containsKey('code'), isFalse);
      expect(body['device_name'], isNotEmpty);

      expect(s.token, 'jwt-1');
      expect(s.member!.handle, '@linyue');
      expect(s.member!.role, MemberRole.owner);
      expect(s.member!.color, 0xFFFF2D55);
      expect(auth.session, same(s));
      expect(auth.api, isNotNull);
      expect(store.server, '192.168.1.5:8080');
      expect(store.session!['token'], 'jwt-1');
      expect(auth.lastServer, '192.168.1.5:8080');
    });

    test('错误按服务端的 code 和 message 原样返回', () async {
      final replies = <http.Response>[
        error(401, 'unauthorized', '账号或密码错误'),
        error(401, 'two_factor_required', '请输入验证器 App 中的 6 位验证码'),
        error(401, 'two_factor_invalid', '二次验证码错误'),
        error(403, 'forbidden', '账号已停用'),
        error(429, 'too_many_requests', '登录失败次数过多，请 42 秒后再试'),
      ];
      final client = MockClient((_) async => replies.removeAt(0));
      final auth = await LiveAuthRepository.restore(store, client: client);
      Future<AuthException> attempt() async {
        try {
          await auth.login(server: 'h.local', handle: 'a', password: 'b');
        } on AuthException catch (e) {
          return e;
        }
        throw StateError('应当失败');
      }

      expect((await attempt()).message, '账号或密码错误');
      expect((await attempt()).needsCode, isTrue);
      expect((await attempt()).code, 'two_factor_invalid');
      expect((await attempt()).message, '账号已停用');
      final locked = await attempt();
      expect(locked.code, 'too_many_requests');
      expect(locked.retryAfter, const Duration(seconds: 42));
      expect(auth.session, isNull);
      expect(store.session, isNull);
    });

    test('带验证码登录', () async {
      late Map body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map;
        return json(loginOk());
      });
      final auth = await LiveAuthRepository.restore(store, client: client);
      await auth.login(
        server: 'h.local',
        handle: 'a',
        password: 'b',
        code: ' 123456 ',
      );
      expect(body['code'], '123456');
    });

    test('连不上服务器时提示检查地址和网络', () async {
      final client = MockClient(
        (_) async => throw const SocketException('refused'),
      );
      final auth = await LiveAuthRepository.restore(store, client: client);
      await expectLater(
        auth.login(server: '10.0.0.9:8080', handle: 'a', password: 'b'),
        throwsA(
          isA<AuthException>()
              .having((e) => e.code, 'code', 'network')
              .having((e) => e.message, 'message', contains('10.0.0.9:8080')),
        ),
      );
    });

    test('地址指向的不是 UniConsole 服务时给出说明', () async {
      final client = MockClient((_) async => http.Response('<html>', 404));
      final auth = await LiveAuthRepository.restore(store, client: client);
      await expectLater(
        auth.login(server: 'example.com', handle: 'a', password: 'b'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            contains('没有找到 UniConsole 服务'),
          ),
        ),
      );
    });
  });

  group('会话', () {
    late MemoryTokenStore store;
    setUp(() => store = MemoryTokenStore());

    Future<LiveAuthRepository> signedIn(MockClient client) async {
      final auth = await LiveAuthRepository.restore(
        store,
        client: MockClient((_) async => json(loginOk())),
      );
      await auth.login(server: 'h.local', handle: 'a', password: 'b');
      // 用同一份钥匙串内容、新的 HTTP 客户端模拟重启。
      return LiveAuthRepository.restore(store, client: client);
    }

    test('重启后从钥匙串恢复会话；/auth/me 刷新当前成员', () async {
      late http.Request sent;
      final auth = await signedIn(
        MockClient((req) async {
          sent = req;
          return json({...member, 'name': '林悦（改）'});
        }),
      );
      expect(auth.session!.member!.name, '林悦');
      await auth.refresh();
      expect(sent.headers['Authorization'], 'Bearer jwt-1');
      expect('${sent.url}', 'http://h.local/api/v1/auth/me');
      expect(auth.session!.member!.name, '林悦（改）');
    });

    test('服务端已吊销会话（401）时清掉并通知界面', () async {
      final auth = await signedIn(
        MockClient((_) async => error(401, 'unauthorized', '登录已失效，请重新登录')),
      );
      final changes = <AuthSession?>[];
      final sub = auth.watchSession().listen(changes.add);
      await auth.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(auth.session, isNull);
      expect(changes.last, isNull);
      expect(store.session, isNull);
      expect(store.server, 'h.local');
      await sub.cancel();
    });

    test('离线时保留本地会话', () async {
      final auth = await signedIn(
        MockClient((_) async => throw const SocketException('offline')),
      );
      await auth.refresh();
      expect(auth.session, isNotNull);
    });

    test('过期的会话启动时直接清掉', () async {
      store.session = {
        'server': 'h.local',
        'token': 't',
        'session_id': 's',
        'expires_at': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
        'member': member,
      };
      final auth = await LiveAuthRepository.restore(
        store,
        client: MockClient((_) async => json({})),
      );
      expect(auth.session, isNull);
      expect(store.session, isNull);
    });

    test('退出：先清本地，网络不通也能退出', () async {
      var logoutCalled = false;
      final auth = await signedIn(
        MockClient((req) async {
          logoutCalled = req.url.path.endsWith('/auth/logout');
          throw const SocketException('offline');
        }),
      );
      await auth.logout();
      expect(logoutCalled, isTrue);
      expect(auth.session, isNull);
      expect(store.session, isNull);
    });
  });

  group('邀请', () {
    test('读取邀请信息并设置密码登录；服务器取自参数或上次登录', () async {
      final store = MemoryTokenStore()..server = 'h.local';
      final urls = <String>[];
      final client = MockClient((req) async {
        urls.add('${req.method} ${req.url}');
        if (req.method == 'GET') {
          return json({
            'handle': 'linyue',
            'name': '林悦',
            'expires_at': '2026-11-11T00:00:00Z',
          });
        }
        return json(loginOk());
      });
      final auth = await LiveAuthRepository.restore(store, client: client);
      final info = await auth.invite('tok');
      expect((info.name, info.handle), ('林悦', '@linyue'));
      await auth.acceptInvite('tok', 'a-good-password', server: 'other.local');
      expect(urls, [
        'GET http://h.local/api/v1/auth/invites/tok',
        'POST http://other.local/api/v1/auth/invites/tok/accept',
      ]);
      expect(auth.session!.server, 'other.local');
    });

    test('无效链接返回服务端的说明；密码太短不发请求', () async {
      var calls = 0;
      final auth = await LiveAuthRepository.restore(
        MemoryTokenStore()..server = 'h.local',
        client: MockClient((_) async {
          calls++;
          return error(404, 'not_found', '邀请链接无效或已过期，请联系管理员重新邀请');
        }),
      );
      await expectLater(
        auth.invite('bad'),
        throwsA(
          isA<AuthException>().having((e) => e.code, 'code', 'not_found'),
        ),
      );
      await expectLater(
        auth.acceptInvite('bad', 'short'),
        throwsA(
          isA<AuthException>().having((e) => e.message, 'message', '密码至少 8 位'),
        ),
      );
      expect(calls, 1);
    });
  });
}
