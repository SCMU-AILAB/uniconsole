import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/repositories/repositories.dart';

/// 第 6 阶段：成员与审计、智能体计划、对讲、偏好。
void main() {
  late MockWorld world;
  setUp(() => world = MockWorld(telemetryHz: 50));
  tearDown(() => world.dispose());

  Future<List<AuditEntry>> audit() => world.members.watchAudit().first;

  group('成员与权限', () {
    test('示例成员与设计稿一致：5 人 4 种角色', () {
      final m = world.members.members;
      expect(m.map((m) => m.name), ['Kanade', '林悦', '周明', '陈一', '展厅访客']);
      expect(m.map((m) => m.role).toSet(), MemberRole.values.toSet());
    });

    test('邀请成员写入审计日志；账号重复返回 conflict', () async {
      await world.members.invite(
        const MemberDraft(name: '王五', handle: 'wangwu', role: MemberRole.user),
      );
      expect(world.members.members.last.handle, '@wangwu');
      expect((await audit()).first.action, '邀请 王五 为使用者，长期有效');
      await expectLater(
        world.members.invite(
          const MemberDraft(
            name: '王五',
            handle: '@wangwu',
            role: MemberRole.user,
          ),
        ),
        throwsA(
          isA<MemberException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
    });

    test('不能修改自己的角色；非管理员不能管理成员', () async {
      await expectLater(
        world.members.update('kanade', role: MemberRole.user),
        throwsA(isA<MemberException>()),
      );
      final owner = MockWorld(currentUserId: 'linyue');
      addTearDown(owner.dispose);
      await expectLater(
        owner.members.update('chenyi', role: MemberRole.viewer),
        throwsA(
          isA<MemberException>().having((e) => e.code, 'code', 'forbidden'),
        ),
      );
    });

    test('修改角色、授权设备与有效期', () async {
      await world.members.update(
        'chenyi',
        role: MemberRole.viewer,
        grantedDeviceIds: ['go2-02'],
        clearExpiry: true,
      );
      final m = world.members.member('chenyi')!;
      expect(m.role, MemberRole.viewer);
      expect(m.grantedDeviceIds, ['go2-02']);
      expect(m.expiresAt, isNull);
      expect((await audit()).first.action, '将 陈一 设为观察者，长期有效，授权设备改为 Bravo');
    });

    test('其他页面的操作写入审计日志（同一数据源）', () async {
      await world.alerts.acknowledge('a2');
      await world.leases.approve('go2-01', 'r1');
      final log = await audit();
      expect(log[0].action, '批准了 林悦 对 Alpha 的控制权申请');
      expect(log[0].kind, AuditKind.control);
      expect(log[1].action, startsWith('确认告警「'));
      expect(log[1].actor, 'Kanade');
    });
  });

  group('智能体', () {
    test('示例对话：集合计划等待确认，检查项使用实时电量', () {
      final p = world.agent.conversation.activePlan!;
      expect(p.state, PlanState.pending);
      expect(p.steps, hasLength(4));
      expect(p.checks.first.text, '电量充足（Alpha 86%，Bravo 72%）');
    });

    test('回桩计划按设备状态生成（MobileAgent rows）', () async {
      await world.agent.send('所有设备回桩充电，正在跑任务的等任务结束再回');
      final p = world.agent.conversation.activePlan!;
      expect(p.title, '回桩计划 · 5 台');
      expect(p.steps.map((s) => '${s.who} ${s.summary}'), [
        'Bravo 立即回桩 #1',
        // 联调会话 #12 里是 Echo 和 Foxtrot（第 4 阶段数据），两台都要先退出。
        'Echo 先退出联调 #12',
        'Foxtrot 先退出联调 #12',
        'Charlie 去维修间（告警中）',
        'Alpha 巡检结束后 · 约 10 分钟',
      ]);
    });

    test('执行计划：逐步推进，完成后空闲设备进入充电', () async {
      await world.agent.send('所有设备回桩充电');
      final p = world.agent.conversation.activePlan!;
      await world.agent.runPlan(p.id);
      expect(world.devices.device('go2-02')!.status, DeviceStatus.busy);
      for (var i = 0; i < 20; i++) {
        world.agent.tick();
      }
      final done = world.agent.conversation.messages.last.plan!;
      expect(done.state, PlanState.done);
      final bravo = world.devices.device('go2-02')!;
      expect(bravo.status, DeviceStatus.charging);
      expect(bravo.location, '充电桩 #1');
      expect(
        world.sessions.session('s12')!.deviceIds,
        isNot(contains('g1-01')),
      );
      expect(world.devices.device('go2-03')!.location, '维修间');
    });

    test('中止计划：停止设备并恢复原状态，写入审计', () async {
      await world.agent.runPlan('p1');
      world.agent.tick();
      await world.agent.abortPlan('p1');
      final p = world.agent.conversation.messages
          .map((m) => m.plan)
          .whereType<AgentPlan>()
          .first;
      expect(p.state, PlanState.aborted);
      expect(world.devices.device('go2-02')!.status, DeviceStatus.online);
      expect((await audit()).first.action, contains('中止智能体计划'));
    });

    test('涉及运动的技能不能设为自动', () async {
      await expectLater(
        world.agent.setSkillMode('navigate_to', SkillMode.auto),
        throwsStateError,
      );
      await world.agent.setSkillMode('capture_photo', SkillMode.ask);
      final skills = await world.agent.watchSkills().first;
      expect(
        skills.firstWhere((s) => s.name == 'capture_photo').mode,
        SkillMode.ask,
      );
    });

    test('查询类指令直接回答，不生成计划', () async {
      await world.agent.send('找出电量最高的空闲设备');
      final m = world.agent.conversation.messages.last;
      expect(m.plan, isNull);
      expect(m.text, startsWith('Bravo 电量最高（72%）'));
      await world.agent.send('谁在控制 Bravo');
      expect(world.agent.conversation.messages.last.text, contains('没有人控制'));
    });
  });

  group('对讲与偏好', () {
    test('展厅分组按在线设备计数；播报写入设备事件', () async {
      final targets = world.intercom.targets;
      expect(targets.map((t) => t.label), [
        'Alpha',
        'Bravo',
        '展厅全部（2 台）',
        '全部在线',
      ]);
      await world.intercom.setTarget('hall');
      expect(await world.intercom.broadcast('请让一下，谢谢'), 2);
      final events = await world.devices.watchEvents('go2-04').first;
      expect(events.first.text, 'Kanade 播报：「请让一下，谢谢」');
    });

    test('偏好更新；关闭二次验证写入审计', () async {
      await world.preferences.update(
        (p) => p.copyWith(twoFactor: false, deadzone: 0.2),
      );
      expect(world.preferences.preferences.deadzone, 0.2);
      expect((await audit()).first.action, '关闭二次验证');
    });
  });
}
