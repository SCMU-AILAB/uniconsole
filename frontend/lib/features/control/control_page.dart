import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../../data/repositories/repositories.dart';
import '../devices/device_widgets.dart';
import 'control_input.dart';
import 'mobile_control_page.dart';

/// 摄像头（Control.dc.html CAMS）。
enum Camera {
  front('前置 RGB', '前置'),
  wide('广角', '广角'),
  depth('深度', '深度'),
  overlay('雷达叠加', '雷达');

  const Camera(this.label, this.short);

  final String label;
  final String short;
}

/// 操控页上的 6 个姿态动作（Control.dc.html MODES）。
const controlModes = [
  MotionMode.stand,
  MotionMode.down,
  MotionMode.balance,
  MotionMode.walk,
  MotionMode.stairs,
  MotionMode.damp,
];

/// 页面级 UI 状态（摄像头、辅助开关、录制）。
class ControlUiState {
  const ControlUiState({
    this.camera = Camera.front,
    this.avoid = true,
    this.light = false,
    this.voice = false,
    this.recording = false,
  });

  final Camera camera;
  final bool avoid;
  final bool light;
  final bool voice;
  final bool recording;

  ControlUiState copyWith({
    Camera? camera,
    bool? avoid,
    bool? light,
    bool? voice,
    bool? recording,
  }) => ControlUiState(
    camera: camera ?? this.camera,
    avoid: avoid ?? this.avoid,
    light: light ?? this.light,
    voice: voice ?? this.voice,
    recording: recording ?? this.recording,
  );
}

class ControlUi extends Notifier<ControlUiState> {
  ControlUi(this.deviceId);

  final String deviceId;

  @override
  ControlUiState build() => const ControlUiState();

  void update(ControlUiState Function(ControlUiState) f) => state = f(state);

  void nextCamera() => state = state.copyWith(
    camera: Camera.values[(state.camera.index + 1) % Camera.values.length],
  );
}

final controlUiProvider = NotifierProvider.autoDispose
    .family<ControlUi, ControlUiState, String>(ControlUi.new);

/// 操控页共享的派生状态与动作，桌面与移动布局共用。
class ControlActions {
  ControlActions(this.ref, this.deviceId);

  final WidgetRef ref;
  final String deviceId;

  ControlRepository get _repo => ref.read(controlRepositoryProvider);

  Future<void> toggleEstop() async {
    final active = ref.read(estopProvider(deviceId)).value ?? false;
    if (!active) ref.read(controlInputProvider(deviceId).notifier).halt();
    await _repo.setEstop(deviceId, active: !active);
  }

  Future<CommandResult> setMode(MotionMode mode) =>
      _repo.send(deviceId, SetModeCommand(mode));

  Future<void> setSpeed(SpeedLevel level) async {
    ref.read(controlInputProvider(deviceId).notifier).setSpeed(level);
    await _repo.send(deviceId, SetSpeedCommand(level));
  }

  Future<void> setAssist(String name, bool on) =>
      _repo.send(deviceId, ActionCommand(name, {'on': on}));

  Future<void> requestLease() =>
      ref.read(leaseRepositoryProvider).acquire(deviceId);

  Future<void> releaseLease() async {
    ref.read(controlInputProvider(deviceId).notifier).halt();
    await ref.read(leaseRepositoryProvider).release(deviceId);
  }

