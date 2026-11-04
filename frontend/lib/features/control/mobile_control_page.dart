import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';

import '../../core/platform/orientation.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'control_input.dart';
import 'control_page.dart';

/// 移动端横屏操控（MobileControl.dc.html，844 × 390）。
///
/// 手机上进入时锁定横屏、隐藏状态栏，离开时恢复。桌面窄窗口（纵向）下按 844 × 390
/// 等比缩放显示，便于预览。
class MobileControlView extends ConsumerStatefulWidget {
  const MobileControlView({
    super.key,
    required this.device,
    required this.gate,
    required this.actions,
  });

  final Device device;
  final ControlGate gate;
  final ControlActions actions;

  @override
  ConsumerState<MobileControlView> createState() => _MobileControlViewState();
}

class _MobileControlViewState extends ConsumerState<MobileControlView> {
  @override
  void initState() {
    super.initState();
    AppOrientation.landscape();
  }

  @override
  void dispose() {
    // 离开时转回竖屏（其余移动页面都是竖屏设计）。
    AppOrientation.portrait();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.videoBackground,
      child: LayoutBuilder(
        builder: (context, box) {
          final content = _Landscape(
            device: widget.device,
            gate: widget.gate,
            actions: widget.actions,
          );
          if (box.maxWidth >= box.maxHeight) return content;
          // 纵向窗口：按设计稿尺寸等比缩放。
          return Center(
            child: FittedBox(
              child: SizedBox(width: 844, height: 390, child: content),
            ),
          );
        },
      ),
    );
  }
}

class _Landscape extends ConsumerWidget {
  const _Landscape({
    required this.device,
    required this.gate,
    required this.actions,
  });

  final Device device;
  final ControlGate gate;
  final ControlActions actions;

  static const _cams = [Camera.front, Camera.wide, Camera.overlay];
  static const _modes = [MotionMode.stand, MotionMode.walk, MotionMode.down];
  static const _speeds = [SpeedLevel.fast, SpeedLevel.normal, SpeedLevel.slow];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final ui = ref.watch(controlUiProvider(d.id));
    final input = ref.watch(controlInputProvider(d.id));
    final notifier = ref.read(controlInputProvider(d.id).notifier);
    final tm = gate.online ? ref.watch(telemetryProvider(d.id)).value : null;
    final mode = tm?.mode == null ? null : MotionMode.values.byName(tm!.mode!);
    final pad = MediaQuery.paddingOf(context);
    // 刘海一侧至少留 52pt（设计稿 50，按 4pt 网格取 52）。
    final side = math.max(AppSpacing.x8 + AppSpacing.x5, pad.left);
    final panel = context.hudOverlay;

