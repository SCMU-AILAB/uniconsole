import '../models/models.dart';
import 'mock_data.dart';

/// 第 3 阶段的示例数据（Main / Control / Sensors 的 renderVals()）。
///
/// 设计稿时间以 [MockData.now] 为「现在」；mock 运行时用 [rebase] 平移到真实当前时间，
/// 这样「2 分钟前」「租约 4:18」之类的相对时间始终成立。
abstract final class MockSeed {
  static final _offset = DateTime.now().difference(MockData.now);

  static DateTime rebase(DateTime t) => t.add(_offset);

  static DateTime ago(Duration d) => rebase(MockData.now.subtract(d));

  // Main.dc.html raw[].events
  static final events = <String, List<(Duration, String, EventTone)>>{
    'go2-01': [
      (const Duration(minutes: 2), '到达点位 B-2-03，拍照完成', EventTone.info),
      (const Duration(minutes: 41), 'Kanade 获取控制权', EventTone.neutral),
      (const Duration(minutes: 43), '开始执行巡检路线 B-2', EventTone.success),
    ],
    'go2-02': [
      (const Duration(minutes: 12), '林悦 释放控制权', EventTone.neutral),
      (const Duration(hours: 1), 'SLAM 地图同步完成', EventTone.success),
    ],
    'go2-03': [
      (const Duration(seconds: 20), '左后腿 RL_calf 电机温度超过阈值', EventTone.warning),
      (const Duration(seconds: 20), '自动切换为低速步态', EventTone.warning),
      (const Duration(hours: 2), '周明 获取控制权', EventTone.neutral),
    ],
    'b2-01': [(const Duration(minutes: 25), '自动回桩并开始充电', EventTone.success)],
    'g1-01': [(const Duration(minutes: 18), '加入联调会话 #12（领队）', EventTone.info)],
    'go2-04': [(const Duration(minutes: 22), '设备上线', EventTone.success)],
    'h1-01': [(const Duration(hours: 2), '连接断开（心跳超时）', EventTone.neutral)],
    'go2-05': [
      (
        const Duration(days: 1, hours: 20, minutes: 12),
        '手动关机',
        EventTone.neutral,
      ),
    ],
  };

  // Control.dc.html J[]：FL FR RL RR × hip thigh calf
  static const jointTemps = <String, List<List<double>>>{
    'go2-01': [
      [41, 44, 46],
      [40, 43, 45],
      [42, 47, 52],
      [39, 42, 44],
    ],
    'go2-03': [
      [44, 47, 50],
      [43, 46, 49],
      [48, 55, 68],
      [42, 45, 48],
    ],
  };

  static List<List<double>> jointsFor(String id, int maxTemp) =>
      jointTemps[id] ??
      [
        for (var leg = 0; leg < 4; leg++)
          [
            for (var j = 0; j < 3; j++)
              (maxTemp - 8 + leg + j * 2.5).toDouble(),
          ],
      ];

  // Control.dc.html logs[]
  static final commandLog = <(Duration, String)>[
    (const Duration(seconds: -8), 'sport.Move(vx=0.62, vy=0, wz=-0.15)'),
    (const Duration(seconds: -5), 'sport.SwitchGait(walk)'),
    (const Duration(seconds: 8), 'obstacle_avoid.Enable(true)'),
    (const Duration(seconds: 20), 'video.Subscribe(front, 720p30)'),
    (const Duration(seconds: 22), 'lease.Acquire(user=Kanade) ✓'),
  ];

  /// 设计稿里各设备当前的运动模式。
  static MotionMode modeFor(DeviceStatus s) => switch (s) {
    DeviceStatus.busy || DeviceStatus.alert => MotionMode.walk,
    DeviceStatus.charging => MotionMode.down,
    _ => MotionMode.stand,
  };

  // Sensors.dc.html cams[] / topics[]
  static const cameras = [
    SensorSource(
      name: '前置 RGB',
      detail: '1280×720 · 30 fps',
      health: SourceHealth.ok,
      hz: 30,
    ),
    SensorSource(
      name: '深度相机',
      detail: '640×480 · 15 fps',
      health: SourceHealth.ok,
      hz: 15,
    ),
    SensorSource(
      name: '广角鱼眼',
      detail: '1920×1080 · 15 fps',
      health: SourceHealth.ok,
      hz: 15,
    ),
    SensorSource(name: '后置', detail: '未订阅', health: SourceHealth.idle),
  ];

  static const topics = [
    SensorSource(
      name: 'rt/lowstate',
      detail: 'rt/lowstate',
      health: SourceHealth.ok,
      hz: 500,
    ),
    SensorSource(
      name: 'rt/sportmodestate',
      detail: 'rt/sportmodestate',
      health: SourceHealth.ok,
      hz: 50,
    ),
    SensorSource(
      name: 'rt/utlidar/cloud',
      detail: 'rt/utlidar/cloud',
      health: SourceHealth.ok,
      hz: 10,
    ),
    SensorSource(
      name: 'rt/frontvideostream',
      detail: 'rt/frontvideostream',
      health: SourceHealth.ok,
      hz: 29.7,
    ),
    SensorSource(
      name: 'rt/odom',
      detail: 'rt/odom',
      health: SourceHealth.degraded,
      hz: 42.3,
    ),
  ];

  static const lidar = '4D LiDAR · 360°×90° · 21,600 点/秒 · 10 Hz';

  // ---- 第 4 阶段：Fleet.dc.html ----

  /// 动作编排时间轴（16 s）：每台设备依次错开起步，与设计稿的 B(...) 一致。
  static List<TrackAction> timelineFor(
    List<String> deviceIds, {
    Duration length = const Duration(seconds: 16),
  }) {
    Duration at(double percent) =>
        Duration(milliseconds: (length.inMilliseconds * percent / 100).round());
    return [
      for (final (i, id) in deviceIds.indexed) ...[
        TrackAction(deviceId: id, start: at(0), end: at(14), action: '站立'),
        TrackAction(
          deviceId: id,
          start: at(16 + i * 2.0),
          end: at(50 + i * 2.0),
          action: '队形前进 3 m',
          kind: TrackActionKind.move,
        ),
        TrackAction(
          deviceId: id,
          start: at(54 + i * 3.0),
          end: at(76 + i * 3.0),
          action: '打招呼',
          kind: TrackActionKind.act,
        ),
        TrackAction(deviceId: id, start: at(80), end: at(98), action: '趴下'),
      ],
    ];
  }

  /// 设计稿「上一条指令回执」：14:31:20 全体站立。
  static FleetReceipt initialReceipt(List<String> deviceIds) => FleetReceipt(
    label: '全体站立',
    sentAt: rebase(DateTime(2026, 11, 2, 14, 31, 20)),
    acks: [
      for (final (i, id) in deviceIds.indexed)
        FleetAck(
          deviceId: id,
          ok: true,
          latency: Duration(
            milliseconds: const [12, 19, 24, 27, 33, 35][i % 6],
          ),
        ),
    ],
  );
}
