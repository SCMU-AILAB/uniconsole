import 'dart:math' as math;
import 'dart:ui';

/// 预览页用的示例数据，取自 design/*.dc.html 的 renderVals()。
/// 第 3 阶段起由 data/mock 的 Repository 提供，这里仅供组件预览。
abstract final class DemoData {
  /// Control.dc.html `lidar(n, seed)` 的移植：墙体 + 障碍物点。
  static List<Offset> lidar(int n, int seed) {
    var s = seed;
    double rnd() {
      s = (s * 9301 + 49297) % 233280;
      return s / 233280;
    }

    final pts = <Offset>[];
    void add(double x, double y) => pts.add(
      Offset((x + (rnd() - 0.5) * 1.2) / 100, (y + (rnd() - 0.5) * 1.6) / 100),
    );
    for (var i = 0; i < n; i++) {
      final r = rnd();
      if (r < 0.3) {
        add(22, 6 + rnd() * 90);
      } else if (r < 0.55) {
        final y = 6 + rnd() * 90;
        if (y < 34 || y > 50) add(78, y);
      } else if (r < 0.72) {
        add(22 + rnd() * 56, 8);
      } else if (r < 0.86) {
        add(60 + rnd() * 10, 26);
      } else {
        add(78 + rnd() * 20, 34 + (rnd() < 0.5 ? 0 : 16));
      }
    }
    return pts;
  }

  /// 同一组点换算到机器人坐标系（米）：视图 8 m 宽，机器人在 (50%, 55%)。
  static List<Offset> lidarMeters(int n, int seed) => [
    for (final p in lidar(n, seed)) Offset((p.dx - 0.5) * 8, (0.55 - p.dy) * 8),
  ];

  /// RL_calf 电机温度近 30 分钟（Alerts.dc.html，阈值 60 °C）。
  static final List<double> motorTemp = List.generate(60, (i) {
    final base = 44 + i * 0.25;
    final spike = i > 44 ? (i - 44) * 1.2 : 0;
    return base + spike + math.sin(i * 0.7) * 1.4;
  });

  static final List<double> velocity = List.generate(
    60,
    (i) => 30 + 18 * math.sin(i / 6) + (i % 7) * 1.5,
  );

  static final List<double> latency = List.generate(
    24,
    (i) => 18 + 6 * math.sin(i / 2.5) + (i % 5) * 1.2,
  );

  static final List<double> battery = List.generate(
    24,
    (i) => 100 - i * 0.6 - (i % 3),
  );

  static const commandLog = [
    ('14:32:08', 'sport.Move(vx=0.62, vy=0, wz=-0.15)'),
    ('14:32:05', 'sport.SwitchGait(walk)'),
    ('14:31:52', 'obstacle_avoid.Enable(true)'),
    ('14:31:40', 'video.Subscribe(front, 720p30)'),
    ('14:31:38', 'lease.Acquire(user=Kanade) ✓'),
  ];
}