  /// 键盘：W A S D / Q E 移动转向，空格急停，1–6 姿态，C 切换摄像头。
  KeyEventResult onKey(KeyEvent e, {required bool canMove}) {
    if (e.logicalKey == LogicalKeyboardKey.space) {
      if (e is KeyDownEvent) toggleEstop();
      return KeyEventResult.handled;
    }
    if (ControlInputState.movementKeys.contains(e.logicalKey)) {
      if (canMove || e is KeyUpEvent) {
        ref.read(controlInputProvider(deviceId).notifier).key(e);
      }
      return KeyEventResult.handled;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.keyC) {
      ref.read(controlUiProvider(deviceId).notifier).nextCamera();
      return KeyEventResult.handled;
    }
    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
    ];
    final i = digits.indexOf(e.logicalKey);
    if (i >= 0 && canMove) {
      setMode(controlModes[i]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 设备能否接受运动操作：在线、持有控制权、未急停（§8.1 / §8.2）。
class ControlGate {
  const ControlGate({
    required this.online,
    required this.holds,
    required this.estop,
  });

  final bool online;
  final bool holds;
  final bool estop;

  bool get canMove => online && holds && !estop;
}

ControlGate watchGate(WidgetRef ref, Device d) => ControlGate(
  online: d.status.isOnline,
  holds: ref.watch(holdsLeaseProvider(d.id)),
  estop: ref.watch(estopProvider(d.id)).value ?? false,
);

String signed(double v, [int digits = 2]) {
  final s = (v.abs() < 0.5 / _pow10(digits) ? 0.0 : v).toStringAsFixed(digits);
  return s.replaceFirst('-', '−');
}

double _pow10(int d) => [1.0, 10.0, 100.0, 1000.0][d];

/// 单机操控（Control.dc.html；移动端为 MobileControl.dc.html 横屏布局）。
class ControlPage extends ConsumerStatefulWidget {
  const ControlPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends ConsumerState<ControlPage> {
  final _focus = FocusNode(debugLabel: 'control');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(deviceProvider(widget.deviceId));
    if (d == null) {
      return const AppPage(
        title: '单机操控',
        children: [EmptyState(title: '找不到该设备')],
      );
    }
    ref.watch(leaseAutoRenewProvider(d.id));
    final gate = watchGate(ref, d);
    // 失去控制权或急停时立刻停止发送。
    ref.listen(holdsLeaseProvider(d.id), (prev, holds) {
      if (prev == true && !holds) {
        ref.read(controlInputProvider(d.id).notifier).halt();
      }
    });
    final actions = ControlActions(ref, d.id);
    // 手机按短边判断，横屏时仍走移动端横屏布局（LayoutSize.ofContext）。
    final mobile = LayoutSize.ofContext(context).isMobile;

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (_, e) => actions.onKey(e, canMove: gate.canMove),
      child: mobile
          ? MobileControlView(device: d, gate: gate, actions: actions)
          : _DesktopControl(device: d, gate: gate, actions: actions),
    );
  }
}

class _DesktopControl extends ConsumerWidget {
  const _DesktopControl({
    required this.device,
    required this.gate,
    required this.actions,
  });

  final Device device;
  final ControlGate gate;
  final ControlActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final d = device;
    final ui = ref.watch(controlUiProvider(d.id));
    final lease = ref.watch(leaseProvider(d.id));
    final me = ref.watch(currentUserProvider).value;
    final queued = lease?.queue.any((r) => r.userId == me?.id) ?? false;

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Presence(
          child: !gate.online
              ? const Padding(
                  padding: EdgeInsets.only(bottom: AppSpacing.x4),
                  child: AppBanner(
                    kind: BannerKind.warning,
                    message: '设备离线 · 无法操控，恢复连接后自动刷新',
                  ),
                )
              : !gate.holds
              ? Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.x4),
                  child: AppBanner(
                    kind: BannerKind.info,
                    message: queued
                        ? '已申请控制权，等待持有者处理 · 当前为只读观看'
                        : '你没有控制权 · 当前为只读观看',
                    action: queued
                        ? null
                        : PrimaryButton(
                            label: '申请控制权',
                            onPressed: actions.requestLease,
                          ),
                  ),
                )
              : null,
        ),
        _Video(device: d, gate: gate),
        const SizedBox(height: AppSpacing.x4),
        _ControlPad(device: d, gate: gate, actions: actions),
        const SizedBox(height: AppSpacing.x2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
          child: Text(
            '支持键盘、手柄（Xbox / PS / Switch Pro）与触控 · 空格键 = 急停 · 松开所有输入 300 ms 后自动停止',
            style: context.type.footnote.copyWith(color: c.secondaryLabel),
          ),
        ),
      ],
    );
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PowerCard(device: d),
        const SizedBox(height: AppSpacing.x3),
        _ImuCard(device: d),
        const SizedBox(height: AppSpacing.x3),
        JointTempsCard(device: d),
        const SizedBox(height: AppSpacing.x3),
        _LogCard(deviceId: d.id),
      ],
    );

    return AppPage(
      title: '单机操控 · ${d.name}',
      toolbarTitle: _DeviceSwitcher(device: d),
      actions: [
        _LeasePill(device: d, gate: gate, queued: queued),
        SecondaryButton(
          label: ui.recording ? '停止录制' : '录制',
          icon: ui.recording ? AppIcons.stop : null,
          onPressed: gate.online
              ? () => ref
                    .read(controlUiProvider(d.id).notifier)
                    .update((s) => s.copyWith(recording: !s.recording))
              : null,
        ),
        if (gate.holds)
          SecondaryButton(label: '释放控制权', onPressed: actions.releaseLease)
        else
          PrimaryButton(
            label: queued ? '已申请' : '申请控制权',
            onPressed: gate.online && !queued ? actions.requestLease : null,
          ),
        EmergencyStopButton(
          engaged: gate.estop,
          onPressed: gate.online ? actions.toggleEstop : null,
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            // 设计稿：左 flex 999 1 560、右 flex 1 0 300；放不下时右栏换到下方。
            if (box.maxWidth >= 560 + AppSpacing.x4 + 300) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: left),
                  const SizedBox(width: AppSpacing.x4),
                  SizedBox(width: 300, child: right),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                left,
                const SizedBox(height: AppSpacing.x4),
                right,
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 工具栏左侧的设备切换按钮。
class _DeviceSwitcher extends ConsumerWidget {
  const _DeviceSwitcher({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final latency = d.status.isOnline
        ? (ref.watch(telemetryProvider(d.id)).value?.latencyMs ?? d.latencyMs)
        : null;
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    return AppMenu<String>(
      options: [
        for (final o in devices)
          if (o.status.isOnline) MenuOption(o.id, '${o.name} · ${o.code}'),
      ],
      selected: d.id,
      onSelected: (id) => context.go(Routes.control(id)),
      anchor: (context, toggle) => Pressable(
        onTap: toggle,
        semanticLabel: '切换设备，当前 ${d.name}',
        focusRadius: AppRadius.md,
        builder: (context, st) => AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          height: 36,
          padding: const EdgeInsets.only(
            left: AppSpacing.x1,
            right: AppSpacing.x2,
          ),
          decoration: BoxDecoration(
            color: st.pressed || st.hovered
                ? c.fillSecondary
                : c.fillSecondary.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.fillSecondary,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: DeviceKindIcon(d.kind, size: 18),
              ),
              const SizedBox(width: AppSpacing.x3),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      d.name,
                      style: t.toolbarTitle.copyWith(color: c.label),
                    ),
                    Text(
                      '${d.code} · ${d.model} · ${latency == null ? '离线' : '延迟 $latency ms'}',
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

/// 控制权状态胶囊，持有时显示租约倒计时（§8.2）。
class _LeasePill extends ConsumerStatefulWidget {
  const _LeasePill({
    required this.device,
    required this.gate,
    required this.queued,
  });

  final Device device;
  final ControlGate gate;
  final bool queued;

  @override
  ConsumerState<_LeasePill> createState() => _LeasePillState();
}

class _LeasePillState extends ConsumerState<_LeasePill> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final lease = ref.watch(leaseProvider(d.id));
    final holder = lease == null
        ? null
        : lease.holderKind == LeaseHolderKind.user
        ? ref.watch(memberNameProvider(lease.holderId))
        : lease.source;
    if (!widget.gate.online) {
      return const StatusPill(
        tone: StatusTone.offline,
        label: '设备离线',
        large: true,
      );
    }
    if (widget.gate.holds) {
      final left = lease?.expiresAt?.difference(DateTime.now());
      return StatusPill(
        tone: StatusTone.busy,
        label: left == null
            ? '你持有控制权'
            : '你持有控制权 · 租约 ${formatCountdown(left)} 后自动续期',
        large: true,
      );
    }
    if (widget.queued) {
      return StatusPill(
        tone: StatusTone.busy,
        label: '已申请 · ${holder ?? ''} 持有控制权',
        large: true,
      );
    }
    return StatusPill(
      tone: holder == null ? StatusTone.offline : StatusTone.warning,
      label: holder == null ? '只读 · 无人控制' : '只读 · $holder 持有控制权',
      large: true,
    );
  }
}

class _Video extends ConsumerWidget {
  const _Video({required this.device, required this.gate});

  final Device device;
  final ControlGate gate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final d = device;
    final ui = ref.watch(controlUiProvider(d.id));
    final tm = gate.online ? ref.watch(telemetryProvider(d.id)).value : null;
    final cloud = gate.online
        ? ref.watch(pointCloudProvider(d.id)).value
        : null;
    final mode = tm?.mode == null ? null : MotionMode.values.byName(tm!.mode!);

    return VideoPanel(
      placeholder: gate.online ? '[${ui.camera.label}视频流 · WebRTC]' : '[设备离线]',
      topLeft: HudSegmented<Camera>(
        semanticLabel: '摄像头',
        options: [for (final cam in Camera.values) (cam, cam.label)],
        value: ui.camera,
        onChanged: (cam) => ref
            .read(controlUiProvider(d.id).notifier)
            .update((s) => s.copyWith(camera: cam)),
      ),
      topRight: gate.online
          ? LiveIndicator(
              detail:
                  '1280×720 · 30 fps · 端到端 ${(tm?.latencyMs ?? d.latencyMs ?? 0) + 30} ms',
            )
          : null,
      bottomLeft: HudMetrics(
        metrics: [
          HudMetric('前进 vx', tm == null ? '—' : '${signed(tm.vx)} m/s'),
          HudMetric('横移 vy', tm == null ? '—' : '${signed(tm.vy)} m/s'),
          HudMetric('转向 ωz', tm == null ? '—' : '${signed(tm.wz)} rad/s'),
          HudMetric('步态', mode?.label ?? '—'),
        ],
      ),
      bottomRight: cloud == null
          ? null
          : SizedBox(
              width: 150,
              height: 96,
              child: PointCloudView(
                points: cloud.points,
                rangeMeters: 4,
                label: '雷达俯视',
                semanticLabel: '雷达俯视小窗',
              ),
            ),
      overlay: gate.estop
          ? Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x3,
              ),
              decoration: BoxDecoration(
                color: c.emergency,
                borderRadius: BorderRadius.circular(AppRadius.group),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    AppIcons.stopAlert,
                    size: 17,
                    color: c.onAccent,
                    strokeWidth: 2,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Flexible(
                    child: Text(
                      '已触发急停 · 电机进入阻尼模式，所有运动指令被拒绝',
                      style: context.type.body.copyWith(
                        color: c.onAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

/// 摇杆 + 姿态动作 + 速度档位 + 辅助（Control.dc.html 操控卡）。
class _ControlPad extends ConsumerWidget {
  const _ControlPad({
    required this.device,
    required this.gate,
    required this.actions,
  });

  final Device device;
  final ControlGate gate;
  final ControlActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final input = ref.watch(controlInputProvider(d.id));
    final ui = ref.watch(controlUiProvider(d.id));
    final tm = gate.online ? ref.watch(telemetryProvider(d.id)).value : null;
    final mode = tm?.mode == null ? null : MotionMode.values.byName(tm!.mode!);
    final notifier = ref.read(controlInputProvider(d.id).notifier);
    // 急停时仍允许「趴下」「阻尼」这类让设备停下的动作。
    bool modeEnabled(MotionMode m) =>
        gate.online &&
        gate.holds &&
        (!gate.estop || m == MotionMode.down || m == MotionMode.damp);

    Widget label(String s) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: Text(s, style: t.subheadStrong.copyWith(color: c.secondaryLabel)),
    );

    final middle = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        label('姿态与动作'),
        LayoutBuilder(
          builder: (context, box) {
            const gap = AppSpacing.x2;
            final w = (box.maxWidth - gap * 2) / 3;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final m in controlModes)
                  SizedBox(
                    width: w,
                    child: _ModeButton(
                      label: m.label,
                      selected: m == mode,
                      onPressed: modeEnabled(m)
                          ? () => actions.setMode(m)
                          : null,
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.x4),
        Wrap(
          spacing: AppSpacing.x4,
          runSpacing: AppSpacing.x3,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  label('速度档位'),
                  IgnorePointer(
                    ignoring: !gate.canMove,
                    child: Opacity(
                      opacity: gate.canMove ? 1 : 0.45,
                      child: SegmentedControl<SpeedLevel>(
                        semanticLabel: '速度档位',
                        size: SegmentedSize.regular,
                        expand: true,
                        value: input.speed,
                        onChanged: actions.setSpeed,
                        options: [
                          for (final s in SpeedLevel.values)
                            SegmentOption(s, '${s.label} ${s.mps} m/s'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                label('辅助'),
                Wrap(
                  spacing: AppSpacing.x2,
                  children: [
                    AppChip(
                      label: ui.avoid ? '避障 开' : '避障 关',
                      selected: ui.avoid,
                      onChanged: gate.online && gate.holds
                          ? (v) {
                              ref
                                  .read(controlUiProvider(d.id).notifier)
                                  .update((s) => s.copyWith(avoid: v));
                              actions.setAssist('obstacle_avoid.Enable', v);
                            }
                          : null,
                    ),
                    AppChip(
                      label: '灯光',
                      selected: ui.light,
                      onChanged: gate.online && gate.holds
                          ? (v) {
                              ref
                                  .read(controlUiProvider(d.id).notifier)
                                  .update((s) => s.copyWith(light: v));
                              actions.setAssist('light.Switch', v);
                            }
                          : null,
                    ),
                    AppChip(
                      label: '语音',
                      selected: ui.voice,
                      onChanged: gate.online && gate.holds
                          ? (v) {
                              ref
                                  .read(controlUiProvider(d.id).notifier)
                                  .update((s) => s.copyWith(voice: v));
                              actions.setAssist('voice.Enable', v);
                            }
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );

    final moveStick = Joystick(
      semanticLabel: '移动摇杆',
      caption: '移动 · W A S D',
      value: input.move,
      onChanged: gate.canMove ? notifier.setStick : null,
    );
    final turnStick = Joystick(
      semanticLabel: '转向摇杆',
      caption: '转向 · Q E',
      axis: JoystickAxis.horizontal,
      value: Offset(input.yaw, 0),
      onChanged: gate.canMove ? (v) => notifier.setTurn(v.dx) : null,
    );

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.x5),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= 132 * 2 + 320 + AppSpacing.x6 * 2) {
            return Row(
              children: [
                moveStick,
                const SizedBox(width: AppSpacing.x6),
                Expanded(child: middle),
                const SizedBox(width: AppSpacing.x6),
                turnStick,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [moveStick, turnStick],
              ),
              const SizedBox(height: AppSpacing.x5),
              middle,
            ],
          );
        },
      ),
    );
  }
}

/// 姿态按钮：40 高、圆角 9；选中为强调色底白字，其余描边（Control.dc.html modes）。
class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => selected
      ? PrimaryButton(
          label: label,
          size: ButtonSize.large,
          expand: true,
          onPressed: onPressed,
        )
      : SecondaryButton(
          label: label,
          size: ButtonSize.large,
          expand: true,
          onPressed: onPressed,
        );
}

class _PowerCard extends ConsumerWidget {
  const _PowerCard({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final online = device.status.isOnline;
    final tm = online ? ref.watch(telemetryProvider(device.id)).value : null;
    final battery = tm?.battery ?? (online ? device.battery.toDouble() : null);
    final minutes = battery == null ? null : (battery * 1.3).round();

    Widget metric(String k, String v) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: t.caption.copyWith(color: c.secondaryLabel)),
        const SizedBox(height: AppSpacing.half),
        Text(v, style: t.bodyMedium.copyWith(color: c.label)),
      ],
    );

    return AppCard(
      title: '电源',
      gap: AppSpacing.x3,
      trailing: Text(
        minutes == null
            ? '离线'
            : minutes >= 60
            ? '预计剩余 ${minutes ~/ 60} 小时 ${minutes % 60} 分'
            : '预计剩余 $minutes 分',
        style: t.subhead.copyWith(color: c.secondaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                battery == null ? '—' : '${battery.round()}',
                style: t.statLarge.copyWith(color: c.label),
              ),
              const SizedBox(width: AppSpacing.x1),
              Text(
                '%',
                style: t.metric.copyWith(
                  color: c.secondaryLabel,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          ProgressBar(
            value: (battery ?? 0) / 100,
            height: 6,
            semanticLabel: '电量',
          ),
          const SizedBox(height: AppSpacing.x3),
          Row(
            children: [
              Expanded(
                child: metric(
                  '电压',
                  tm?.voltage == null
                      ? '—'
                      : '${tm!.voltage!.toStringAsFixed(1)} V',
                ),
              ),
              Expanded(
                child: metric(
                  '电流',
                  tm?.current == null
                      ? '—'
                      : '${tm!.current!.toStringAsFixed(1)} A',
                ),
              ),
              Expanded(
                child: metric(
                  '电池温度',
                  tm?.batteryTemp == null
                      ? '—'
                      : '${tm!.batteryTemp!.round()} °C',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ImuCard extends ConsumerWidget {
  const _ImuCard({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tm = device.status.isOnline
        ? ref.watch(telemetryProvider(device.id)).value
        : null;
    String deg(double? v) => v == null ? '—' : '${signed(v, 1)}°';
    return AppCard(
      title: '机身姿态 IMU',
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

/// 关节电机温度：4 条腿 × 3 个关节，≥ 60 严重、≥ 50 警告（Control.dc.html temp()）。
class JointTempsCard extends ConsumerWidget {
  const JointTempsCard({super.key, required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;
    final tm = device.status.isOnline
        ? ref.watch(telemetryProvider(device.id)).value
        : null;
    const legs = ['FL', 'FR', 'RL', 'RR'];
    const joints = ['髋 Hip', '大腿 Thigh', '小腿 Calf'];

    Widget cell(double? v) {
      final sw = v == null
          ? s.offline
          : v >= 60
          ? s.critical
          : v >= 50
          ? s.warning
          : s.online;
      return Container(
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sw.bg,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Text(
          v == null ? '—' : '${v.round()}',
          style: t.subhead.copyWith(color: sw.fg),
        ),
      );
    }

    return AppCard(
      title: '关节电机温度',
      trailing: Text('°C', style: t.subhead.copyWith(color: c.secondaryLabel)),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 36),
              for (final j in joints)
                Expanded(
                  child: Text(
                    j,
                    textAlign: TextAlign.center,
                    style: t.caption.copyWith(color: c.secondaryLabel),
                  ),
                ),
            ],
          ),
          for (var leg = 0; leg < 4; leg++) ...[
            const SizedBox(height: AppSpacing.x2),
            Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    legs[leg],
                    style: t.footnote.copyWith(
                      color: c.tertiaryLabel,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (var j = 0; j < 3; j++) ...[
                  if (j > 0) const SizedBox(width: AppSpacing.x2),
                  Expanded(child: cell(tm?.jointTemps[leg][j])),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LogCard extends ConsumerWidget {
  const _LogCard({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final log = ref.watch(commandLogProvider(deviceId)).value ?? const [];
    String hms(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    return AppCard(
      title: '指令日志',
      gap: AppSpacing.x2,
      trailing: Semantics(
        link: true,
        child: Text('全部', style: context.type.subhead.copyWith(color: c.link)),
      ),
      child: log.isEmpty
          ? Text(
              '暂无指令',
              style: context.type.footnote.copyWith(color: c.secondaryLabel),
            )
          : LogConsole(
              semanticLabel: '指令日志',
              lines: [
                for (final e in log.take(6))
                  LogLine(
                    e.ok ? e.text : '${e.text} · ${e.error}',
                    time: hms(e.at),
                    level: e.ok ? LogLevel.normal : LogLevel.error,
                  ),
              ],
            ),
    );
  }
}
