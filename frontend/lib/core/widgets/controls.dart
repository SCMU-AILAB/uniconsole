import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'app_icon.dart';
import 'pressable.dart';

class SegmentOption<T> {
  const SegmentOption(this.value, this.label, {this.semanticLabel});

  final T value;
  final String label;
  final String? semanticLabel;
}

enum SegmentedSize {
  /// 工具栏筛选：段高 24、字号 12
  small(24, AppRadius.md, AppRadius.xs),

  /// 卡片内（速度档位）：段高 28
  regular(28, AppRadius.md, AppRadius.xs),

  /// 移动端：段高 30、字号 13
  mobile(30, AppRadius.lg, AppRadius.sm);

  const SegmentedSize(this.height, this.trackRadius, this.radius);

  final double height;
  final double trackRadius;
  final double radius;
}

/// 分段控件：灰色轨道 + 白色选中块（Main.dc.html 状态筛选）。
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.size = SegmentedSize.small,
    this.expand = false,
    this.semanticLabel,
  });

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final SegmentedSize size;

  /// 每段等宽撑满（移动端、速度档位）。
  final bool expand;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final base = size == SegmentedSize.mobile ? t.mobileFootnote : t.subhead;
    final segments = <Widget>[];
    for (var i = 0; i < options.length; i++) {
      final o = options[i];
      final on = o.value == value;
      Widget seg = Pressable(
        onTap: () => onChanged(o.value),
        semanticLabel: o.semanticLabel ?? o.label,
        selected: on,
        focusRadius: size.radius,
        builder: (context, st) => AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: size.height,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on
                ? c.segmentedSelected
                : st.hovered
                ? c.label.withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(size.radius),
            boxShadow: on && !c.isDark
                ? [
                    BoxShadow(
                      color: c.shadow,
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            o.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(
              color: c.label,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      );
      if (expand) seg = Expanded(child: seg);
      if (i > 0) segments.add(const SizedBox(width: AppSpacing.xxs));
      segments.add(seg);
    }
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.xxs),
        decoration: BoxDecoration(
          color: size == SegmentedSize.mobile
              ? c.mobileControlFill
              : c.segmentedTrack,
          borderRadius: BorderRadius.circular(size.trackRadius),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: segments,
        ),
      ),
    );
  }
}

