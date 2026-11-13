import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/models/models.dart';

/// 第 4 阶段：控制权、多机联调、安全策略的规则（API.md「控制权 / 多机联调 / 安全」）。
void main() {
  late MockWorld world;
  setUp(() => world = MockWorld(telemetryHz: 50));
  tearDown(() => world.dispose());

  group('控制权', () {
    test('批准申请：控制权转移给申请人，队列清空，原持有者变为只读', () async {
      expect(world.leases.holds('go2-01'), isTrue);
      await world.leases.approve('go2-01', 'r1');
      final l = world.leases.lease('go2-01')!;
      expect(l.holderId, 'linyue');
      expect(l.queue, isEmpty);
      expect(world.leases.holds('go2-01'), isFalse);
      // 已处理的申请不能再处理（409）。
      expect(
        () => world.leases.deny('go2-01', 'r1'),
        throwsA(isA<LeaseException>()),
      );
    });

    test('拒绝申请：持有者不变，申请移出队列', () async {
      await world.leases.deny('go2-01', 'r1');
      expect(world.leases.lease('go2-01')!.holderId, 'kanade');
      expect(world.leases.lease('go2-01')!.queue, isEmpty);
    });

    test('强制收回只允许设备管理者和平台管理员', () async {
      final user = MockWorld(currentUserId: 'chenyi');
      addTearDown(user.dispose);
      await expectLater(
        user.leases.forceRelease('go2-01', reason: '测试'),
        throwsA(
          isA<LeaseException>().having((e) => e.code, 'code', 'forbidden'),
        ),
      );
      await world.leases.forceRelease('go2-03', reason: '电机过热，现场处理');
      expect(world.leases.lease('go2-03'), isNull);
    });

    test('转移给自动任务；联调会话持有的设备不能单独转移', () async {
      await world.leases.transfer(
        'go2-01',
        const LeaseTarget.task('scheduler'),
      );
      expect(world.leases.lease('go2-01')!.holderKind, LeaseHolderKind.task);
      await expectLater(
        world.leases.transfer('g1-01', const LeaseTarget.user('linyue')),
        throwsA(isA<LeaseException>()),
      );
    });
  });

  group('多机联调', () {
    test('加入空闲设备：会话接管控制权；告警 / 充电中的设备不能加入', () async {
      await world.sessions.setParticipant('s12', 'go2-02', joined: true);
      expect(world.leases.heldBySession('go2-02', 's12'), isTrue);
      expect(world.sessions.session('s12')!.deviceIds.last, 'go2-02');

      await expectLater(
        world.sessions.setParticipant('s12', 'go2-03', joined: true),
        throwsA(isA<FleetException>()),
      );
      await expectLater(
        world.sessions.setParticipant('s12', 'b2-01', joined: true),
        throwsA(isA<FleetException>()),
      );
    });

    test('加入自己持有的设备：个人控制权被会话接管；移出后释放', () async {
      await world.sessions.setParticipant('s12', 'go2-01', joined: true);
      expect(world.leases.holds('go2-01'), isFalse);
      expect(world.leases.heldBySession('go2-01', 's12'), isTrue);
      await world.sessions.setParticipant('s12', 'go2-01', joined: false);
      expect(world.leases.lease('go2-01'), isNull);
    });

    test('同步指令：每台设备一条回执；急停的设备拒绝运动指令，趴下同样被拒绝', () async {
      var r = await world.sessions.send(
        's12',
        const SetModeCommand(MotionMode.stand),
        label: '全体站立',
      );
      expect(r.acks.map((a) => a.ok), [true, true]);

      await world.fleet.setEstop('go2-04', active: true);
      r = await world.sessions.send(
        's12',
        const SetModeCommand(MotionMode.stand),
        label: '全体站立',
      );
      expect(r.acks.last.error, CommandError.estopActive);
      r = await world.sessions.send(
        's12',
        const SetModeCommand(MotionMode.down),
        label: '全体趴下',
      );
      expect(r.acks.last.error, CommandError.estopActive);
      expect(world.sessions.session('s12')!.lastReceipt!.label, '全体趴下');
    });

    test('按预设发起：任一设备不可用则整体失败；正在运行的预设直接返回该会话', () async {
      await expectLater(
        world.sessions.start(presetId: 'p-warehouse'),
        throwsA(
          isA<FleetException>().having(
            (e) => e.deviceIds,
            'deviceIds',
            containsAll(['go2-03', 'b2-01']),
          ),
        ),
      );
      expect(await world.sessions.start(presetId: 'p-welcome'), 's12');
    });

    test('结束会话：停止并释放所有设备的租约', () async {
      await world.sessions.end('s12');
      expect(world.sessions.session('s12'), isNull);
      expect(world.leases.lease('g1-01'), isNull);
      expect(world.leases.lease('go2-04'), isNull);
    });

    test('只有发起人和平台管理员可以操作会话', () async {
      final owner = MockWorld(currentUserId: 'linyue');
      addTearDown(owner.dispose);
      await expectLater(
        owner.sessions.setFormation('s12', Formation.line),
        throwsA(isA<FleetException>()),
      );
      await world.sessions.setFormation('s12', Formation.line);
      expect(world.sessions.session('s12')!.formation, Formation.line);
    });
  });

  group('安全策略', () {
    test('全局急停：所有在线设备急停、会话暂停；解除按策略需要管理者', () async {
      final user = MockWorld(currentUserId: 'chenyi');
      addTearDown(user.dispose);
      // 任何人都能触发。
      await user.safety.setGlobalEstop(active: true);
      expect(user.safety.state.globalEstop, isTrue);
      expect(user.safety.state.estopBy, '陈一');
      for (final id in [
        'go2-01',
        'go2-02',
        'go2-03',
        'b2-01',
        'g1-01',
        'go2-04',
      ]) {
        expect(user.fleet.robot(id)!.estop, isTrue, reason: id);
      }
      expect(user.sessions.session('s12')!.paused, isTrue);
      await expectLater(
        user.safety.setGlobalEstop(active: false),
        throwsA(isA<LeaseException>()),
      );

      await world.safety.setGlobalEstop(active: true);
      await world.safety.setGlobalEstop(active: false);
      expect(world.fleet.robot('go2-01')!.estop, isFalse);
      expect(world.sessions.session('s12')!.paused, isFalse);
    });

    test('围栏：新建、拖动后更新、删除', () async {
      final id = await world.safety.addZone(ZoneType.ban);
      var zones = await world.safety.watchZones().first;
      expect(zones, hasLength(5));
      final z = zones.last;
      expect(z.id, id);
      expect(z.name, '禁入区 3');
      await world.safety.updateZone(
        z.copyWith(rect: const Rect.fromLTWH(10, 10, 20, 20)),
      );
      zones = await world.safety.watchZones().first;
      expect(zones.last.rect.width, 20);
      await world.safety.deleteZone(id);
      expect(await world.safety.watchZones().first, hasLength(4));
    });

    test('急停演练：所有在线设备都有响应时间，并更新演练日期', () async {
      final r = await world.safety.runDrill();
      expect(r.responses, hasLength(6));
      expect(world.safety.state.lastDrillAt, r.at);
    });
  });
}
