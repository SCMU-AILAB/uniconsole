import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/models/models.dart';

/// 第 5 阶段：告警处理、任务点位、录制剪辑、固件灰度升级的规则。
void main() {
  late MockWorld world;
  setUp(() => world = MockWorld(telemetryHz: 50));
  tearDown(() => world.dispose());

  group('告警', () {
    test('确认：未处理变为处理中，处理人为当前用户，写入时间线', () async {
      await world.alerts.acknowledge('a2');
      final a = world.alerts.alert('a2')!;
      expect(a.state, AlertState.doing);
      expect(a.assigneeId, 'kanade');
      expect(a.events.last.message, contains('Kanade 已确认'));
    });

    test('关闭必须填写备注；关闭后可以重新打开', () async {
      expect(
        () => world.alerts.close('a1', note: '  '),
        throwsA(isA<ArgumentError>()),
      );
      await world.alerts.close('a1', note: '已更换散热风扇');
      expect(world.alerts.alert('a1')!.state, AlertState.closed);
      expect(
        world.alerts.alert('a1')!.events.last.message,
        'Kanade 关闭：已更换散热风扇',
      );
      await world.alerts.reopen('a1');
      expect(world.alerts.alert('a1')!.state, AlertState.open);
    });

    test('指派与静默', () async {
      await world.alerts.assign('a3', 'linyue');
      expect(world.alerts.alert('a3')!.assigneeId, 'linyue');
      expect(world.alerts.alert('a3')!.state, AlertState.doing);
      await world.alerts.silence('a3', const Duration(minutes: 30));
      expect(world.alerts.alert('a3')!.silencedAt(DateTime.now()), isTrue);
      await world.alerts.silence('a3', null);
      expect(world.alerts.alert('a3')!.silencedAt(DateTime.now()), isFalse);
    });

    test('远程趴下走急停通道：不需要控制权', () async {
      expect(world.leases.holds('go2-03'), isFalse);
      await world.alerts.remoteDown('a1');
      expect(world.fleet.robot('go2-03')!.estop, isTrue);
      expect(world.alerts.alert('a1')!.events.last.tone, EventTone.critical);
    });

    test('规则：开关与新建', () async {
      await world.alerts.setRuleEnabled('ack', enabled: true);
      var rules = await world.alerts.watchRules().first;
      expect(rules.firstWhere((r) => r.id == 'ack').enabled, isTrue);
      await world.alerts.addRule(
        name: '电压过低',
        metric: AlertMetric.voltage,
        op: '<',
        threshold: 24,
        duration: const Duration(seconds: 30),
        severity: AlertSeverity.warning,
        autoAction: '自动回桩',
      );
      rules = await world.alerts.watchRules().first;
      expect(rules.last.summary, '电压 < 24 V 持续 30 秒 · 警告 · 自动回桩');
    });

    test('曲线：阈值在 70，严重告警的末端超过阈值', () async {
      final h = await world.alerts.history('a1');
      expect(h.values, hasLength(61));
      expect(h.values.last, greaterThan(h.threshold));
    });
  });

  group('地图与任务', () {
    test('三张地图；配电柜围栏只在 B 区巡检层', () async {
      final maps = await world.missions.watchMaps().first;
      expect(maps.map((m) => m.shortName), ['B 区巡检层', '展厅 1F', 'C 区仓库']);
      final b = await world.safety.watchZones(mapId: 'b-patrol').first;
      expect(b.map((z) => z.name), ['配电柜']);
      expect(await world.safety.watchZones().first, hasLength(4));
    });

    test('修改点位后已完成数不超过点位数', () async {
      final m = world.missions.mission('patrol-b2')!;
      await world.missions.setWaypoints(
        'patrol-b2',
        m.waypoints.take(2).toList(),
      );
      final next = world.missions.mission('patrol-b2')!;
      expect(next.waypoints, hasLength(2));
      expect(next.completed, 2);
    });

    test('新建任务、放置充电桩、在指定地图上新建禁行区', () async {
      final id = await world.missions.addMission('夜间巡检 B-3', 'b-patrol');
      expect(world.missions.mission(id)!.state, MissionState.paused);
      await world.missions.addCharger('b-patrol', const Offset(80, 82));
      expect(world.missions.map('b-patrol')!.chargers, hasLength(2));
      await world.safety.addZone(
        ZoneType.ban,
        mapId: 'b-patrol',
        rect: const Rect.fromLTWH(40, 80, 10, 8),
      );
      final b = await world.safety.watchZones(mapId: 'b-patrol').first;
      expect(b.last.name, '禁入区 2');
    });

    test('重新建图：建图任务转为运行中', () async {
      await world.missions.remap('b-patrol');
      expect(world.missions.mission('remap-b')!.state, MissionState.running);
    });
  });

  group('录制与回放', () {
    test('剪辑：截取区间内的事件，另存为新录制并计入存储', () async {
      final before = await world.recordings.watchStorage().first;
      final id = await world.recordings.clip(
        'r1',
        const Duration(minutes: 12),
        const Duration(minutes: 20),
      );
      final clip = world.recordings.recording(id)!;
      expect(clip.duration, const Duration(minutes: 8));
      expect(clip.events.map((e) => e.label), ['温度 > 60 °C', '过热告警', '自动降速']);
      expect(clip.events.first.offset, const Duration(seconds: 42));
      final after = await world.recordings.watchStorage().first;
      expect(after.usedBytes, greaterThan(before.usedBytes));
    });

    test('导出文件名与分享链接带时间点', () async {
      expect(
        await world.recordings.export('r1', ExportFormat.mcap),
        endsWith('.mcap'),
      );
      expect(
        world.recordings.shareLink(
          'r1',
          const Duration(minutes: 12, seconds: 41),
        ),
        endsWith('/recordings/r1?t=761'),
      );
    });
  });

  group('设备运维', () {
    test('初始状态与设计稿一致', () {
      FirmwareState st(String id) => world.maintenance.status(id)!.state;
      expect(st('go2-01'), FirmwareState.waitingTask);
      expect(st('go2-02'), FirmwareState.available);
      expect(st('go2-03'), FirmwareState.failed);
      expect(st('b2-01'), FirmwareState.latest);
      expect(st('go2-04'), FirmwareState.upgrading);
      expect(world.maintenance.status('go2-04')!.progress, 0.62);
      expect(st('go2-05'), FirmwareState.waitingOnline);
    });

    test('灰度升级：会话中的设备等任务结束，其余排队，正在升级的完成后并行', () async {
      await world.maintenance.upgrade(['go2-02', 'g1-01']);
      FirmwareState st(String id) => world.maintenance.status(id)!.state;
      expect(st('g1-01'), FirmwareState.waitingTask);
      expect(st('go2-02'), FirmwareState.queued);

      // Foxtrot 从 62% 升到 100%，自检通过后 Bravo 开始升级。
      for (var i = 0; i < 20; i++) {
        world.maintenance.advance();
      }
      expect(st('go2-04'), FirmwareState.latest);
      expect(world.devices.device('go2-04')!.firmware, 'v1.1.8');
      expect(st('go2-02'), FirmwareState.upgrading);
      final logs = await world.maintenance.watchLogs().first;
      expect(logs.any((e) => e.message.contains('v1.1.8 installed')), isTrue);
    });

    test('电池：Delta 约 3 周后低于 80%', () async {
      final b = await world.maintenance.watchBattery().first;
      final delta = b.firstWhere((x) => x.deviceId == 'b2-01');
      expect(delta.weeksUntil(80)!.round(), 3);
    });

    test('远程终端：离线设备连不上；未知命令报错', () async {
      expect(
        (await world.maintenance.run('go2-05', 'uptime')).single.tone,
        TerminalTone.error,
      );
      final out = await world.maintenance.run('go2-01', 'rm -rf /');
      expect(out.single.text, contains('command not found'));
      final df = await world.maintenance.run('go2-01', 'df -h /data');
      expect(df.last.text, contains('/data'));
    });
  });
}
