import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../control/control_page.dart' show JointTempsCard, signed;

enum SensorTab {
  all('总览'),
  cameras('摄像头'),
  lidar('激光雷达'),
  imu('IMU 与里程计'),
  joints('关节');

  const SensorTab(this.label);

  final String label;
}

enum CloudView {
  top('俯视'),
  perspective('3D'),
  follow('跟随');

  const CloudView(this.label);

  final String label;
}

/// 感知中心（Sensors.dc.html）。
class SensorsPage extends ConsumerStatefulWidget {
  const SensorsPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<SensorsPage> createState() => _SensorsPageState();
}

class _SensorsPageState extends ConsumerState<SensorsPage> {
  SensorTab _tab = SensorTab.all;
  CloudView _view = CloudView.top;
  bool _recording = false;
  final _overlays = <String>{};

  /// 暂停时冻结的画面（点云、遥测、10 秒历史）。
  ({PointCloudFrame? cloud, Telemetry? tm, List<Telemetry> history})? _frozen;

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(deviceProvider(widget.deviceId));
    if (d == null) {
      return const AppPage(
        title: '感知中心',
        children: [EmptyState(title: '找不到该设备')],
      );
    }
    final online = d.status.isOnline;
    final mobile = LayoutSize.ofContext(context).isMobile;

    final liveCloud = online ? ref.watch(pointCloudProvider(d.id)).value : null;
    final liveTm = online ? ref.watch(telemetryProvider(d.id)).value : null;
    final liveHistory = online
        ? ref.watch(telemetryHistoryProvider(d.id))
        : const <Telemetry>[];
    final cloud = _frozen?.cloud ?? liveCloud;
    final tm = _frozen?.tm ?? liveTm;
    final history = _frozen?.history ?? liveHistory;
    final status = online ? ref.watch(sensorStatusProvider(d.id)).value : null;

    void togglePause() => setState(() {
      _frozen = _frozen == null
          ? (cloud: liveCloud, tm: liveTm, history: liveHistory)
          : null;
    });

    final tabs = SegmentedControl<SensorTab>(
      semanticLabel: '传感器类别',
      size: mobile ? SegmentedSize.mobile : SegmentedSize.small,
      value: _tab,
      onChanged: (v) => setState(() => _tab = v),
      options: [for (final t in SensorTab.values) SegmentOption(t, t.label)],
    );

    final cloudPanel = _CloudPanel(
      points: cloud?.points ?? const [],
      online: online,
      lidar: status?.lidar ?? '—',
      view: _view,
      onView: (v) => setState(() => _view = v),
      overlays: _overlays,
      onOverlay: (o) => setState(
        () => _overlays.contains(o) ? _overlays.remove(o) : _overlays.add(o),
      ),
      tall: _tab == SensorTab.lidar,
    );
    final cams = _CameraGrid(
      cameras: status?.cameras ?? const [],
      online: online,
    );
    final imu = _ImuChart(history: history);
    final feet = _FootForces(tm: tm);
    final topics = _Topics(topics: status?.topics ?? const []);