/// 搜索框（桌面 28 高；[mobile] 为 36 高、字号 16）。
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.hint,
    this.semanticLabel,
    this.controller,
    this.onChanged,
    this.width,
    this.mobile = false,
  });

  final String hint;
  final String? semanticLabel;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final double? width;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style =
        (mobile
                ? context.type.mobileBody.copyWith(fontSize: 16)
                : context.type.subhead)
            .copyWith(color: c.label);
    return Container(
      width: width,
      height: mobile ? 36 : 28,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: BoxDecoration(
        color: mobile ? c.mobileControlFill : c.segmentedTrack,
        borderRadius: BorderRadius.circular(
          mobile ? AppRadius.group : AppRadius.sm,
        ),
      ),
      child: Row(
        children: [
          AppIcon(AppIcons.search, size: mobile ? 16 : 14, strokeWidth: 2),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Semantics(
              label: semanticLabel,
              child: Material(
                type: MaterialType.transparency,
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  style: style,
                  cursorHeight: style.fontSize! + 2,
                  decoration: InputDecoration.collapsed(
                    hintText: hint,
                    hintStyle: style.copyWith(color: c.secondaryLabel),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// iOS 风格开关：38×22 轨道、18 圆钮。
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: Pressable(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        isButton: false,
        focusRadius: 11,
        builder: (context, st) => Opacity(
          opacity: st.enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 38,
            height: 22,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value ? c.switchOn : c.separator,
              borderRadius: BorderRadius.circular(11),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: c.knob,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: c.shadow,
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 复选框（16×16，强调色填充）。带 [label] 时整行可点。
class AppCheckbox extends StatelessWidget {
  const AppCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      checked: value,
      label: semanticLabel ?? label,
      child: Pressable(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        isButton: false,
        focusRadius: 4,
        builder: (context, st) => Opacity(
          opacity: st.enabled ? 1 : 0.45,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: value ? c.accent : c.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: value
                      ? null
                      : Border.all(color: c.controlBorder, width: 1.2),
                ),
                child: value
                    ? AppIcon(
                        AppIcons.check,
                        size: 14,
                        color: c.onAccent,
                        strokeWidth: 2.8,
                      )
                    : null,
              ),
              if (label != null) ...[
                const SizedBox(width: AppSpacing.md),
                ExcludeSemantics(
                  child: Text(
                    label!,
                    style: context.type.body.copyWith(color: c.label),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 单选按钮（16×16 圆，选中为强调色 + 白点）。
class AppRadio<T> extends StatelessWidget {
  const AppRadio({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.label,
  });

  final T value;
  final T groupValue;
  final ValueChanged<T>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final on = value == groupValue;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: on,
      label: label,
      child: Pressable(
        onTap: onChanged == null ? null : () => onChanged!(value),
        isButton: false,
        focusRadius: 8,
        builder: (context, st) => Opacity(
          opacity: st.enabled ? 1 : 0.45,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? c.accent : c.surface,
                  shape: BoxShape.circle,
                  border: on
                      ? null
                      : Border.all(color: c.controlBorder, width: 1.2),
                ),
                child: on
                    ? Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: c.onAccent,
                          shape: BoxShape.circle,
                        ),
                      )
                    : null,
              ),
              if (label != null) ...[
                const SizedBox(width: AppSpacing.md),
                ExcludeSemantics(
                  child: Text(
                    label!,
                    style: context.type.body.copyWith(color: c.label),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 滑块：4px 轨道、强调色填充、白色圆钮。支持拖动、点击与 ← → 键。
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.min = 0,
    this.max = 100,
    this.step = 1,
    this.width = 180,
    this.valueLabel,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final String semanticLabel;
  final double min;
  final double max;
  final double step;
  final double? width;
  final String Function(double)? valueLabel;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  bool _focused = false;

  double get _frac =>
      ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0, 1);

  void _setFromDx(double dx, double width) {
    final f = (dx / width).clamp(0.0, 1.0);
    var v = widget.min + f * (widget.max - widget.min);
    v = (v / widget.step).round() * widget.step;
    widget.onChanged?.call(v.clamp(widget.min, widget.max));
  }

  void _nudge(int dir) => widget.onChanged?.call(
    (widget.value + dir * widget.step).clamp(widget.min, widget.max),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    String fmt(double v) => widget.valueLabel?.call(v) ?? v.round().toString();
    final label = fmt(widget.value);
    return Semantics(
      slider: true,
      label: widget.semanticLabel,
      value: label,
      increasedValue: fmt(
        (widget.value + widget.step).clamp(widget.min, widget.max),
      ),
      decreasedValue: fmt(
        (widget.value - widget.step).clamp(widget.min, widget.max),
      ),
      onIncrease: () => _nudge(1),
      onDecrease: () => _nudge(-1),
      child: FocusableActionDetector(
        enabled: widget.onChanged != null,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowRight): _NudgeIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowUp): _NudgeIntent(1),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _NudgeIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowDown): _NudgeIntent(-1),
        },
        actions: {
          _NudgeIntent: CallbackAction<_NudgeIntent>(
            onInvoke: (i) {
              _nudge(i.dir);
              return null;
            },
          ),
        },
        mouseCursor: SystemMouseCursors.click,
        child: SizedBox(
          width: widget.width,
          height: 22,
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              const knob = 18.0;
              final track = w - knob;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) =>
                    _setFromDx(d.localPosition.dx - knob / 2, track),
                onHorizontalDragUpdate: (d) =>
                    _setFromDx(d.localPosition.dx - knob / 2, track),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Positioned(
                      left: knob / 2,
                      right: knob / 2,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: c.separator,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      left: knob / 2,
                      width: track * _frac,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      left: track * _frac,
                      child: Container(
                        width: knob,
                        height: knob,
                        decoration: BoxDecoration(
                          color: c.knob,
                          shape: BoxShape.circle,
                          border: _focused
                              ? Border.all(color: c.accent, width: 2)
                              : null,
                          boxShadow: [
                            BoxShadow(
                              color: c.shadow,
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                            BoxShadow(
                              color: c.shadow,
                              blurRadius: 0,
                              spreadRadius: 0.5,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NudgeIntent extends Intent {
  const _NudgeIntent(this.dir);
  final int dir;
}
