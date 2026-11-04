import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/features/auth/login_page.dart';
import 'package:uniconsole/features/devices/devices_page.dart';

import 'helpers.dart';

/// 登录页、邀请页、退出登录与路由守卫。
void main() {
  String location(WidgetTester tester) =>
      GoRouter.of(tester.element(find.byType(Navigator).first))
          .routeInformationProvider
          .value
          .uri
          .toString();

  Future<void> type(WidgetTester tester, String semantic, String text) async {
    final field = find.descendant(
      of: find.bySemanticsLabel(semantic),
      matching: find.byType(TextField),
    );
    await tester.enterText(field.first, text);
    await tester.pump();
  }

  for (final width in [1440.0, 390.0]) {
    testWidgets('未登录打开其他页面跳到登录页，登录后回到原页面（$width）', (tester) async {
      await open(
        tester,
        location: '/alerts',
        width: width,
        height: 900,
        signedIn: false,
      );
      expect(find.byType(LoginPage), findsOneWidget);
      expect(location(tester), startsWith('/login?from='));

      await type(tester, '账号', '@linyue');
      await type(tester, '密码', MockAuthRepository.demoPassword);
      await tapText(tester, '登录');
      await settle(tester);
      expect(find.byType(LoginPage), findsNothing);
      expect(location(tester), '/alerts');
      await close(tester);
    });
  }

  testWidgets('密码错误显示提示；二次验证要输入验证码', (tester) async {
    await open(tester, location: '/devices', signedIn: false);
    await type(tester, '账号', 'kanade');
    await type(tester, '密码', 'wrong-pass');
    await tapText(tester, '登录');
    expect(find.text('账号或密码错误'), findsOneWidget);

    await type(tester, '密码', MockAuthRepository.demoPassword);
    await tapText(tester, '登录');
    expect(find.textContaining('开启了二次验证'), findsOneWidget);

    await type(tester, '二次验证码', '000000');
    await settle(tester);
    expect(find.text('二次验证码错误'), findsOneWidget);

    await type(tester, '二次验证码', MockAuthRepository.demoCode);
    await settle(tester);
    expect(find.byType(DevicesPage), findsOneWidget);
    await close(tester);
  });

  testWidgets('设置里退出登录后回到登录页', (tester) async {
    final container = await open(tester, location: '/settings/account');
    final button = find.widgetWithText(DestructiveButton, '退出登录');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settle(tester);
    expect(find.text('退出登录？'), findsOneWidget);
    // 确认框里的「退出登录」是最后一个。
    await tester.tap(find.text('退出登录').last);
    await settle(tester);
    expect(container.read(authRepositoryProvider).session, isNull);
    expect(find.byType(LoginPage), findsOneWidget);
    await close(tester);
  });

  testWidgets('邀请页：两次密码不一致时提示，设置后进入设备总览', (tester) async {
    await open(tester, location: '/invite/demo', signedIn: false);
    expect(find.text('为 王宁（@wangning）设置登录密码'), findsOneWidget);
    await type(tester, '新密码', 'a-good-password');
    await type(tester, '再次输入新密码', 'another-password');
    await tapText(tester, '设置密码并登录');
    expect(find.text('两次输入的密码不一致'), findsOneWidget);

    await type(tester, '再次输入新密码', 'a-good-password');
    await tapText(tester, '设置密码并登录');
    await settle(tester);
    expect(find.byType(DevicesPage), findsOneWidget);
    await close(tester);
  });

  testWidgets('无效的邀请链接提示并可前往登录', (tester) async {
    await open(tester, location: '/invite/nope', signedIn: false);
    expect(find.textContaining('邀请链接无效或已过期'), findsOneWidget);
    await tapText(tester, '前往登录');
    expect(find.byType(LoginPage), findsOneWidget);
    await close(tester);
  });

  for (final width in [320.0, 390.0, 768.0, 1000.0, 1440.0]) {
    testWidgets('登录页与邀请页在 $width 宽度下不溢出', (tester) async {
      for (final loc in ['/login', '/invite/demo']) {
        await open(
          tester,
          location: loc,
          width: width,
          height: 640,
          signedIn: false,
        );
        expect(tester.takeException(), isNull);
        await close(tester);
      }
    });
  }
}
