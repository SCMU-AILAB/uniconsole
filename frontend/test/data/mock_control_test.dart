import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/repositories/repositories.dart';

/// mock 数据层遵守 API.md 与 HANDOFF §8 的规则。
void main() {
  late MockWorld world;
  setUp(() => world = MockWorld(telemetryHz: 50));

  Future<Telemetry> nextAfter(String id, Duration wait) async {
    await Future<void>.delayed(wait);
    return world.fleet.watch(id).first;
  }

  test('持有控制权时 move 生效；300 ms 内没有新指令自动停止（看门狗）', () async {
    // Bravo 空闲，先申请控制权。
    expect(await world.leases.acquire('go2-02'), LeaseRequestResult.granted);
    final sub = world.fleet.watch('go2-02').listen((_) {});
    world.fleet.move('go2-02', 0.8, 0, 0);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    world.fleet.move('go2-02', 0.8, 0, 0);
    final moving = await nextAfter('go2-02', const Duration(milliseconds: 100));
    expect(moving.vx, greaterThan(0.3));

    final stopped = await nextAfter(
      'go2-02',
      const Duration(milliseconds: 900),
    );
    expect(stopped.vx.abs(), lessThan(0.05));
    await sub.cancel();
  });

  test('没有控制权：指令被拒绝（403 forbidden），设备不动', () async {
    // Charlie 由周明持有。
    final result = await world.fleet.send(
      'go2-03',
      const SetModeCommand(MotionMode.stand),
    );
    expect(result.error, CommandError.forbidden);
    world.fleet.move('go2-03', 1, 0, 0);
    expect(world.fleet.robot('go2-03')!.mode, MotionMode.walk);
  });

  test('急停：运动指令被拒绝（423），趴下仍允许；任何人都能触发急停', () async {
    await world.fleet.setEstop('go2-03', active: true); // 不需要控制权
    expect(await world.fleet.watchEstop('go2-03').first, isTrue);

    await world.fleet.setEstop('go2-01', active: true);
    final walk = await world.fleet.send(
      'go2-01',
      const SetModeCommand(MotionMode.walk),
    );
    expect(walk.error, CommandError.estopActive);
    final down = await world.fleet.send(
      'go2-01',
      const SetModeCommand(MotionMode.down),
    );
    expect(down.ok, isTrue);

    final log = await world.fleet.watchLog('go2-01').first;
    expect(log.first.text, contains('SwitchGait(down)'));
    expect(log[1].ok, isFalse);
  });

  test('控制权：被占用时进入申请队列；释放后可直接获得', () async {
    expect(await world.leases.acquire('go2-03'), LeaseRequestResult.queued);
    expect(world.leases.lease('go2-03')!.queue.last.userId, 'kanade');

    await world.leases.release('go2-01');
    expect(world.leases.lease('go2-01'), isNull);
    expect(await world.leases.acquire('go2-01'), LeaseRequestResult.granted);
    expect(world.leases.holds('go2-01'), isTrue);
  });

  test('离线设备：不推送遥测，指令返回 robot_offline', () async {
    final result = await world.fleet.send('h1-01', const StopCommand());
    expect(result.error, CommandError.robotOffline);
    expect(await world.fleet.watch('h1-01').isEmpty, isTrue);
  });
}
