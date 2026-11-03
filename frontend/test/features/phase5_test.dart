import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/providers.dart';

import 'helpers.dart';

void main() {
  group('告警中心', () {
    testWidgets('统计与列表来自同一数据源；筛选「未处理」只剩 2 条', (tester) async {
      await open(tester, location: Routes.alerts);
      expect(find.text('2 条未处理 · 1 条处理中 · 近 7 天 5 条'), findsOneWidget);
      expect(find.text('定位置信度下降'), findsOneWidget);
      expect(find.text('跌倒检测触发'), findsOneWidget);

      await tapText(tester, '未处理');
      expect(find.text('跌倒检测触发'), findsNothing);
      expect(find.text('定位置信度下降'), findsOneWidget);
      expect(find.text('离线超过 24 小时'), findsWidgets);
      await close(tester);
    });

    testWidgets('选中 → 确认处理 → 填写备注后关闭；时间线随之增加', (tester) async {
      final container = await open(tester, location: Routes.alerts);
      await tapText(tester, '定位置信度下降');
      await tapText(tester, '确认处理');
      expect(container.read(alertProvider('a2'))!.state, AlertState.doing);
      expect(find.text('Kanade 已确认，状态变为处理中'), findsOneWidget);

      // 关闭需要备注：空备注时按钮不可用。
      PrimaryButton closeButton() => tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, '关闭告警'),
      );
      expect(closeButton().onPressed, isNull);
      await tester.enterText(
        find.byType(EditableText).last,
        '重新扫描走廊，置信度恢复到 0.9',
      );
      await settle(tester);
      expect(closeButton().onPressed, isNotNull);
      await tapText(tester, '关闭告警');
      expect(container.read(alertProvider('a2'))!.state, AlertState.closed);
      expect(find.text('Kanade 关闭：重新扫描走廊，置信度恢复到 0.9'), findsOneWidget);
      expect(find.text('1 条未处理 · 1 条处理中 · 近 7 天 5 条'), findsOneWidget);
      await close(tester);
    });

    testWidgets('远程趴下需确认，经急停通道下发', (tester) async {
      final container = await open(tester, location: Routes.alerts);
      await tapText(tester, '远程趴下');
      expect(find.text('远程趴下 Charlie？'), findsOneWidget);
      await tester.tap(find.widgetWithText(DestructiveButton, '远程趴下').last);
      await settle(tester);
      expect(
        container.read(mockWorldProvider).fleet.robot('go2-03')!.estop,
        isTrue,
      );
      expect(find.text('Charlie 已远程趴下'), findsOneWidget);
      await close(tester);
    });

    testWidgets('规则开关；新建规则', (tester) async {
      final container = await open(tester, location: Routes.alerts);
      bool ack() => container
          .read(alertRulesProvider)
          .value!
          .firstWhere((r) => r.id == 'ack')
          .enabled;
      expect(ack(), isFalse);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is AppSwitch && w.semanticLabel == '指令超时',
        ),
      );
      await settle(tester);
      expect(ack(), isTrue);

      await tapText(tester, '新建规则');
      final fields = find.descendant(
        of: find.byWidgetPredicate((w) => w is AppAlert),
        matching: find.byType(EditableText),
      );
      await tester.enterText(fields.first, '电机温度偏高');
      await tester.enterText(fields.at(1), '55');
      await settle(tester);
      await tester.tap(find.widgetWithText(PrimaryButton, '新建'));
      await settle(tester);
      expect(find.text('电机温度偏高'), findsOneWidget);
      expect(find.text('电机温度 > 55 °C 持续 10 秒 · 警告'), findsOneWidget);
      await close(tester);
    });

    testWidgets('手机：列表点开进入告警详情，确认后变为「已确认」', (tester) async {
      final container = await open(
        tester,
        location: Routes.alerts,
        width: 390,
        height: 844,
      );
      await tapText(tester, '定位置信度下降');
      expect(find.text('告警详情'), findsWidgets);
      await tapText(tester, '确认处理');
      expect(container.read(alertProvider('a2'))!.state, AlertState.doing);
      expect(find.text('已确认'), findsOneWidget);
      expect(find.text('处理中 · 你'), findsOneWidget);
      await close(tester);
    });
  });

  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    testWidgets('第 5 阶段页面在 ${width.toInt()} 宽下无溢出', (tester) async {
      for (final loc in [Routes.alerts, Routes.alert('a1')]) {
        await open(tester, location: loc, width: width, height: 900);
        expect(tester.takeException(), isNull, reason: loc);
        await close(tester);
      }
      expect(find.byType(SizedBox), findsOneWidget);
    });
  }
}
