import 'dart:async';

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_repositories.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

/// 模拟智能体：按关键词把指令拆成计划或直接回答，数据取自 [MockWorld]。
///
/// 计划执行被压缩到几秒钟：每一步按 [_durations] 推进，期间设备显示「智能体计划」
/// 任务，结束或中止后恢复；回桩计划完成后空闲设备进入充电。
class MockAgentRepository implements AgentRepository {
  MockAgentRepository({required this.world});

  final MockWorld world;

  late final _conv = MockStore<Conversation>(_seedConversation());
  late final _history = MockStore<List<Conversation>>(_seedHistory());
  final _skills = MockStore<List<AgentSkill>>(const [
    AgentSkill(
      name: 'navigate_to',
      description: '导航到地图上的点位或区域',
      mode: SkillMode.ask,
      motion: true,
    ),
    AgentSkill(
      name: 'capture_photo',
      description: '用指定摄像头拍照并发回对话',
      mode: SkillMode.auto,
    ),
    AgentSkill(
      name: 'posture / gait',
      description: '站立、趴下、切换步态等姿态动作',
      mode: SkillMode.ask,
      motion: true,
    ),
    AgentSkill(
      name: 'broadcast_tts',
      description: '通过设备扬声器播报文字',
      mode: SkillMode.auto,
    ),
    AgentSkill(
      name: 'start_mission',
      description: '启动或暂停巡检任务',
      mode: SkillMode.ask,
      motion: true,
    ),
    AgentSkill(
      name: 'firmware / shell',
      description: '固件升级与远程终端',
      mode: SkillMode.deny,
    ),
  ]);

  var _seq = 100;
  Timer? _timer;

  /// 计划 id → 每一步的模拟耗时（秒）。
  final _durations = <String, List<int>>{};

  /// 计划 id → 当前步骤已用秒数。
  final _elapsed = <String, int>{};

  /// 执行前的设备状态，结束或中止时恢复。
  final _before = <String, Device>{};

  Conversation get conversation => _conv.value;

  String _id(String prefix) => '$prefix${_seq++}';

  void dispose() => _timer?.cancel();

  // ---- 对话 ----

  @override
  Stream<Conversation> watchConversation() => _conv.watch();

  @override
  Stream<List<Conversation>> watchHistory() => _history.watch();

  @override
  Future<void> openConversation(String id) async {
    final target = _history.value.where((c) => c.id == id).firstOrNull;
    if (target == null || target.id == conversation.id) return;
    _archiveCurrent(except: id);
    _conv.value = target;
  }

  @override
  Future<void> newConversation() async {
    if (conversation.messages.isEmpty) return;
    _archiveCurrent();
    _conv.value = Conversation(
      id: _id('c'),
      title: '新对话',
      updatedAt: DateTime.now(),
    );
  }

  void _archiveCurrent({String? except}) {
    final cur = conversation;
    _history.value = [
      if (cur.messages.isNotEmpty) cur,
      for (final c in _history.value)
        if (c.id != cur.id && c.id != except) c,
    ];
  }

  @override
  Future<void> setContext({List<String>? deviceIds, String? mapId}) async {
    _conv.value = conversation.copyWith(
      deviceIds: deviceIds,
      mapId: mapId,
      clearMap: mapId == '',
    );
  }

