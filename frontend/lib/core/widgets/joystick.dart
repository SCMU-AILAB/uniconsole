import 'package:flutter/material.dart';

import '../theme/theme.dart';

enum JoystickAxis {
  /// 移动：前后 + 横移
  both,

  /// 转向：仅左右（Q / E）
  horizontal,
}

/// 摇杆（Control.dc.html）：132 圆底 + 50 白色圆钮，松手回中。
///
/// [onChanged] 输出 x、y ∈ [-1, 1]（y 向上为正）；松手时输出 (0, 0)。
/// 「松开 300 ms 后自动发送停止指令」由操控页的指令层处理。
class Joystick extends StatefulWidget {
  const Joystick({
    super.key,
    required this.semanticLabel,
    this.onChanged,
    this.axis = JoystickAxis.both,
    this.size = 132,
    this.caption,
    this.value,
  });

  final String semanticLabel;
  final ValueChanged<Offset>? onChanged;
  final JoystickAxis axis;
  final double size;

  /// 下方说明文字，如「移动 · W A S D」。
  final String? caption;

  /// 外部驱动的位置（键盘/手柄输入时显示）；拖动时以手势为准。
  final Offset? value;

  @override
  State<Joystick> createState() => _JoystickState();
}

class _JoystickState extends State<Joystick> {
  Offset? _drag;

  double get _knob => widget.size * 50 / 132;
  double get _travel => (widget.size - _knob) / 2 - 4;

  void _update(Offset local) {
    final center = Offset(widget.size / 2, widget.size / 2);
    var d = local - center;
    if (widget.axis == JoystickAxis.horizontal) d = Offset(d.dx, 0);
    if (d.distance > _travel) d = d / d.distance * _travel;
    setState(() => _drag = d);
    widget.onChanged?.call(Offset(d.dx / _travel, -d.dy / _travel));
  }

  void _release() {
    setState(() => _drag = null);
    widget.onChanged?.call(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = widget.onChanged != null;
    final v = widget.value ?? Offset.zero;
    final offset = _drag ?? Offset(v.dx * _travel, -v.dy * _travel);
    final hint = context.type.caption.copyWith(
      fontSize: 10,
      color: c.decorativeGray,
      height: 1,
    );

    Widget arrow(String s, Alignment a) => Align(
      alignment: a,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Text(s, style: hint),
      ),
    );

    final pad = Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GestureDetector(
        onPanStart: enabled ? (d) => _update(d.localPosition) : null,
        onPanUpdate: enabled ? (d) => _update(d.localPosition) : null,
        onPanEnd: enabled ? (_) => _release() : null,
        onPanCancel: enabled ? _release : null,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: c.fillSecondary,
            shape: BoxShape.circle,
            border: Border.all(color: c.separator),
          ),
          child: Stack(
            children: [
              if (widget.axis == JoystickAxis.both) ...[
                arrow('▲', Alignment.topCenter),
                arrow('▼', Alignment.bottomCenter),
                arrow('◀', Alignment.centerLeft),
                arrow('▶', Alignment.centerRight),
              ] else ...[
                arrow('↺', Alignment.centerLeft),
                arrow('↻', Alignment.centerRight),
              ],
              AnimatedPositioned(
                duration: _drag == null
                    ? const Duration(milliseconds: 180)
                    : Duration.zero,
                curve: Curves.easeOutBack,
                left: (widget.size - 2) / 2 - _knob / 2 + offset.dx,
                top: (widget.size - 2) / 2 - _knob / 2 + offset.dy,
                child: Container(
                  width: _knob,
                  height: _knob,
                  decoration: BoxDecoration(
                    color: c.isDark
                        ? c.decorativeGrayLight.withValues(alpha: 1)
                        : c.surface,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: c.shadow.withValues(alpha: 0.18),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      label: widget.semanticLabel,
      value:
          'x ${(offset.dx / _travel).toStringAsFixed(2)}，y ${(-offset.dy / _travel).toStringAsFixed(2)}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: pad),
          if (widget.caption != null) ...[
            const SizedBox(height: AppSpacing.md),
            ExcludeSemantics(
              child: Text(
                widget.caption!,
                style: context.type.subhead.copyWith(color: c.secondaryLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
