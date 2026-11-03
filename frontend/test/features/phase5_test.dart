import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/data/mock/mock_data_ops.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/features/maintenance/maintenance_widgets.dart';

import 'helpers.dart';

/// 今日已执行：开始时间已过的巡检排期块（与页面同一规则）。
/// 回放控制条上的「当前 / 总长」（Charlie 过热前后共 38 分钟）。
Finder at(String t) => find.text('$t / 00:38:00', findRichText: true);

int runsToday() => MockOpsData.schedule()
    .where(
      (b) => b.kind == ScheduleKind.run && !b.start.isAfter(DateTime.now()),
    )
    .length;

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

  group('地图与任务', () {
    testWidgets('默认选中巡检路线 B-2 第 3 个点位；统计来自同一数据源', (tester) async {
      await open(tester, location: Routes.missions);
      expect(
        find.text('3 张地图 · 4 个任务 · 今日已执行 ${runsToday()} 次'),
        findsOneWidget,
      );
      expect(find.text('B-2-03 · 配电仪表'), findsOneWidget);
      expect(find.text('(10.9 m, 4.4 m)'), findsOneWidget);
      expect(find.text('8 个点位 · 全长 56 m · 预计 18 分钟'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(RegExp('^点位 5 ')));
      await settle(tester);
      expect(find.text('B-2-05 · 窗户'), findsOneWidget);
      await close(tester);
    });

    testWidgets('添加点位：点按地图追加到末尾并选中', (tester) async {
      final container = await open(tester, location: Routes.missions);
      await tapText(tester, '添加点位');
      final map = tester.getRect(find.byType(FloorMapView));
      await tester.tapAt(
        map.topLeft + Offset(map.width * 0.5, map.height * 0.9),
      );
      await settle(tester);
      final m = container
          .read(missionsProvider)
          .value!
          .firstWhere((m) => m.id == 'patrol-b2');
      expect(m.waypoints, hasLength(9));
      expect(find.text('点位 9'), findsWidgets);
      await close(tester);
    });

    testWidgets('拖动点位后坐标随之更新；添加到达后动作', (tester) async {
      final container = await open(tester, location: Routes.missions);
      Offset pos() => container
          .read(missionsProvider)
          .value!
          .firstWhere((m) => m.id == 'patrol-b2')
          .waypoints[2]
          .position;
      final before = pos();
      await tester.drag(
        find.bySemanticsLabel(RegExp('^点位 3 ')),
        const Offset(40, 40),
      );
      await settle(tester);
      expect(pos().dx, greaterThan(before.dx));
      expect(pos().dy, greaterThan(before.dy));

      await tapText(tester, '＋ 添加动作');
      await tapText(tester, '热成像 · 温度 > 45 °C 告警');
      final wp = container
          .read(missionsProvider)
          .value!
          .firstWhere((m) => m.id == 'patrol-b2')
          .waypoints[2];
      expect(wp.actions.last.name, '热成像');
      await close(tester);
    });

    testWidgets('点任务切换地图：仓库夜巡在 C 区仓库', (tester) async {
      await open(tester, location: Routes.missions);
      await tapText(tester, '仓库夜巡 C-1');
      expect(
        tester.widget<FloorMapView>(find.byType(FloorMapView)).semanticLabel,
        '地图 · C 区仓库',
      );
      expect(find.text('起点 · 充电桩 #3'), findsOneWidget);
      await close(tester);
    });
  });

  group('录制与回放', () {
    testWidgets('默认打开第一条录制，停在第一个告警事件；±10 s 与点事件跳转', (tester) async {
      await open(tester, location: Routes.recordings);
      expect(find.text('回放 · Charlie 过热前后'), findsOneWidget);
      expect(at('00:12:42'), findsOneWidget);
      await tapText(tester, '+10 s');
      expect(at('00:12:52'), findsOneWidget);
      await tapText(tester, '过热告警');
      expect(at('00:17:29'), findsOneWidget);
      await close(tester);
    });

    testWidgets('2× 播放：1 秒后前进 2 秒；空格暂停', (tester) async {
      await open(tester, location: Routes.recording('r1'));
      await tapText(tester, '2×');
      await tester.tap(find.bySemanticsLabel('播放'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(at('00:12:44'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(seconds: 1));
      expect(at('00:12:44'), findsOneWidget);
      await close(tester);
    });

    testWidgets('告警的「回放触发前后 60 秒」链接带时间点', (tester) async {
      await open(tester, location: Routes.alerts);
      await tapText(tester, '回放触发前后 60 秒');
      expect(find.text('回放 · Charlie 过热前后'), findsOneWidget);
      expect(at('00:16:29'), findsOneWidget);
      await close(tester);
    });

    testWidgets('搜索录制库；切换录制；剪辑片段另存为新录制', (tester) async {
      final container = await open(tester, location: Routes.recordings);
      await tester.enterText(find.byType(EditableText).first, '联调');
      await settle(tester);
      expect(find.text('巡检 B-2 · 上午'), findsNothing);
      await tapText(tester, '联调会话 #12');
      expect(find.text('回放 · 联调会话 #12'), findsOneWidget);

      await tapText(tester, '剪辑片段');
      await tapText(tester, '另存为片段');
      expect(find.text('回放 · 联调会话 #12 · 片段'), findsOneWidget);
      expect(container.read(recordingsProvider).value, hasLength(5));
      await close(tester);
    });

    testWidgets('手机：录制库列表点开进入回放', (tester) async {
      await open(tester, location: Routes.recordings, width: 390, height: 844);
      await tapText(tester, '步态调试');
      expect(find.text('回放 · 步态调试'), findsWidgets);
      await close(tester);
    });
  });

  group('设备运维', () {
    testWidgets('统计来自同一数据源；立即升级按灰度规则排队', (tester) async {
      final container = await open(tester, location: Routes.maintenance);
      expect(
        find.text('4 台可升级 · 1 台建议更换电池 · 维护窗口 每天 02:00–04:00'),
        findsOneWidget,
      );
      expect(find.text('已选 2 台 · 灰度发布：先升级 1 台，自检通过后其余并行'), findsOneWidget);
      expect(find.text('Delta 预计 3 周后低于 80%，建议安排更换。'), findsOneWidget);

      await tapText(tester, '立即升级');
      await tester.tap(find.widgetWithText(PrimaryButton, '开始升级'));
      await settle(tester);
      final world = container.read(mockWorldProvider);
      // Foxtrot 正在升级（作为灰度），Bravo 排队；Echo 在联调会话中，等任务结束。
      expect(world.maintenance.status('go2-02')!.state, FirmwareState.queued);
      expect(
        world.maintenance.status('g1-01')!.state,
        FirmwareState.waitingTask,
      );
      expect(find.text('排队中 · 等待灰度设备自检通过'), findsOneWidget);
      expect(find.text('已选 0 台 · 灰度发布：先升级 1 台，自检通过后其余并行'), findsOneWidget);
      await close(tester);
    });

    testWidgets('远程终端执行命令；日志按级别筛选', (tester) async {
      await open(tester, location: Routes.maintenance);
      expect(
        find.textContaining('/dev/nvme0n1p3', findRichText: true),
        findsOneWidget,
      );
      final input = find.descendant(
        of: find.byType(TerminalCard),
        matching: find.byType(EditableText),
      );
      await tester.enterText(input, 'uptime');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(
        find.textContaining(' up 3h 12min', findRichText: true),
        findsOneWidget,
      );

      await tapText(tester, 'ERROR');
      expect(find.text('motor[RL_calf] temp 68.2C > 60.0C'), findsOneWidget);
      expect(find.text('gait.switch(low_speed) ok'), findsNothing);
      await close(tester);
    });

    testWidgets('维护窗口设置：改为 03:00 开始', (tester) async {
      await open(tester, location: Routes.maintenance);
      await tapText(tester, '维护窗口设置');
      await tapText(tester, '02:00');
      await tapText(tester, '03:00');
      await tester.tap(find.widgetWithText(PrimaryButton, '保存'));
      await settle(tester);
      expect(find.textContaining('维护窗口 每天 03:00–05:00'), findsOneWidget);
      await close(tester);
    });
  });

  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    testWidgets('第 5 阶段页面在 ${width.toInt()} 宽下无溢出', (tester) async {
      for (final loc in [Routes.alerts, Routes.alert('a1'), Routes.missions]) {
        await open(tester, location: loc, width: width, height: 900);
        expect(tester.takeException(), isNull, reason: loc);
        await close(tester);
      }
      expect(find.byType(SizedBox), findsOneWidget);
    });
  }
}
