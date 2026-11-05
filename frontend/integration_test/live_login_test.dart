import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uniconsole/data/api/live_auth_repository.dart';
import 'package:uniconsole/data/api/token_store.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/features/auth/login_page.dart';
import 'package:uniconsole/features/devices/devices_page.dart';
import 'package:uniconsole/main.dart';

/// 在真机 / 桌面应用里对真实服务端登录：验证网络权限与系统钥匙串。
///
/// ```
/// flutter test integration_test -d macos \
///   --dart-define=E2E_SERVER=127.0.0.1:8080 \
///   --dart-define=E2E_HANDLE=admin --dart-define=E2E_PASSWORD=…
/// ```
const _server = String.fromEnvironment('E2E_SERVER');
const _handle = String.fromEnvironment('E2E_HANDLE');
const _password = String.fromEnvironment('E2E_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('登录页 → 真实服务端 → 令牌写入钥匙串 → 重启恢复 → 退出清除', (tester) async {
    final store = SecureTokenStore();
    await store.clearSession();
    final auth = await LiveAuthRepository.restore(store);
    expect(auth.session, isNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [authRepositoryProvider.overrideWithValue(auth)],
        child: const UniConsoleApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);

    Finder field(String label) => find.descendant(
      of: find.bySemanticsLabel(label),
      matching: find.byType(TextField),
    );
    await tester.enterText(field('服务器地址'), _server);
    await tester.enterText(field('账号'), _handle);
    await tester.enterText(field('密码'), _password);
    await tester.tap(find.text('登录'));
    for (
      var i = 0;
      i < 50 && find.byType(DevicesPage).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(DevicesPage), findsOneWidget);

    // 钥匙串里有会话；模拟重启后能恢复。
    final saved = await store.readSession();
    expect(saved?['token'], isNotEmpty);
    expect(await store.readServer(), _server);
    final restarted = await LiveAuthRepository.restore(store);
    expect(restarted.session?.token, auth.session!.token);
    await restarted.refresh();
    expect(restarted.session, isNotNull);

    await auth.logout();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LoginPage), findsOneWidget);
    expect(await store.readSession(), isNull);
  }, skip: _server.isEmpty);
}
