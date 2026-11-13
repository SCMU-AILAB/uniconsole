import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/features/control/control_input.dart';
import 'package:uniconsole/features/control/control_page.dart';
import 'package:uniconsole/features/devices/device_detail_page.dart';
import 'package:uniconsole/features/devices/device_inspector.dart';
import 'package:uniconsole/features/devices/device_widgets.dart';
import 'package:uniconsole/features/devices/devices_page.dart';
import 'package:uniconsole/features/sensors/sensors_page.dart';
import 'package:uniconsole/main.dart';

/// 打开应用；流式页面（操控、感知）不能 pumpAndSettle，用 [settle] = false。
Future<ProviderContainer> open(
  WidgetTester tester, {
  required String location,
  double width = 1440,
  double height = 900,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 容器由 ProviderScope 持有：卸载界面即释放，遥测与租约定时器随之停止。
  await tester.pumpWidget(
    ProviderScope(child: UniConsoleApp(initialLocation: location)),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(UniConsoleApp)),
  );
  container.read(themeModeProvider.notifier).set(ThemeMode.light);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // 流式页面：逐帧推进，让各级数据流（租约 → 成员名 → 界面）都有机会重建。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  return container;
}

/// 卸载应用（同时释放容器），让订阅与定时器收尾。
Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('设备总览', () {
    testWidgets('统计数字与设计稿一致：8 台 / 6 在线 / 1 告警 / 3 控制会话', (tester) async {
      await open(tester, location: Routes.devices);
      String valueOf(String label) => tester
          .widget<StatTile>(
            find.byWidgetPredicate((w) => w is StatTile && w.label == label),
          )
          .value;
      expect(valueOf('设备总数'), '8');
      expect(valueOf('在线'), '6');
      expect(valueOf('告警'), '1');
      expect(valueOf('控制会话'), '3');
      expect(find.text('Charlie · 左后腿电机过热'), findsOneWidget);
    });

    testWidgets('筛选「告警」只剩 Charlie；搜索使用者姓名；切换列表视图', (tester) async {
      await open(tester, location: Routes.devices);
      expect(find.byType(DeviceCard), findsNWidgets(8));

      await tester.tap(find.bySemanticsLabel('告警').first);
      await tester.pumpAndSettle();
      expect(find.byType(DeviceCard), findsOneWidget);
      expect(find.text('告警设备 · 1'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('全部').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '周明');
      await tester.pumpAndSettle();
      // 周明 管理 Echo / Foxtrot，正在使用 Charlie / Echo。
      expect(find.byType(DeviceCard), findsNWidgets(3));

      await tester.tap(find.bySemanticsLabel('列表视图'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceCard), findsNothing);
      expect(find.byType(AppDataTable), findsOneWidget);
    });

    testWidgets('点击卡片：检查器切换到该设备，显示设备信息与最近事件', (tester) async {
      await open(tester, location: Routes.devices);
      expect(
        find.descendant(
          of: find.byType(DeviceInspector),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.bySemanticsLabel(RegExp('^Charlie，')));
      await tester.pumpAndSettle();
      final inspector = find.byType(DeviceInspector);
      expect(
        find.descendant(of: inspector, matching: find.text('Charlie')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inspector, matching: find.text('GO2E-24A0166')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: inspector,
          matching: find.text('左后腿 RL_calf 电机温度超过阈值'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('移动端：设备列表 → 推入设备详情（‹ 设备 返回）', (tester) async {
    await open(tester, location: Routes.devices, width: 390, height: 844);
    expect(find.text('8 台设备 · 按状态排序'), findsOneWidget);
    await tester.tap(find.text('Bravo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(DeviceDetailPage), findsOneWidget);
    expect(find.bySemanticsLabel('返回设备'), findsOneWidget);
    expect(find.text('横屏操控'), findsOneWidget);
    await close(tester);
  });

  group('单机操控', () {
    testWidgets('摇杆发送 move，设备开始移动；松开 300 ms 后发送 stop（§8.4）', (tester) async {
      final container = await open(
        tester,
        location: Routes.control('go2-02'),
        settle: false,
      );
      // Bravo 空闲：先申请控制权。
      await tester.tap(find.bySemanticsLabel('申请控制权').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(holdsLeaseProvider('go2-02')), isTrue);

      final stick = find.bySemanticsLabel(RegExp('^移动摇杆'));
      final center = tester.getCenter(stick);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(0, -40));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        container.read(telemetryProvider('go2-02')).value!.vx,
        greaterThan(0.2),
      );

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      var log = container.read(commandLogProvider('go2-02')).value!;
      expect(
        log.first.text,
        isNot(contains('StopMove')),
        reason: '松开后 300 ms 内还不发 stop',
      );
      await tester.pump(const Duration(milliseconds: 300));
      log = container.read(commandLogProvider('go2-02')).value!;
      expect(log.first.text, contains('StopMove'));
      await close(tester);
    });

    testWidgets('键盘 W 前进；空格急停后运动控件全部禁用，「趴下」同样禁用', (tester) async {
      final container = await open(
        tester,
        location: Routes.control('go2-01'),
        settle: false,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 200));
      expect(container.read(controlInputProvider('go2-01')).move.dy, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(estopProvider('go2-01')).value, isTrue);
      expect(find.textContaining('已触发急停'), findsOneWidget);
      final stick = tester.widget<Joystick>(
        find.byWidgetPredicate(
          (w) => w is Joystick && w.semanticLabel == '移动摇杆',
        ),
      );
      expect(stick.onChanged, isNull);
      Widget mode(String label) => tester.widget(
        find.byWidgetPredicate(
          (w) =>
              (w is PrimaryButton && w.label == label) ||
              (w is SecondaryButton && w.label == label),
        ),
      );
      expect((mode('行走') as dynamic).onPressed, isNull);
      expect((mode('趴下') as dynamic).onPressed, isNull);

      // 再按一次空格解除。
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(estopProvider('go2-01')).value, isFalse);
      await close(tester);
    });

    testWidgets('窗口失去焦点后清空按键并停止，恢复焦点不重放输入', (tester) async {
      final container = await open(
        tester,
        location: Routes.control('go2-01'),
        settle: false,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(controlInputProvider('go2-01')).active, true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(container.read(controlInputProvider('go2-01')).active, false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(controlInputProvider('go2-01')).active, false);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await close(tester);
    });

    testWidgets('没有控制权：只读提示，申请后进入排队（§8.2）', (tester) async {
      await open(tester, location: Routes.control('go2-03'), settle: false);
      expect(find.text('你没有控制权 · 当前为只读观看'), findsOneWidget);
      expect(find.text('只读 · 周明 持有控制权'), findsOneWidget);
      final stick = tester.widget<Joystick>(
        find.byWidgetPredicate(
          (w) => w is Joystick && w.semanticLabel == '移动摇杆',
        ),
      );
      expect(stick.onChanged, isNull);

      await tester.tap(find.bySemanticsLabel('申请控制权').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('已申请控制权'), findsOneWidget);
      await close(tester);
    });

    testWidgets('持有控制权时显示租约倒计时', (tester) async {
      await open(tester, location: Routes.control('go2-01'), settle: false);
      expect(
        find.textContaining(RegExp(r'你持有控制权 · 租约 \d+:\d{2} 后自动续期')),
        findsOneWidget,
      );
      await close(tester);
    });

    testWidgets('移动端横屏操控：全屏无标签栏，圆形 STOP', (tester) async {
      await open(
        tester,
        location: Routes.control('go2-01'),
        width: 844,
        height: 390,
        settle: false,
      );
      // 桌面平台下 844 宽不是移动布局；用窄窗口（390 × 844）检查等比缩放的横屏界面。
      await close(tester);
      await open(
        tester,
        location: Routes.control('go2-01'),
        width: 390,
        height: 844,
        settle: false,
      );
      expect(find.byType(MobileTabBar), findsNothing);
      expect(find.text('STOP'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });

    testWidgets('移动端从标签栏进入操控：返回按钮回到设备详情，不会困在全屏页', (tester) async {
      await open(tester, location: Routes.devices, width: 390, height: 844);
      await tester.tap(find.bySemanticsLabel('操控'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('STOP'), findsOneWidget);
      expect(find.byType(MobileTabBar), findsNothing);

      await tester.tap(find.bySemanticsLabel('返回'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(DeviceDetailPage), findsOneWidget);
      expect(find.byType(MobileTabBar), findsOneWidget);
      await close(tester);
    });
  });

  group('感知中心', () {
    testWidgets('点云、四路摄像头、话题健康；暂停画面冻结时间戳', (tester) async {
      await open(tester, location: Routes.sensors('go2-01'), settle: false);
      expect(find.text('激光雷达 · 点云'), findsOneWidget);
      expect(find.text('[前置 RGB画面]'), findsOneWidget);
      expect(find.text('rt/odom'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('暂停画面'));
      await tester.pump();
      final frozen = find.textContaining('已暂停 ·');
      expect(frozen, findsOneWidget);
      final text = tester.widget<Text>(frozen).data;
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(find.textContaining('已暂停 ·')).data, text);
      await close(tester);
    });

    testWidgets('离线设备：提示离线，不报错', (tester) async {
      await open(tester, location: Routes.sensors('h1-01'), settle: false);
      expect(find.text('Golf 离线 · 没有实时传感器数据'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  });

  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    testWidgets('第 3 阶段页面在 ${width.toInt()} 宽下无溢出', (tester) async {
      for (final loc in [
        Routes.devices,
        Routes.device('go2-01'),
        Routes.control('go2-01'),
        Routes.sensors('go2-01'),
      ]) {
        await open(tester, location: loc, width: width, settle: false);
        expect(tester.takeException(), isNull, reason: loc);
        await close(tester);
      }
      expect(find.byType(SensorsPage), findsNothing);
      expect(find.byType(DevicesPage), findsNothing);
      expect(find.byType(ControlPage), findsNothing);
    });
  }
}