    Widget pill({required Widget child, EdgeInsets? padding}) => Container(
      padding:
          padding ??
          const EdgeInsets.symmetric(
            horizontal: AppSpacing.x3,
            vertical: AppSpacing.x2,
          ),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(AppRadius.tile),
      ),
      child: child,
    );

    Widget chip(
      String label,
      bool selected,
      VoidCallback? onTap, {
      double width = 56,
      bool accent = false,
    }) => Pressable(
      onTap: onTap,
      semanticLabel: label,
      selected: selected,
      focusRadius: AppRadius.tile,
      builder: (context, st) {
        final bg = selected
            ? (accent ? c.accentFill : c.hudText.withValues(alpha: 0.92))
            : panel;
        final fg = selected && !accent ? c.videoBackground : c.hudText;
        return AnimatedOpacity(
          duration: AppMotion.highlight,
          opacity: st.enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: AppMotion.fade(pressed: st.pressed),
            width: width,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: st.pressed ? Color.lerp(bg, c.pressShade, 0.2) : bg,
              borderRadius: BorderRadius.circular(AppRadius.tile),
            ),
            child: Text(
              label,
              style: t.mobileFootnote.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      },
    );

    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _PerspectiveGrid(c.hudText.withValues(alpha: 0.08)),
          ),
        ),
        Align(
          alignment: const Alignment(0, -0.08),
          child: Text(
            gate.online ? '[${ui.camera.short}实时画面]' : '[设备离线]',
            style: t.subhead.copyWith(color: c.decorativeGray),
          ),
        ),
        Center(
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.hudText.withValues(alpha: 0.5)),
            ),
          ),
        ),
        // 左上：返回 + 设备信息
        Positioned(
          left: side,
          top: AppSpacing.x4,
          child: Row(
            children: [
              Pressable(
                // 从标签栏进入时没有可返回的页面：回到该设备的详情（全屏操控隐藏了标签栏，不能困住用户）。
                onTap: () {
                  final nav = Navigator.of(context);
                  if (nav.canPop()) {
                    nav.pop();
                  } else {
                    context.go(Routes.device(d.id));
                  }
                },
                semanticLabel: '返回',
                tooltip: '返回',
                focusRadius: 20,
                builder: (context, st) => AnimatedContainer(
                  duration: AppMotion.fade(pressed: st.pressed),
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: st.pressed
                        ? Color.lerp(panel, c.hudText, 0.15)
                        : panel,
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(
                    AppIcons.chevronLeft,
                    size: 20,
                    color: c.hudText,
                    strokeWidth: 2.2,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              pill(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name, style: t.headline.copyWith(color: c.hudText)),
                    Text(
                      tm == null
                          ? '离线'
                          : '${tm.battery?.round() ?? '—'}% · ${tm.latencyMs ?? '—'} ms · ${mode?.label ?? '—'}',
                      style: t.caption.copyWith(color: c.hudTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 顶部居中：摄像头
        Positioned(
          top: AppSpacing.x4,
          left: 0,
          right: 0,
          child: Center(
            child: HudSegmented<Camera>(
              semanticLabel: '摄像头',
              options: [for (final cam in _cams) (cam, cam.short)],
              value: _cams.contains(ui.camera) ? ui.camera : Camera.front,
              onChanged: (cam) => ref
                  .read(controlUiProvider(d.id).notifier)
                  .update((s) => s.copyWith(camera: cam)),
            ),
          ),
        ),
        // 右上：急停
        Positioned(
          right: side,
          top: AppSpacing.x3,
          child: _RoundStop(
            engaged: gate.estop,
            onPressed: gate.online ? actions.toggleEstop : null,
          ),
        ),
        Positioned(
          top: AppSpacing.x8 * 2,
          left: 0,
          right: 0,
          child: Center(
            child: PopIn(
              child: gate.estop
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.x4,
                        vertical: AppSpacing.x2,
                      ),
                      decoration: BoxDecoration(
                        color: c.emergency,
                        borderRadius: BorderRadius.circular(AppRadius.group),
                      ),
                      child: Text(
                        '已急停 · 再次点按解除',
                        style: t.mobileFootnote.copyWith(
                          color: c.onAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  : !gate.holds && gate.online
                  ? pill(
                      child: Text(
                        '只读观看 · 没有控制权',
                        style: t.mobileFootnote.copyWith(color: c.hudText),
                      ),
                    )
                  : null,
            ),
          ),
        ),
        // 左下：移动摇杆 + 速度档位
        Positioned(
          left: side + AppSpacing.x2,
          bottom: AppSpacing.x6 + AppSpacing.half,
          child: Joystick(
            semanticLabel: '移动摇杆',
            size: 136,
            overlay: true,
            value: input.move,
            onChanged: gate.canMove ? notifier.setStick : null,
          ),
        ),
        Positioned(
          left: side + AppSpacing.x2 + 136 + AppSpacing.x5,
          bottom: AppSpacing.x7 + AppSpacing.half,
          child: Semantics(
            label: '速度档位',
            container: true,
            child: Column(
              children: [
                for (final s in _speeds) ...[
                  chip(
                    s.label == '标准' ? '中' : s.label,
                    input.speed == s,
                    gate.canMove ? () => actions.setSpeed(s) : null,
                  ),
                  if (s != _speeds.last) const SizedBox(height: AppSpacing.x2),
                ],
              ],
            ),
          ),
        ),
        // 右下：姿态 + 转向摇杆
        Positioned(
          right: side + AppSpacing.x2 + 136 + AppSpacing.x5,
          bottom: AppSpacing.x7 + AppSpacing.half,
          child: Column(
            children: [
              for (final m in _modes) ...[
                chip(
                  m.label,
                  mode == m,
                  gate.online &&
                          gate.holds &&
                          (!gate.estop || m == MotionMode.down)
                      ? () => actions.setMode(m)
                      : null,
                  width: 72,
                  accent: true,
                ),
                if (m != _modes.last) const SizedBox(height: AppSpacing.x2),
              ],
            ],
          ),
        ),
        Positioned(
          right: side + AppSpacing.x2,
          bottom: AppSpacing.x6 + AppSpacing.half,
          child: Joystick(
            semanticLabel: '转向摇杆',
            size: 136,
            overlay: true,
            axis: JoystickAxis.horizontal,
            value: Offset(input.yaw, 0),
            onChanged: gate.canMove ? (v) => notifier.setTurn(v.dx) : null,
          ),
        ),
        // 底部居中：速度读数
        Positioned(
          bottom: AppSpacing.x4 + AppSpacing.half,
          left: 0,
          right: 0,
          child: Center(
            child: pill(
              child: DefaultTextStyle(
                style: t.caption.copyWith(color: c.hudTertiary),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (k, v) in [
                      ('vx', tm == null ? '—' : signed(tm.vx)),
                      ('vy', tm == null ? '—' : signed(tm.vy)),
                      ('ωz', tm == null ? '—' : signed(tm.wz)),
                    ]) ...[
                      Text('$k '),
                      Text(
                        v,
                        style: t.caption.copyWith(
                          color: c.hudText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x3),
                    ],
                    const Text('避障 '),
                    Text(
                      ui.avoid ? '开' : '关',
                      style: t.caption.copyWith(
                        color: ui.avoid ? c.switchOn : c.hudSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 圆形急停（64，白色描边）。
class _RoundStop extends StatelessWidget {
  const _RoundStop({required this.engaged, required this.onPressed});

  final bool engaged;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onPressed,
      semanticLabel: engaged ? '解除急停' : '急停',
      toggled: engaged,
      focusRadius: 32,
      builder: (context, st) {
        final base = engaged ? c.emergencyReleased : c.emergency;
        return AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: st.pressed ? Color.lerp(base, c.pressShade, 0.2) : base,
            shape: BoxShape.circle,
            border: Border.all(
              color: c.hudText.withValues(alpha: 0.85),
              width: 3,
            ),
            boxShadow: [
              BoxShadow(
                color: c.pressShade.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            engaged ? '解除' : 'STOP',
            style: context.type.mobileFootnote.copyWith(
              color: c.onAccent,
              fontWeight: FontWeight.w800,
            ),
          ),
        );
      },
    );
  }
}

/// 视频占位上的透视网格（MobileControl.dc.html 背景）。
class _PerspectiveGrid extends CustomPainter {
  const _PerspectiveGrid(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    final w = size.width, h = size.height;
    final vx = w / 2, vy = h * 0.49;
    for (final f in [0.0, 0.19, 0.36, 0.64, 0.81, 1.0]) {
      canvas.drawLine(
        Offset(w * f, h),
        Offset(vx + (w * f - vx) * 0.08, vy),
        p,
      );
    }
    for (final f in [0.95, 0.82, 0.72, 0.62, 0.55, 0.51]) {
      final y = h * f;
      final k = (y - vy) / (h - vy);
      canvas.drawLine(
        Offset(vx - vx * k * 0.92, y),
        Offset(vx + vx * k * 0.92, y),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_PerspectiveGrid old) => old.color != color;
}