    Widget grid(List<Widget> cards, {double min = 260}) => LayoutBuilder(
      builder: (context, box) {
        const gap = AppSpacing.x4;
        // auto-fit：列数不超过卡片数，卡片拉伸填满一行。
        final cols = ((box.maxWidth + gap) / (min + gap)).floor().clamp(
          1,
          cards.length.clamp(1, 4),
        );
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in cards) SizedBox(width: w, child: c)],
        );
      },
    );

    final children = switch (_tab) {
      SensorTab.all => [
        LayoutBuilder(
          builder: (context, box) {
            // 设计稿：点云 flex 999 1 520、摄像头 flex 1 0 360；放不下时换行。
            if (box.maxWidth >= 520 + AppSpacing.x4 + 360) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cloudPanel),
                  const SizedBox(width: AppSpacing.x4),
                  SizedBox(width: 360, child: cams),
                ],
              );
            }
            return Column(
              children: [
                cloudPanel,
                const SizedBox(height: AppSpacing.x4),
                cams,
              ],
            );
          },
        ),
        grid([imu, feet, topics]),
      ],
      SensorTab.cameras => [
        _CameraGrid(
          cameras: status?.cameras ?? const [],
          online: online,
          large: true,
        ),
      ],
      SensorTab.lidar => [
        cloudPanel,
        grid([topics]),
      ],
      SensorTab.imu => [
        grid([imu, _ImuNumbers(tm: tm), _Odometry(tm: tm)]),
      ],
      SensorTab.joints => [
        grid([JointTempsCard(device: d), feet], min: 320),
      ],
    };

    final time = tm == null
        ? '离线'
        : _frozen != null
        ? '已暂停 · ${_clock(tm.ts)}'
        : '实时 · ${_clock(tm.ts)}';

    return AppPage(
      title: '感知 · ${d.name}',
      mobileTitle: '感知',
      subtitle: mobile ? '${d.name} · ${d.code} · $time' : null,
      toolbarTitle: _SensorSwitcher(device: d, time: time),
      actions: [
        tabs,
        SecondaryButton(
          label: _frozen == null ? '暂停画面' : '继续',
          onPressed: online ? togglePause : null,
        ),
        PrimaryButton(
          label: _recording ? '停止录制' : '录制数据包',
          icon: _recording ? AppIcons.stop : AppIcons.record,
          onPressed: online
              ? () => setState(() => _recording = !_recording)
              : null,
        ),
      ],
      mobileActions: [
        AppIconButton(
          icon: _frozen == null ? AppIcons.pause : AppIcons.play,
          label: _frozen == null ? '暂停画面' : '继续',
          style: IconButtonStyle.circle,
          onPressed: online ? togglePause : null,
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        if (mobile)
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: tabs),
        if (!online)
          AppBanner(
            kind: BannerKind.warning,
            message: '${d.name} 离线 · 没有实时传感器数据',
          ),
        Presence(
          child: _recording
              ? AppBanner(
                  kind: BannerKind.info,
                  message: '正在录制数据包：点云、摄像头、IMU、关节 · 停止后保存到「录制与回放」',
                  action: SecondaryButton(
                    label: '停止',
                    onPressed: () => setState(() => _recording = false),
                  ),
                )
              : null,
        ),
        ...children,
      ],
    );
  }

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }
}

class _SensorSwitcher extends ConsumerWidget {
  const _SensorSwitcher({required this.device, required this.time});

  final Device device;
  final String time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    return AppMenu<String>(
      options: [
        for (final o in devices)
          if (o.status.isOnline) MenuOption(o.id, '${o.name} · ${o.code}'),
      ],
      selected: device.id,
      onSelected: (id) => context.go(Routes.sensors(id)),
      anchor: (context, toggle) => Pressable(
        onTap: toggle,
        semanticLabel: '切换设备，当前 ${device.name}',
        focusRadius: AppRadius.md,
        builder: (context, st) => AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
          decoration: BoxDecoration(
            color: st.pressed || st.hovered
                ? c.fillSecondary
                : c.fillSecondary.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '感知 · ${device.name}',
                      style: t.toolbarTitle.copyWith(color: c.label),
                    ),
                    Text(
                      '${device.code} · $time',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.caption.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              AppIcon(AppIcons.chevronDown, size: 12, strokeWidth: 2.4),
            ],
          ),
        ),
      ),
    );
  }
}

/// 激光雷达点云主视图（深色面板 + HUD）。
class _CloudPanel extends StatelessWidget {
  const _CloudPanel({
    required this.points,
    required this.online,
    required this.lidar,
    required this.view,
    required this.onView,
    required this.overlays,
    required this.onOverlay,
    this.tall = false,
  });