  @override
  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final now = DateTime.now();
    _conv.value = conversation.copyWith(
      title: conversation.messages.isEmpty ? _titleFor(t) : null,
      updatedAt: now,
      messages: [
        ...conversation.messages,
        AgentMessage(id: _id('u'), role: AgentRole.user, text: t, at: now),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final reply = _respond(t);
    _conv.value = conversation.copyWith(
      updatedAt: DateTime.now(),
      messages: [...conversation.messages, reply],
    );
  }

  static String _titleFor(String t) =>
      t.length <= 16 ? t : '${t.substring(0, 16)}…';

  AgentMessage _say(String text, {AgentPlan? plan, AgentPhoto? photo}) =>
      AgentMessage(
        id: _id('a'),
        role: AgentRole.agent,
        text: text,
        at: DateTime.now(),
        plan: plan,
        photo: photo,
      );

  Device? _named(String text) {
    final lower = text.toLowerCase();
    for (final d in world.devices.all) {
      if (lower.contains(d.name.toLowerCase())) return d;
    }
    for (final id in conversation.deviceIds) {
      if (world.devices.device(id) case final d?) return d;
    }
    return null;
  }

  AgentMessage _respond(String t) {
    if (t.contains('回桩') || t.contains('充电')) return _chargePlan();
    if (t.contains('集合') || (t.contains('拍') && t.contains('门锁'))) {
      return _say(
        '我拟定了下面的计划，共 4 步，预计 3 分钟。Charlie 正在 C 区处理过热告警，两条路线都已避开它。',
        plan: _gatherPlan(),
      );
    }
    if (t.contains('看到') || t.contains('在看')) return _look(_named(t));
    if (t.contains('报告')) return _report();
    if (t.contains('电量最高')) return _bestIdle();
    if (t.contains('谁在控制') || t.contains('控制权')) return _holder(_named(t));
    return _say(
      '这条指令我还不能拆成可执行的步骤。可以试试：让设备回桩充电、集合到某个区域并拍照、'
      '查询设备画面、谁在控制某台设备，或生成今天的巡检报告。',
    );
  }

  AgentMessage _look(Device? d) {
    final dev = d ?? world.devices.device('go2-01')!;
    if (!dev.status.isOnline) {
      return _say('${dev.name} 当前离线（${dev.location}），拿不到画面。');
    }
    return _say(
      '这是 ${dev.name} 前置摄像头的实时画面。它在 ${dev.location}，'
      '当前任务：${dev.currentTask}。',
      photo: AgentPhoto(
        deviceId: dev.id,
        caption: '${dev.name} · 前置摄像头 · ${dev.location}',
      ),
    );
  }

  AgentMessage _report() {
    final missions = world.missions.missions;
    final running = missions.where((m) => m.state == MissionState.running);
    final scheduled = missions.where((m) => m.state == MissionState.scheduled);
    final alerts = world.alerts.alerts;
    final open = alerts.where((a) => a.state != AlertState.closed).toList();
    final critical = open
        .where((a) => a.severity == AlertSeverity.critical)
        .length;
    final online = world.devices.all.where((d) => d.status.isOnline).toList();
    final avg = online.isEmpty
        ? 0
        : online.map((d) => d.battery).reduce((a, b) => a + b) ~/ online.length;
    final lines = [
      '今天的巡检报告：',
      '· 任务：${running.length} 个执行中（${running.map((m) => '${m.name} ${m.completed}/${m.waypoints.length}').join('、')}），${scheduled.length} 个已排期。',
      '· 告警：${open.length} 条未关闭，其中严重 $critical 条'
          '${open.isEmpty ? '' : '（${open.map((a) => '${world.deviceName(a.deviceId)} ${a.title}').join('、')}）'}。',
      '· 设备：在线 ${online.length}/${world.devices.all.length} 台，平均电量 $avg%。',
    ];
    return _say(lines.join('\n'));
  }

  AgentMessage _bestIdle() {
    final idle = [
      for (final d in world.devices.all)
        if (d.status == DeviceStatus.online && world.leases.lease(d.id) == null)
          d,
    ]..sort((a, b) => b.battery.compareTo(a.battery));
    if (idle.isEmpty) return _say('现在没有空闲的在线设备。');
    final best = idle.first;
    final rest = idle.skip(1).map((d) => '${d.name} ${d.battery}%').join('、');
    return _say(
      '${best.name} 电量最高（${best.battery}%），在 ${best.location}，没有人控制。'
      '${rest.isEmpty ? '' : '其他空闲设备：$rest。'}',
    );
  }

  AgentMessage _holder(Device? d) {
    if (d == null) return _say('要查询哪台设备？可以用 @ 指定。');
    final l = world.leases.lease(d.id);
    if (l == null) {
      return _say(
        '${d.name} 目前没有人控制，${d.status.isOnline ? '可以直接申请。' : '设备离线。'}',
      );
    }
    final left = l.expiresAt?.difference(DateTime.now());
    final term = left == null
        ? '不限时'
        : '租约剩余 ${left.inMinutes} 分 ${(left.inSeconds % 60).toString().padLeft(2, '0')} 秒';
    final queue = l.queue.isEmpty ? '' : '，另有 ${l.queue.length} 个申请在排队';
    return _say(
      '${d.name} 由 ${world.leases.holderName(l)} 控制（${l.source}），$term$queue。',
    );
  }

  // ---- 计划 ----

  AgentPlan _gatherPlan({String? id}) {
    final alpha = world.devices.device('go2-01')!;
    final bravo = world.devices.device('go2-02')!;
    final planId = id ?? _id('p');
    _durations[planId] = [3, 5, 1, 2];
    final bravoFree = !world.leases.holds('go2-02');
    return AgentPlan(
      id: planId,
      title: '执行计划',
      steps: const [
        AgentStep(
          who: 'Alpha',
          deviceId: 'go2-01',
          text: '导航到 C 区 · 仓库门口（左侧）',
          call: 'navigate_to(target="C-gate", side="left")',
          eta: '约 90 秒',
          summary: '前往仓库门口左侧',
        ),
        AgentStep(
          who: 'Bravo',
          deviceId: 'go2-02',
          text: '申请控制权并导航到 C 区 · 仓库门口（右侧）',
          call: 'lease.acquire() → navigate_to(target="C-gate", side="right")',
          eta: '约 120 秒',
          summary: '前往仓库门口右侧',
        ),
        AgentStep(
          who: '系统',
          text: '等待两台设备都到达',
          call: 'wait_all(arrived, timeout=180s)',
          summary: '等待集合',
        ),
        AgentStep(
          who: 'Bravo',
          deviceId: 'go2-02',
          text: '对准门锁拍照，发送到本对话',
          call: 'capture_photo(cam="front", focus="door_lock")',
          eta: '约 5 秒',
          summary: '拍门锁照片',
        ),
      ],
      checks: [
        PlanCheck(
          '电量充足（Alpha ${alpha.battery}%，Bravo ${bravo.battery}%）',
          ok: alpha.battery >= 30 && bravo.battery >= 30,
        ),
        const PlanCheck('路线不经过禁入区和限速区'),
        if (bravoFree)
          const PlanCheck('Bravo 当前空闲，执行时会自动申请控制权，完成后释放', ok: false),
      ],
    );
  }

  AgentMessage _chargePlan() {
    final devices = world.devices.all;
    final occupied = {
      for (final d in devices)
        if (RegExp(r'充电桩 #(\d)').firstMatch(d.location) case final m?)
          int.parse(m.group(1)!),
    };
    var dock = 0;
    int nextDock() {
      do {
        dock++;
      } while (occupied.contains(dock));
      return dock;
    }

    final idle = <AgentStep>[];
    final inSession = <AgentStep>[];
    final alerting = <AgentStep>[];
    final onMission = <AgentStep>[];
    final reply = <String>[];
    for (final d in devices) {
      if (!d.status.isOnline || d.status == DeviceStatus.charging) continue;
      final session = world.sessions.sessions
          .where((s) => s.deviceIds.contains(d.id))
          .firstOrNull;
      final mission = world.missions.missions
          .where(
            (m) =>
                m.state == MissionState.running && m.assignee.deviceId == d.id,
          )
          .firstOrNull;
      if (d.status == DeviceStatus.alert) {
        alerting.add(
          AgentStep(
            who: d.name,
            deviceId: d.id,
            text: '告警中，低速前往维修间',
            call: 'navigate_to(target="repair-room", gait="slow")',
            eta: '约 3 分钟',
            summary: '去维修间（告警中）',
          ),
        );
      } else if (session != null) {
        final n = nextDock();
        inSession.add(
          AgentStep(
            who: d.name,
            deviceId: d.id,
            text: '退出联调 #${session.number} 后回桩充电（充电桩 #$n）',
            call: 'session.leave(${session.number}) → return_to_dock(dock=$n)',
            eta: '约 3 分钟',
            summary: '先退出联调 #${session.number}',
          ),
        );
      } else if (mission != null) {
        final left = mission.waypoints.length - mission.completed;
        final minutes = left * 2;
        onMission.add(
          AgentStep(
            who: d.name,
            deviceId: d.id,
            text: '${mission.name} 结束后回桩充电',
            call: 'after(mission="${mission.id}") → return_to_dock()',
            eta: '约 $minutes 分钟',
            summary: '巡检结束后 · 约 $minutes 分钟',
          ),
        );
        reply.add(
          '${d.name} 正在${mission.name.replaceFirst('巡检路线 ', '巡检 ')}'
          '（${mission.completed}/${mission.waypoints.length}），预计 $minutes 分钟后结束再回',
        );
      } else {
        final n = nextDock();
        idle.add(
          AgentStep(
            who: d.name,
            deviceId: d.id,
            text: '立即回桩充电（充电桩 #$n）',
            call: 'return_to_dock(dock=$n)',
            eta: '约 2 分钟',
            summary: '立即回桩 #$n',
          ),
        );
      }
    }
    final steps = [...idle, ...inSession, ...alerting, ...onMission];
    if (steps.isEmpty) return _say('所有在线设备都已经在充电了。');
    final now = idle.length + inSession.length + alerting.length;
    final planId = _id('p');
    _durations[planId] = [for (final _ in steps) 3];
    final head = now == 0
        ? '好的。'
        : '好的。$now 台设备马上处理：'
              '${[if (idle.isNotEmpty) '${idle.map((s) => s.who).join('、')} 直接回桩', if (inSession.isNotEmpty) '${inSession.map((s) => s.who).join('、')} 先退出联调', if (alerting.isNotEmpty) '${alerting.map((s) => s.who).join('、')} 告警中改去维修间'].join('，')}';
    return _say(
      '$head${reply.isEmpty ? '' : '；${reply.join('；')}'}。',
      plan: AgentPlan(
        id: planId,
        title: '回桩计划 · ${steps.length} 台',
        steps: steps,
        checks: [
          PlanCheck(
            '空闲充电桩 ${4 - occupied.length} 个，足够 ${idle.length + inSession.length} 台同时回桩',
          ),
          for (final s in inSession)
            PlanCheck('${s.who} 将退出联调会话，会话中的其他设备继续执行', ok: false),
          for (final s in alerting)
            PlanCheck('${s.who} 处于告警状态，以低速步态前往维修间', ok: false),
        ],
      ),
    );
  }

  AgentPlan? _plan(String planId) => conversation.messages
      .map((m) => m.plan)
      .whereType<AgentPlan>()
      .where((p) => p.id == planId)
      .firstOrNull;

  void _setPlan(String planId, AgentPlan Function(AgentPlan) f) {
    _conv.value = conversation.copyWith(
      messages: [
        for (final m in conversation.messages)
          m.plan?.id == planId ? m.withPlan(f(m.plan!)) : m,
      ],
    );
  }

  @override
  Future<void> runPlan(String planId) async {
    final p = _plan(planId);
    if (p == null || p.state != PlanState.pending) return;
    world.log(
      '执行智能体计划「${p.title}」（${p.deviceIds.map(world.deviceName).join('、')}）',
      kind: AuditKind.control,
    );
    for (final id in p.deviceIds) {
      final d = world.devices.device(id);
      if (d == null) continue;
      _before.putIfAbsent(id, () => d);
      world.devices.update(
        id,
        (d) => d.copyWith(
          status: d.status == DeviceStatus.online ? DeviceStatus.busy : null,
          currentTask:
              '智能体计划 · ${p.steps.firstWhere((s) => s.deviceId == id).summary}',
        ),
      );
    }
    _elapsed[planId] = 0;
    _setPlan(
      planId,
      (p) => p.copyWith(
        state: PlanState.running,
        steps: _startStep(p.steps, 0),
        progress: _progress(p, 0, 0),
      ),
    );
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  List<AgentStep> _startStep(List<AgentStep> steps, int i) => [
    for (final (j, s) in steps.indexed)
      j < i
          ? s.copyWith(state: StepState.done)
          : j == i
          ? s.copyWith(state: StepState.running, summary: _runningSummary(s))
          : s,
  ];

  static String? _runningSummary(AgentStep s) {
    final sum = s.summary;
    if (sum == null) return null;
    if (sum.startsWith('立即回桩')) return '返回中 · ${s.eta?.replaceFirst('约 ', '')}';
    if (sum.startsWith('先退出联调')) return '离开联调后返回';
    return sum;
  }

  String? _progress(AgentPlan p, int step, int elapsed) {
    if (p.title != '执行计划') {
      final s = p.steps[step];
      return '第 ${step + 1}/${p.steps.length} 台：${s.who} ${s.text}';
    }
    final total = _durations[p.id]![step];
    final frac = total == 0 ? 1.0 : elapsed / total;
    return switch (step) {
      0 =>
        'Alpha 距离 ${(14.0 * (1 - frac)).toStringAsFixed(1)} m，Bravo 距离 ${(18.6 - 6 * frac).toStringAsFixed(1)} m',
      1 => 'Alpha 已到达，Bravo 距离 ${(12.4 * (1 - frac)).toStringAsFixed(1)} m',
      2 => '两台设备都已到达',
      _ => 'Bravo 正在对准门锁拍照',
    };
  }

  /// 推进所有执行中的计划一秒（测试可直接调用）。
  void tick() {
    final running = conversation.messages
        .map((m) => m.plan)
        .whereType<AgentPlan>()
        .where((p) => p.state == PlanState.running)
        .toList();
    if (running.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    for (final p in running) {
      final step = p.current ?? 0;
      final dur = _durations[p.id] ?? [for (final _ in p.steps) 2];
      final e = (_elapsed[p.id] ?? 0) + 1;
      if (e < dur[step]) {
        _elapsed[p.id] = e;
        _setPlan(p.id, (p) => p.copyWith(progress: _progress(p, step, e)));
        continue;
      }
      _elapsed[p.id] = 0;
      _finishStep(p, step);
      if (step + 1 < p.steps.length) {
        _setPlan(
          p.id,
          (p) => p.copyWith(
            steps: _startStep(p.steps, step + 1),
            progress: _progress(p, step + 1, 0),
          ),
        );
      } else {
        _complete(p.id);
      }
    }
  }

  /// 一步完成后的设备侧效果。
  void _finishStep(AgentPlan p, int step) {
    final s = p.steps[step];
    final id = s.deviceId;
    if (id == null) return;
    final dock = RegExp(r'dock=(\d)').firstMatch(s.call)?.group(1);
    if (s.call.startsWith('session.leave')) {
      final session = world.sessions.sessions
          .where((x) => x.deviceIds.contains(id))
          .firstOrNull;
      if (session != null) {
        world.fleet.robot(id)?.stop();
        world.sessions.detach(id);
        world.leases.releaseSession(id, session.id);
        // 最后一台设备退出后会话自动结束。
        if (world.sessions.session(session.id)?.deviceIds.isEmpty ?? false) {
          unawaited(world.sessions.end(session.id));
        }
        world.devices.addEvent(
          id,
          '智能体计划：退出联调 #${session.number}',
          EventTone.neutral,
        );
      }
    }
    if (dock != null && !s.call.startsWith('after(')) {
      _before.remove(id);
      world.devices.update(
        id,
        (d) => d.copyWith(
          status: DeviceStatus.charging,
          location: '充电桩 #$dock',
          currentTask: '充电中',
        ),
      );
      world.devices.addEvent(id, '智能体计划：回桩充电（充电桩 #$dock）', EventTone.success);
    } else if (s.call.contains('repair-room')) {
      final before = _before.remove(id);
      world.devices.update(
        id,
        (d) => d.copyWith(
          status: before?.status,
          location: '维修间',
          currentTask: before?.currentTask,
        ),
      );
      world.devices.addEvent(id, '智能体计划：到达维修间', EventTone.info);
    }
  }

  void _restore(Iterable<String> ids) {
    for (final id in ids) {
      final before = _before.remove(id);
      if (before == null) continue;
      world.devices.update(
        id,
        (d) =>
            d.copyWith(status: before.status, currentTask: before.currentTask),
      );
    }
  }

  void _complete(String planId) {
    final p = _plan(planId)!;
    _restore(p.deviceIds);
    _setPlan(
      planId,
      (p) => p.copyWith(
        state: PlanState.done,
        steps: [
          for (final s in p.steps)
            s.copyWith(
              state: StepState.done,
              summary: s.call.startsWith('after(')
                  ? '已排队：任务结束后自动回桩'
                  : s.summary?.startsWith('返回中') ?? false
                  ? '已回桩充电'
                  : null,
            ),
        ],
        progress: '全部完成',
      ),
    );
    if (p.title == '执行计划') {
      _conv.value = conversation.copyWith(
        messages: [
          ...conversation.messages,
          _say(
            'Alpha 和 Bravo 已在 C 区仓库门口集合。这是 Bravo 拍到的门锁照片：',
            photo: const AgentPhoto(
              deviceId: 'go2-02',
              caption: 'Bravo · 前置摄像头 · C 区仓库门锁',
            ),
          ),
        ],
      );
    }
  }

  @override
  Future<void> abortPlan(String planId) async {
    final p = _plan(planId);
    if (p == null || p.state != PlanState.running) return;
    for (final id in p.deviceIds) {
      world.fleet.robot(id)?.stop();
      world.devices.addEvent(
        id,
        '${world.me.name} 中止智能体计划，已停止',
        EventTone.warning,
      );
    }
    _restore(p.deviceIds);
    _setPlan(
      planId,
      (p) => p.copyWith(
        state: PlanState.aborted,
        steps: [
          for (final s in p.steps)
            s.state == StepState.done
                ? s
                : s.copyWith(state: StepState.skipped),
        ],
        progress: '已中止，${p.deviceIds.length} 台设备已停止',
      ),
    );
    world.log('中止智能体计划「${p.title}」并停止所有设备', kind: AuditKind.control);
  }

  @override
  Future<void> cancelPlan(String planId) async {
    final p = _plan(planId);
    if (p == null || p.state != PlanState.pending) return;
    _setPlan(planId, (p) => p.copyWith(state: PlanState.cancelled));
  }

  @override
  Stream<List<AgentSkill>> watchSkills() => _skills.watch();

  @override
  Future<void> setSkillMode(String name, SkillMode mode) async {
    final skill = _skills.value.where((s) => s.name == name).firstOrNull;
    if (skill == null) return;
    if (skill.motion && mode == SkillMode.auto) {
      throw StateError('涉及运动的技能必须经过确认');
    }
    _skills.value = [
      for (final s in _skills.value)
        s.name == name ? s.copyWith(mode: mode) : s,
    ];
    world.log('将智能体技能 $name 设为「${mode.label}」');
  }

  // ---- 示例 ----

  // Agent.dc.html：集合并拍照，等待确认。
  Conversation _seedConversation() {
    final at = MockSeed.ago(const Duration(minutes: 1));
    return Conversation(
      id: 'c1',
      title: 'Alpha 和 Bravo 去 C 区仓库门口集合',
      updatedAt: at,
      deviceIds: const ['go2-01', 'go2-02'],
      mapId: 'c-warehouse',
      messages: [
        AgentMessage(
          id: 'u1',
          role: AgentRole.user,
          text: '让 Alpha 和 Bravo 去 C 区仓库门口集合，然后 Bravo 拍一张门锁的照片发给我',
          at: at,
        ),
        AgentMessage(
          id: 'a1',
          role: AgentRole.agent,
          text: '我拟定了下面的计划，共 4 步，预计 3 分钟。Charlie 正在 C 区处理过热告警，两条路线都已避开它。',
          at: at,
          plan: _gatherPlan(id: 'p1'),
        ),
      ],
    );
  }

  List<Conversation> _seedHistory() {
    final y = MockSeed.rebase(DateTime(2026, 11, 1, 18, 5));
    final y2 = MockSeed.rebase(DateTime(2026, 11, 1, 9, 2));
    final d3 = MockSeed.rebase(DateTime(2026, 10, 31, 15, 40));
    return [
      Conversation(
        id: 'c0',
        title: '所有设备回桩充电',
        updatedAt: y,
        messages: [
          AgentMessage(id: 'h1', role: AgentRole.user, text: '所有设备回桩充电', at: y),
          AgentMessage(
            id: 'h2',
            role: AgentRole.agent,
            text: '已完成：5 台设备回桩，Charlie 送往维修间。',
            at: y,
          ),
        ],
      ),
      Conversation(
        id: 'c-1',
        title: '生成昨天的巡检报告',
        updatedAt: y2,
        messages: [
          AgentMessage(
            id: 'h3',
            role: AgentRole.user,
            text: '生成昨天的巡检报告',
            at: y2,
          ),
          AgentMessage(
            id: 'h4',
            role: AgentRole.agent,
            text: '昨天的巡检报告：\n· 任务：巡检路线 B-2 执行 4 次，夜间巡检 C-1 执行 1 次。\n· 告警：3 条，均已关闭。',
            at: y2,
          ),
        ],
      ),
      Conversation(
        id: 'c-2',
        title: 'Foxtrot 展厅迎宾播报',
        updatedAt: d3,
        messages: [
          AgentMessage(
            id: 'h5',
            role: AgentRole.user,
            text: '让 Foxtrot 在展厅入口播报欢迎词',
            at: d3,
          ),
          AgentMessage(
            id: 'h6',
            role: AgentRole.agent,
            text: '已通过 Foxtrot 播报：「您好，欢迎参观，请跟随我前往展品区。」',
            at: d3,
          ),
        ],
      ),
    ];
  }
}

/// 对讲：目标从设备列表计算（展厅分组的在线设备、全部在线设备）。
class MockIntercomRepository implements IntercomRepository {
  MockIntercomRepository({required this.world});

  final MockWorld world;
  final _state = MockStore(
    const IntercomState(
      targetId: 'go2-01',
      presets: ['请让一下，谢谢', '此区域禁止进入', '巡检中，请勿触碰'],
    ),
  );

  IntercomState get state => _state.value;

  List<IntercomTarget> _targets(List<Device> devices) {
    final online = [
      for (final d in devices)
        if (d.status.isOnline) d.id,
    ];
    final hall = [
      for (final d in devices)
        if (d.groupId == 'showroom' && d.status.isOnline) d.id,
    ];
    return [
      for (final id in const ['go2-01', 'go2-02'])
        IntercomTarget(id: id, label: world.deviceName(id), deviceIds: [id]),
      IntercomTarget(
        id: 'hall',
        label: '展厅全部（${hall.length} 台）',
        deviceIds: hall,
      ),
      IntercomTarget(id: 'all', label: '全部在线', deviceIds: online),
    ];
  }

  List<IntercomTarget> get targets => _targets(world.devices.all);

  @override
  Stream<List<IntercomTarget>> watchTargets() =>
      world.devices.watchDevices().map(_targets);

  @override
  Stream<IntercomState> watchState() => _state.watch();

  @override
  Future<void> setTarget(String targetId) async {
    if (state.talking) await stopTalking();
    _state.value = state.copyWith(targetId: targetId);
  }

  IntercomTarget? get _target =>
      targets.where((t) => t.id == state.targetId).firstOrNull;

  @override
  Future<void> startTalking() async {
    final t = _target;
    if (t == null || t.deviceIds.every((id) => !_online(id))) return;
    _state.value = state.copyWith(talkingSince: DateTime.now());
  }

  @override
  Future<void> stopTalking() async {
    _state.value = state.copyWith(stopTalking: true);
  }

  @override
  Future<void> setListening(bool listening) async {
    _state.value = state.copyWith(listening: listening);
  }

  bool _online(String id) => world.devices.device(id)?.status.isOnline ?? false;

  @override
  Future<int> broadcast(String text) async {
    final t = _target;
    final msg = text.trim();
    if (t == null || msg.isEmpty) return 0;
    var n = 0;
    for (final id in t.deviceIds) {
      if (!_online(id)) continue;
      n++;
      world.devices.addEvent(id, '${world.me.name} 播报：「$msg」', EventTone.info);
    }
    return n;
  }
}
