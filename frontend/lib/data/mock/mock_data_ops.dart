import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import '../models/models.dart';

/// 第 5 阶段的示例数据：Alerts / Missions / Replay / Maintenance 的 renderVals()。
///
/// 相对时间（告警、日志）由 mock 仓库用 MockSeed.rebase 平移到当前时间；
/// 日历上的时刻（排期、录制、建图时间）用 [today] 取今天的同一时刻。
abstract final class MockOpsData {
  static DateTime today(int h, [int m = 0, int s = 0]) {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, h, m, s);
  }

  static DateTime _t(int day, int h, int m, [int s = 0]) =>
      DateTime(2026, 11, day, h, m, s);

  // ---- Alerts.dc.html ----

  // a1 的「已确认」原稿是 14:33:40，晚于设计稿的「现在」14:32，提前到 14:31:48。
  // a3 原稿「昨天 18:20 断开 → 今天 18:20 触发」也晚于现在：改为前天 18:20 断开、
  // 昨天 18:20 触发（列表时间仍是「昨天 18:20」）。
  static final alerts = [
    Alert(
      id: 'a1',
      severity: AlertSeverity.critical,
      state: AlertState.doing,
      title: '左后腿电机过热',
      deviceId: 'go2-03',
      location: 'C 区仓库',
      metric: 'RL_calf 电机温度（°C）',
      createdAt: _t(2, 14, 31),
      assigneeId: 'zhouming',
      recordingId: 'r1',
      events: [
        AlertEvent(
          at: _t(2, 14, 31, 2),
          message: '温度 68 °C，超过阈值 60 °C 持续 10 秒',
          tone: EventTone.critical,
        ),
        AlertEvent(at: _t(2, 14, 31, 3), message: '自动执行：切换低速步态，限速 0.3 m/s'),
        AlertEvent(at: _t(2, 14, 31, 5), message: '已推送给 林悦（管理者）、周明（使用者）、值班'),
        AlertEvent(
          at: _t(2, 14, 31, 48),
          message: '周明 已确认，正在返回维修间',
          tone: EventTone.info,
        ),
      ],
    ),
    Alert(
      id: 'a2',
      severity: AlertSeverity.warning,
      state: AlertState.open,
      title: '定位置信度下降',
      deviceId: 'go2-01',
      location: 'B 区 · 2 号走廊',
      metric: '定位置信度（×100）',
      createdAt: _t(2, 13, 58),
      events: [
        AlertEvent(
          at: _t(2, 13, 58, 12),
          message: '置信度 0.54，低于阈值 0.6',
          tone: EventTone.warning,
        ),
        AlertEvent(at: _t(2, 13, 58, 13), message: '已推送给 Kanade'),
      ],
    ),
    Alert(
      id: 'a3',
      severity: AlertSeverity.warning,
      state: AlertState.open,
      title: '离线超过 24 小时',
      deviceId: 'go2-05',
      location: '最后位置 · A 区',
      metric: '心跳间隔（分钟）',
      createdAt: _t(1, 18, 20),
      events: [
        AlertEvent(at: _t(0, 18, 20), message: '收到手动关机信号后断开'),
        AlertEvent(
          at: _t(1, 18, 20),
          message: '离线超过 24 小时，触发提醒',
          tone: EventTone.warning,
        ),
      ],
    ),
    Alert(
      id: 'a4',
      severity: AlertSeverity.critical,
      state: AlertState.closed,
      title: '跌倒检测触发',
      deviceId: 'go2-04',
      location: '展厅 · 台阶',
      metric: '机身俯仰角（°）',
      createdAt: _t(1, 17, 20),
      assigneeId: 'zhouming',
      events: [
        AlertEvent(
          at: _t(1, 17, 20, 31),
          message: '俯仰角突变，判定为跌倒',
          tone: EventTone.critical,
        ),
        AlertEvent(
          at: _t(1, 17, 20, 34),
          message: '自动恢复站立成功',
          tone: EventTone.success,
        ),
        AlertEvent(at: _t(1, 17, 42, 10), message: '周明 关闭：台阶边缘已加入禁行区'),
      ],
    ),
    Alert(
      id: 'a5',
      severity: AlertSeverity.info,
      state: AlertState.closed,
      title: '联调指令回执超时',
      deviceId: 'g1-01',
      location: '联调会话 #11',
      metric: '回执延迟（ms ÷ 10）',
      createdAt: _t(1, 16, 5),
      events: [
        AlertEvent(
          at: _t(1, 16, 5, 44),
          message: '回执 420 ms，超过 300 ms',
          tone: EventTone.info,
        ),
        AlertEvent(at: _t(1, 16, 20), message: '自动关闭：后续 15 分钟恢复正常'),
      ],
    ),
  ];

  /// 各告警曲线的上升幅度（设计稿 `series(peak, seed)`）。
  static const alertPeaks = {'a1': 58, 'a2': 40, 'a3': 20, 'a4': 66, 'a5': 48};

  /// 设计稿 `series()` 的移植：61 个采样点，阈值在 70（SVG 的 y = 30）。
  static List<double> alertSeries(int peak) {
    var s = peak;
    double rnd() {
      s = (s * 9301 + 49297) % 233280;
      return s / 233280;
    }

    return [
      for (var i = 0; i <= 60; i++)
        100 -
            (70 - math.pow(i / 60, 2) * peak + (rnd() - 0.5) * 5).clamp(6, 96),
    ];
  }

  static const rules = [
    AlertRule(
      id: 'temp',
      name: '电机过热',
      condition: '> 60 °C 持续 10 秒',
      severity: AlertSeverity.critical,
      autoAction: '自动降速',
    ),
    AlertRule(
      id: 'bat',
      name: '低电量',
      condition: '< 20%',
      severity: AlertSeverity.warning,
      autoAction: '自动回桩',
    ),
    AlertRule(
      id: 'off',
      name: '设备离线',
      condition: '心跳中断 > 5 分钟',
      severity: AlertSeverity.warning,
    ),
    AlertRule(
      id: 'fall',
      name: '跌倒检测',
      condition: '姿态突变',
      severity: AlertSeverity.critical,
      autoAction: '通知管理者',
    ),
    AlertRule(
      id: 'loc',
      name: '定位丢失',
      condition: '置信度 < 0.6',
      severity: AlertSeverity.warning,
    ),
    AlertRule(
      id: 'ack',
      name: '指令超时',
      condition: '回执 > 300 ms',
      severity: AlertSeverity.info,
      enabled: false,
    ),
  ];

  static const channels = [
    NotifyChannel('App 推送', '全部级别'),
    NotifyChannel('邮件', '警告及以上'),
    NotifyChannel('团队 IM（Webhook）', '警告及以上'),
    NotifyChannel('短信 / 电话', '仅严重'),
  ];

  static const roster = OnCallRoster(
    weeks: ['zhouming', 'linyue', 'kanade'],
    escalateAfter: Duration(minutes: 15),
    escalateToId: 'kanade',
  );

  // ---- Missions.dc.html ----

  /// B 区巡检层：32 m × 20 m（设计稿坐标换算 x × 0.32、y × 0.2）。
  static final mapB = SiteMap(
    id: 'b-patrol',
    name: 'B 区巡检层',
    widthMeters: 32,
    heightMeters: 20,
    areas: const [
      MapArea(Rect.fromLTRB(10, 10, 88, 90), outline: true),
      MapArea(Rect.fromLTWH(26, 32, 44, 34), label: '设备间（不可通行）'),
    ],
    chargers: const [Offset(14, 82)],
    // Alpha 已完成 B-2-03，正前往 B-2-04。
    devicePositions: const {'go2-01': Offset(41, 22)},
    deviceHeadings: const {'go2-01': math.pi / 2},
    updatedAt: today(7, 12),
  );

  static final mapC = SiteMap(
    id: 'c-warehouse',
    name: 'C 区仓库',
    widthMeters: 30,
    heightMeters: 18,
    areas: const [
      MapArea(Rect.fromLTRB(8, 10, 90, 88), outline: true),
      MapArea(Rect.fromLTWH(22, 26, 12, 46), label: '货架 A'),
      MapArea(Rect.fromLTWH(44, 26, 12, 46), label: '货架 B'),
      MapArea(Rect.fromLTWH(68, 60, 20, 26), label: '维修间'),
    ],
    chargers: const [Offset(12, 80), Offset(64, 16)],
    devicePositions: const {'go2-03': Offset(62, 78), 'b2-01': Offset(64, 20)},
    deviceHeadings: const {'go2-03': math.pi / 2, 'b2-01': 0},
    updatedAt: today(6, 40),
  );

  static final missions = [
    Mission(
      id: 'patrol-b2',
      name: '巡检路线 B-2',
      mapId: 'b-patrol',
      assignee: const MissionAssignee.device('go2-01'),
      schedule: '每天 09:00、14:00',
      state: MissionState.running,
      completed: 3,
      waypoints: const [
        Waypoint(
          name: '起点 · 充电桩 #1',
          position: Offset(18, 78),
          actions: [WaypointAction('自检', '电量 ≥ 40%')],
        ),
        Waypoint(
          name: 'B-2-02 · 消防栓',
          position: Offset(18, 40),
          yaw: 180,
          stay: Duration(seconds: 5),
          actions: [
            WaypointAction('拍照', '前置 RGB'),
            WaypointAction('识别', '消防栓状态'),
          ],
        ),
        Waypoint(
          name: 'B-2-03 · 配电仪表',
          position: Offset(34, 22),
          yaw: 90,
          stay: Duration(seconds: 10),
          actions: [
            WaypointAction('拍照', '前置 + 广角'),
            WaypointAction('识别', '仪表读数'),
            WaypointAction('上报', '超出范围则告警'),
          ],
        ),
        Waypoint(
          name: 'B-2-04 · 门禁',
          position: Offset(58, 22),
          yaw: 90,
          stay: Duration(seconds: 5),
          actions: [WaypointAction('识别', '门锁状态')],
        ),
        Waypoint(
          name: 'B-2-05 · 窗户',
          position: Offset(80, 30),
          stay: Duration(seconds: 5),
          actions: [WaypointAction('拍照', '广角')],
        ),
        Waypoint(
          name: 'B-2-06 · 走廊尽头',
          position: Offset(80, 60),
          yaw: 270,
          stay: Duration(seconds: 3),
          actions: [WaypointAction('点云快照', '变化检测')],
        ),
        Waypoint(
          name: 'B-2-07 · 机柜',
          position: Offset(58, 80),
          yaw: 270,
          stay: Duration(seconds: 10),
          actions: [WaypointAction('热成像', '温度 > 45 °C 告警')],
        ),
        Waypoint(
          name: 'B-2-08 · 出口',
          position: Offset(36, 80),
          yaw: 180,
          stay: Duration(seconds: 3),
          actions: [WaypointAction('拍照', '前置 RGB')],
        ),
      ],
    ),
    Mission(
      id: 'night-patrol-c1',
      name: '仓库夜巡 C-1',
      mapId: 'c-warehouse',
      assignee: const MissionAssignee.device('go2-03', backupDeviceId: 'b2-01'),
      schedule: '每晚 22:00',
      state: MissionState.scheduled,
      waypoints: const [
        Waypoint(
          name: '起点 · 充电桩 #3',
          position: Offset(14, 76),
          actions: [WaypointAction('自检', '电量 ≥ 60%')],
        ),
        Waypoint(
          name: 'C-1-02 · 货架 A 北',
          position: Offset(16, 18),
          yaw: 90,
          stay: Duration(seconds: 5),
          actions: [WaypointAction('点云快照', '货位变化检测')],
        ),
        Waypoint(
          name: 'C-1-03 · 通道',
          position: Offset(39, 18),
          yaw: 270,
          stay: Duration(seconds: 3),
          actions: [WaypointAction('拍照', '广角')],
        ),
        Waypoint(
          name: 'C-1-04 · 货架 B 南',
          position: Offset(39, 80),
          stay: Duration(seconds: 5),
          actions: [WaypointAction('热成像', '温度 > 45 °C 告警')],
        ),
        Waypoint(
          name: 'C-1-05 · 卸货口',
          position: Offset(62, 40),
          yaw: 90,
          stay: Duration(seconds: 10),
          actions: [
            WaypointAction('识别', '卷帘门状态'),
            WaypointAction('上报', '未关闭则告警'),
          ],
        ),
      ],
    ),
    Mission(
      id: 'welcome-hall',
      name: '展厅迎宾',
      mapId: 'showroom-1f',
      assignee: const MissionAssignee.preset('p-welcome'),
      schedule: '周六、日 10:00',
      state: MissionState.scheduled,
      loop: false,
      waypoints: const [
        Waypoint(
          name: '入口集合',
          position: Offset(20, 80),
          actions: [WaypointAction('队形', 'V 字')],
        ),
        Waypoint(
          name: '接待台',
          position: Offset(28, 30),
          yaw: 270,
          stay: Duration(seconds: 30),
          actions: [WaypointAction('打招呼', '全体'), WaypointAction('广播语音', '欢迎词')],
        ),
        Waypoint(
          name: '展厅中央',
          position: Offset(48, 50),
          stay: Duration(minutes: 2),
          actions: [WaypointAction('编队舞蹈', 'v2')],
        ),
      ],
    ),
    const Mission(
      id: 'remap-b',
      name: 'B 区地图更新',
      mapId: 'b-patrol',
      assignee: MissionAssignee.device('go2-02'),
      schedule: '每周一 07:00',
      state: MissionState.paused,
      loop: false,
    ),
  ];

  /// 今日排期（设计稿百分比换算成时刻；日历时刻，不随「现在」平移）。
  static List<ScheduleBlock> schedule() => [
    ScheduleBlock(
      deviceId: 'go2-01',
      start: today(9),
      end: today(10, 41),
      label: '巡检 B-2',
      kind: ScheduleKind.run,
      missionId: 'patrol-b2',
    ),
    ScheduleBlock(
      deviceId: 'go2-01',
      start: today(10, 48),
      end: today(13, 12),
      label: '充电',
      kind: ScheduleKind.charge,
    ),
    ScheduleBlock(
      deviceId: 'go2-01',
      start: today(14),
      end: today(15, 41),
      label: '巡检 B-2',
      kind: ScheduleKind.run,
      missionId: 'patrol-b2',
    ),
    ScheduleBlock(
      deviceId: 'go2-03',
      start: today(0),
      end: today(1, 55),
      label: '夜巡',
      kind: ScheduleKind.run,
      missionId: 'night-patrol-c1',
    ),
    ScheduleBlock(
      deviceId: 'go2-03',
      start: today(2, 2),
      end: today(8, 2),
      label: '充电',
      kind: ScheduleKind.charge,
    ),
    ScheduleBlock(
      deviceId: 'go2-03',
      start: today(22),
      end: today(23, 59, 59),
      label: '夜巡',
      kind: ScheduleKind.run,
      missionId: 'night-patrol-c1',
    ),
    ScheduleBlock(
      deviceId: 'b2-01',
      start: today(4, 48),
      end: today(7, 41),
      label: '充电',
      kind: ScheduleKind.charge,
    ),
    ScheduleBlock(
      deviceId: 'b2-01',
      start: today(22),
      end: today(23, 59, 59),
      label: '替补待命',
      kind: ScheduleKind.other,
      missionId: 'night-patrol-c1',
    ),
    ScheduleBlock(
      deviceId: 'go2-02',
      start: today(7),
      end: today(8, 26),
      label: '建图（暂停）',
      kind: ScheduleKind.other,
      missionId: 'remap-b',
    ),
  ];

  // ---- Replay.dc.html ----

  static const _gb = 1000 * 1000 * 1000;

  /// 录制时刻是日历时刻（「今天 14:02–14:40」），按设计稿原值，不随「现在」平移。
  static List<Recording> recordings() => [
    Recording(
      id: 'r1',
      name: 'Charlie 过热前后',
      deviceIds: const ['go2-03'],
      start: today(14, 2),
      end: today(14, 40),
      sizeBytes: (6.2 * _gb).round(),
      tags: const [RecordingTag.alert, RecordingTag.patrol],
      mapId: 'c-warehouse',
      events: const [
        RecordingEvent(Duration(minutes: 3, seconds: 2), '开始巡检'),
        RecordingEvent(
          Duration(minutes: 12, seconds: 42),
          '温度 > 60 °C',
          tone: EventTone.warning,
        ),
        RecordingEvent(
          Duration(minutes: 17, seconds: 29),
          '过热告警',
          tone: EventTone.critical,
        ),
        RecordingEvent(Duration(minutes: 19, seconds: 46), '自动降速'),
        RecordingEvent(Duration(minutes: 33, seconds: 26), '返回维修间'),
      ],
      tracks: const [
        RecordingTrack(TrackKind.video, [(0, 1)]),
        RecordingTrack(TrackKind.pointCloud, [(0, .61), (.63, 1)]),
        RecordingTrack(TrackKind.joints, [(0, 1)]),
        RecordingTrack(TrackKind.commands, [
          (.04, .07),
          (.20, .28),
          (.50, .56),
          (.84, .94),
        ]),
      ],
    ),
    Recording(
      id: 'r2',
      name: '巡检 B-2 · 上午',
      deviceIds: const ['go2-01'],
      start: today(9),
      end: today(9, 17, 42),
      sizeBytes: (3.1 * _gb).round(),
      tags: const [RecordingTag.patrol],
      mapId: 'b-patrol',
      events: const [
        RecordingEvent(Duration(seconds: 20), '开始巡检'),
        RecordingEvent(Duration(minutes: 4, seconds: 10), 'B-2-03 仪表读数'),
        RecordingEvent(
          Duration(minutes: 9, seconds: 35),
          '门禁未关',
          tone: EventTone.warning,
        ),
        RecordingEvent(Duration(minutes: 17, seconds: 5), '完成 8/8'),
      ],
      tracks: const [
        RecordingTrack(TrackKind.video, [(0, 1)]),
        RecordingTrack(TrackKind.pointCloud, [(0, 1)]),
        RecordingTrack(TrackKind.joints, [(0, 1)]),
        RecordingTrack(TrackKind.commands, [(0, .03)]),
      ],
    ),
    Recording(
      id: 'r3',
      name: '联调会话 #12',
      deviceIds: const ['g1-01', 'go2-04'],
      start: today(14, 14),
      end: today(14, 32, 10),
      sizeBytes: (9.8 * _gb).round(),
      tags: const [RecordingTag.fleet],
      mapId: 'showroom-1f',
      events: const [
        RecordingEvent(Duration(seconds: 30), '会话开始'),
        RecordingEvent(Duration(minutes: 6, seconds: 12), 'V 字队形'),
        RecordingEvent(Duration(minutes: 17, seconds: 20), '全体站立'),
      ],
      tracks: const [
        RecordingTrack(TrackKind.video, [(0, 1)]),
        RecordingTrack(TrackKind.pointCloud, [(0, .4), (.46, 1)]),
        RecordingTrack(TrackKind.joints, [(0, 1)]),
        RecordingTrack(TrackKind.commands, [
          (.02, .06),
          (.33, .40),
          (.62, .66),
          (.95, .98),
        ]),
      ],
    ),
    Recording(
      id: 'r4',
      name: '步态调试',
      deviceIds: const ['go2-02'],
      start: today(11, 20),
      end: today(11, 45, 3),
      sizeBytes: (4.4 * _gb).round(),
      tags: const [RecordingTag.manual],
      mapId: 'b-patrol',
      events: const [
        RecordingEvent(Duration(minutes: 2), '切换小跑'),
        RecordingEvent(
          Duration(minutes: 11, seconds: 30),
          '打滑',
          tone: EventTone.warning,
        ),
        RecordingEvent(Duration(minutes: 21), '参数 v3'),
      ],
      tracks: const [
        RecordingTrack(TrackKind.video, [(0, 1)]),
        RecordingTrack(TrackKind.pointCloud, [(.1, .9)]),
        RecordingTrack(TrackKind.joints, [(0, 1)]),
        RecordingTrack(TrackKind.commands, [(.02, .2), (.3, .55), (.6, .92)]),
      ],
    ),
  ];

  /// 地图轨迹（Replay.dc.html 第四个面板）。
  static const trajectories = {
    'r1': [
      Offset(15, 85),
      Offset(15, 30),
      Offset(45, 18),
      Offset(80, 26),
      Offset(82, 70),
      Offset(50, 82),
    ],
    'r2': [
      Offset(18, 78),
      Offset(18, 40),
      Offset(34, 22),
      Offset(58, 22),
      Offset(80, 30),
      Offset(80, 60),
      Offset(58, 80),
      Offset(36, 80),
      Offset(18, 78),
    ],
    'r3': [Offset(20, 80), Offset(28, 40), Offset(48, 50), Offset(52, 60)],
    'r4': [
      Offset(20, 30),
      Offset(70, 30),
      Offset(70, 26),
      Offset(20, 26),
      Offset(20, 22),
      Offset(70, 22),
    ],
  };

  static const storage = RecordingStorage(
    usedBytes: 182 * _gb,
    totalBytes: 1000 * _gb,
    retention: Duration(days: 30),
    autoRules: ['告警前后 60 秒', '所有联调会话'],
  );

  // ---- Maintenance.dc.html ----

  static const release = FirmwareRelease(
    latest: {
      'Unitree Go2 EDU': 'v1.1.8',
      'Unitree B2': 'v1.0.9',
      'Unitree G1': 'v0.9.4',
      'Unitree H1': 'v1.2.0',
    },
    agentVersion: '2.4.0',
    notes: [
      'v1.1.8：低速步态在湿滑地面更稳；修复雷达偶发丢帧',
      'v0.9.4（G1）：手臂动作库新增「打招呼 v2」',
      'UniConsole Agent 2.4.0：心跳与指令回执合并，降低 30% 流量',
    ],
  );

  /// 设计稿的初始状态；其余由设备状态推导。
  static const firmwareStates = {
    'go2-01': FirmwareState.waitingTask,
    'go2-02': FirmwareState.available,
    'go2-03': FirmwareState.failed,
    'g1-01': FirmwareState.available,
    'go2-04': FirmwareState.upgrading,
    'go2-05': FirmwareState.waitingOnline,
  };

  static const battery = [
    BatteryHealth(
      deviceId: 'go2-02',
      cycles: 205,
      monthly: [98, 97.6, 97.2, 96.8, 96.4, 96],
    ),
    BatteryHealth(
      deviceId: 'go2-01',
      cycles: 312,
      monthly: [97.5, 96.8, 96.1, 95.4, 94.7, 94],
    ),
    BatteryHealth(
      deviceId: 'go2-03',
      cycles: 488,
      monthly: [91, 90, 89, 88, 87, 86],
    ),
    BatteryHealth(
      deviceId: 'b2-01',
      cycles: 620,
      monthly: [88, 86.6, 85.2, 83.8, 82.4, 81],
    ),
  ];

  // 原稿 14:33:40 的降速日志晚于「现在」，按告警时间线改为 14:31:03；
  // Echo 加入会话 #12 的时间按会话开始时间改为 14:14:02。
  static final logs = [
    (_t(2, 14, 31, 3), LogSeverity.info, 'go2-03', 'gait.switch(low_speed) ok'),
    (
      _t(2, 14, 31, 2),
      LogSeverity.error,
      'go2-03',
      'motor[RL_calf] temp 68.2C > 60.0C',
    ),
    (
      _t(2, 14, 28, 17),
      LogSeverity.info,
      'go2-04',
      'ota: writing partition B (62%)',
    ),
    (
      _t(2, 14, 14, 2),
      LogSeverity.info,
      'g1-01',
      'session #12 joined as leader',
    ),
    (
      _t(2, 13, 58, 12),
      LogSeverity.warn,
      'go2-01',
      'loc.confidence 0.54 below 0.60',
    ),
    (
      _t(2, 13, 40, 5),
      LogSeverity.warn,
      'go2-03',
      'ota: sha256 mismatch, rollback',
    ),
    (
      _t(2, 13, 12, 44),
      LogSeverity.info,
      'b2-01',
      'dock: charging started 23%',
    ),
  ];

  static const window = MaintenanceWindow(
    Duration(hours: 2),
    Duration(hours: 4),
  );
}