  final List<Offset> points;
  final bool online;
  final String lidar;
  final CloudView view;
  final ValueChanged<CloudView> onView;
  final Set<String> overlays;
  final ValueChanged<String> onOverlay;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    Widget legend(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppSpacing.half),
          ),
        ),
        const SizedBox(width: AppSpacing.x1),
        Text(label),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: SizedBox(
        height: tall ? 600 : 440,
        child: Stack(
          children: [
            Positioned.fill(
              child: PointCloudView(
                points: points,
                pixelsPerMeter: 60,
                rings: const [1, 2, 4],
                showHeading: true,
                pointSize: 3,
                robotSize: 18,
                border: false,
                semanticLabel: online ? '激光雷达点云，${points.length} 个点' : '激光雷达离线',
              ),
            ),
            Positioned(
              left: AppSpacing.x4,
              top: AppSpacing.x4,
              child: HudPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x3,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '激光雷达 · 点云',
                      style: t.cardTitle.copyWith(color: c.hudText),
                    ),
                    const SizedBox(height: AppSpacing.half),
                    Text(
                      online ? lidar : '离线',
                      style: t.caption.copyWith(color: c.hudSecondary),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: AppSpacing.x4,
              top: AppSpacing.x4,
              child: HudSegmented<CloudView>(
                semanticLabel: '点云视角',
                options: [for (final v in CloudView.values) (v, v.label)],
                value: view,
                onChanged: onView,
              ),
            ),
            Positioned(
              left: AppSpacing.x4,
              bottom: AppSpacing.x4,
              child: HudPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x2,
                ),
                child: DefaultTextStyle.merge(
                  style: t.caption.copyWith(color: c.hudTertiary),
                  child: Wrap(
                    spacing: AppSpacing.x3,
                    children: [
                      const Text('距离着色'),
                      legend(c.cloudNear, '< 1 m'),
                      legend(c.cloudMid, '1–2 m'),
                      legend(c.cloudFar, '> 2 m'),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: AppSpacing.x4,
              bottom: AppSpacing.x4,
              child: Row(
                children: [
                  for (final o in const ['栅格地图', '轨迹', '测距']) ...[
                    const SizedBox(width: AppSpacing.x2),
                    _HudToggle(
                      label: o,
                      on: overlays.contains(o),
                      onTap: () => onOverlay(o),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HudToggle extends StatelessWidget {
  const _HudToggle({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      toggled: on,
      focusRadius: AppRadius.sm,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? c.hudText.withValues(alpha: 0.9)
              : c.hudText.withValues(alpha: st.pressed ? 0.26 : 0.16),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          label,
          style: context.type.subhead.copyWith(
            color: on ? c.videoBackground : c.hudText,
          ),
        ),
      ),
    );
  }
}

/// 摄像头 2×2（4:3）。
class _CameraGrid extends StatelessWidget {
  const _CameraGrid({
    required this.cameras,
    required this.online,
    this.large = false,
  });

  final List<SensorSource> cameras;
  final bool online;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return LayoutBuilder(
      builder: (context, box) {
        const gap = AppSpacing.x3;
        final cols = box.maxWidth < 280 ? 1 : 2;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final cam in cameras)
              SizedBox(
                width: w,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: large ? 16 / 9 : 4 / 3,
                      child: Container(
                        decoration: BoxDecoration(
                          color: cam.health == SourceHealth.idle
                              ? context.hudOverlay
                              : c.videoBackground,
                          borderRadius: BorderRadius.circular(AppRadius.group),
                        ),
                        child: Stack(
                          children: [
                            Positioned(
                              left: AppSpacing.x2,
                              top: AppSpacing.x2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.x2,
                                  vertical: AppSpacing.half,
                                ),
                                decoration: BoxDecoration(
                                  color: c.pressShade.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.tag,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: cam.health == SourceHealth.ok
                                            ? c.live
                                            : c.decorativeGray,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.x1),
                                    Text(
                                      cam.health == SourceHealth.ok
                                          ? 'LIVE'
                                          : '待机',
                                      style: t.micro.copyWith(color: c.hudText),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Center(
                              child: Text(
                                '[${cam.name}画面]',
                                style: t.caption.copyWith(
                                  color: c.hudSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x2),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.half,
                      ),
                      child: Row(
                        children: [
                          Text(
                            cam.name,
                            style: t.subheadMedium.copyWith(color: c.label),
                          ),
                          const SizedBox(width: AppSpacing.x2),
                          Expanded(
                            child: Text(
                              cam.detail,
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.caption.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// IMU 三轴加速度，近 10 秒。
class _ImuChart extends StatelessWidget {
  const _ImuChart({required this.history});

  final List<Telemetry> history;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final samples = history.where((h) => h.accel.length >= 3).toList();
    final last = samples.isEmpty ? null : samples.last.accel;
    // Z 轴含重力（≈ 9.8），减去后与 X / Y 同量级绘制，读数仍显示原值。
    final series = [
      ChartSeries(
        values: [for (final h in samples) h.accel[0]],
        color: c.accent,
      ),
      ChartSeries(
        values: [for (final h in samples) h.accel[1]],
        color: s.warning.dot,
      ),
      ChartSeries(
        values: [for (final h in samples) h.accel[2] - 9.8],
        color: c.decorativeGray,
      ),
    ];
    Widget key(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 2, color: color),
        const SizedBox(width: AppSpacing.x1),
        Text(label, style: t.footnote.copyWith(color: c.tertiaryLabel)),
      ],
    );
    return AppCard(
      title: 'IMU 加速度',
      gap: AppSpacing.x2,
      trailing: Text(
        'm/s² · 近 10 秒',
        style: t.caption.copyWith(color: c.secondaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LineChart(
            semanticLabel: '三轴加速度曲线',
            series: samples.length < 2 ? const [] : series,
            minY: -1.5,
            maxY: 1.5,
            height: 96,
            background: false,
          ),
          const SizedBox(height: AppSpacing.x2),
          Wrap(
            spacing: AppSpacing.x4,
            children: [
              key(c.accent, 'X ${last == null ? '—' : signed(last[0])}'),
              key(s.warning.dot, 'Y ${last == null ? '—' : signed(last[1])}'),
              key(
                c.decorativeGray,
                'Z ${last == null ? '—' : signed(last[2])}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FootForces extends StatelessWidget {
  const _FootForces({required this.tm});

  final Telemetry? tm;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    const legs = ['FL', 'FR', 'RL', 'RR'];
    final moving =
        tm != null && (tm!.vx.abs() + tm!.vy.abs() + tm!.wz.abs() > 0.05);
    return AppCard(
      title: '足端接触力',
      trailing: Text('N', style: t.caption.copyWith(color: c.secondaryLabel)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.x2),
            Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    legs[i],
                    style: t.footnote.copyWith(
                      color: c.tertiaryLabel,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: ProgressBar(
                    value: ((tm?.footForce(i) ?? 0) / 160).clamp(0, 1),
                    height: 8,
                    battery: false,
                    color: (tm?.footForce(i) ?? 0) < 5
                        ? c.decorativeGrayLight
                        : context.status.online.dot,
                    semanticLabel: '${legs[i]} 接触力',
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    tm?.footForce(i) == null
                        ? '—'
                        : '${tm!.footForce(i)!.round()}',
                    textAlign: TextAlign.right,
                    style: t.footnote.copyWith(color: c.tertiaryLabel),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.x3),
          Text(
            tm == null
                ? '—'
                : moving
                ? '步态相位：对角小跑 · 2.1 Hz'
                : '步态相位：静止站立',
            style: t.footnote.copyWith(color: c.secondaryLabel),
          ),
        ],
      ),
    );
  }
}

class _Topics extends StatelessWidget {
  const _Topics({required this.topics});

  final List<SensorSource> topics;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    return AppCard(
      title: '话题健康',
      gap: AppSpacing.x2,
      trailing: Semantics(
        link: true,
        child: Text('全部 24 个', style: t.subhead.copyWith(color: c.link)),
      ),
      child: Column(
        children: [
          for (final topic in topics)
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.separatorSubtle)),
              ),
              child: Row(
                children: [
                  StatusDot(switch (topic.health) {
                    SourceHealth.ok => StatusTone.online,
                    SourceHealth.degraded => StatusTone.warning,
                    SourceHealth.idle => StatusTone.offline,
                  }),
                  const SizedBox(width: AppSpacing.x2),
                  Expanded(
                    child: Text(
                      topic.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.mono.copyWith(color: c.label),
                    ),
                  ),
                  Text(
                    topic.hz == null || topic.health == SourceHealth.idle
                        ? '—'
                        : '${topic.hz!.toStringAsFixed(1)} Hz',
                    style: t.mono.copyWith(
                      color: topic.health == SourceHealth.degraded
                          ? s.warning.fg
                          : c.tertiaryLabel,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ImuNumbers extends StatelessWidget {
  const _ImuNumbers({required this.tm});

  final Telemetry? tm;

  @override
  Widget build(BuildContext context) {
    String deg(double? v) => v == null ? '—' : '${signed(v, 1)}°';
    return AppCard(
      title: '机身姿态',
      child: Row(
        children: [
          Expanded(
            child: MetricCell(label: '横滚 Roll', value: deg(tm?.roll)),
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: MetricCell(label: '俯仰 Pitch', value: deg(tm?.pitch)),
          ),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: MetricCell(label: '航向 Yaw', value: deg(tm?.yaw)),
          ),
        ],
      ),
    );
  }
}

class _Odometry extends StatelessWidget {
  const _Odometry({required this.tm});

  final Telemetry? tm;

  @override
  Widget build(BuildContext context) {
    final p = tm?.pose;
    return AppCard(
      title: '里程计',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: MetricCell(
                  label: 'x',
                  value: p == null ? '—' : '${signed(p.x)} m',
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: MetricCell(
                  label: 'y',
                  value: p == null ? '—' : '${signed(p.y)} m',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          Row(
            children: [
              Expanded(
                child: MetricCell(
                  label: '定位置信度',
                  value: tm?.locConfidence == null
                      ? '—'
                      : tm!.locConfidence!.toStringAsFixed(2),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: MetricCell(
                  label: '速度',
                  value: tm == null ? '—' : '${signed(tm!.vx)} m/s',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
