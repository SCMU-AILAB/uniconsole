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
///
/// 与 UISegmentedControl 一致：只有一个选中块，切换时以弹簧滑到新位置（§13）；
/// 每段宽度按选中态（粗体）预留，切换时文字不会跳动。
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

  static const _gap = AppSpacing.half;
  static const _segmentPadding = AppSpacing.x3;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final base = (size == SegmentedSize.mobile ? t.mobileFootnote : t.subhead)
        .copyWith(color: c.label);
    final bold = base.copyWith(fontWeight: FontWeight.w600);
    final scaler = MediaQuery.textScalerOf(context);
    final selected = options.indexWhere((o) => o.value == value);
    // 选项还没加载（如数据流的第一帧）时不占位。
    if (options.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label: semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.half),
        decoration: BoxDecoration(
          color: size == SegmentedSize.mobile
              ? c.mobileControlFill
              : c.segmentedTrack,
          borderRadius: BorderRadius.circular(size.trackRadius),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final gaps = _gap * (options.length - 1);
            final List<double> widths;
            if (expand && box.maxWidth.isFinite) {
              final w = (box.maxWidth - gaps) / options.length;
              widths = List.filled(options.length, w);
            } else {
              widths = [
                for (final o in options)
                  (TextPainter(
                        text: TextSpan(text: o.label, style: bold),
                        textDirection: TextDirection.ltr,
                        textScaler: scaler,
                        maxLines: 1,
                      )..layout()).width.ceilToDouble() +
                      _segmentPadding * 2,
              ];
            }
            var left = 0.0;
            for (var i = 0; i < selected; i++) {
              left += widths[i] + _gap;
            }

            return SizedBox(
              width: widths.fold<double>(0, (a, w) => a + w) + gaps,
              height: size.height,
              child: Stack(
                children: [
                  if (selected >= 0)
                    AnimatedPositioned(
                      duration: AppMotion.move(context, AppMotion.snappy),
                      curve: AppMotion.snappy,
                      left: left,
                      top: 0,
                      bottom: 0,
                      width: widths[selected],
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: c.segmentedSelected,
                          borderRadius: BorderRadius.circular(size.radius),
                          boxShadow: c.isDark
                              ? null
                              : [
                                  BoxShadow(
                                    color: c.shadow,
                                    blurRadius: 2,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        if (i > 0) const SizedBox(width: _gap),
                        SizedBox(
                          width: widths[i],
                          child: Pressable(
                            onTap: () => onChanged(options[i].value),
                            semanticLabel:
                                options[i].semanticLabel ?? options[i].label,
                            selected: i == selected,
                            focusRadius: size.radius,
                            builder: (context, st) => AnimatedContainer(
                              duration: AppMotion.fade(pressed: st.pressed),
                              curve: AppMotion.highlightCurve,
                              height: size.height,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: st.pressed && i != selected
                                    ? c.label.withValues(alpha: 0.06)
                                    : c.label.withValues(alpha: 0),
                                borderRadius: BorderRadius.circular(
                                  size.radius,
                                ),
                              ),
                              child: AnimatedDefaultTextStyle(
                                duration: AppMotion.highlight,
                                style: i == selected ? bold : base,
                                child: Text(
                                  options[i].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  softWrap: false,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            );
          },
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
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
      decoration: BoxDecoration(
        color: mobile ? c.mobileControlFill : c.segmentedTrack,
        borderRadius: BorderRadius.circular(
          mobile ? AppRadius.group : AppRadius.sm,
        ),
      ),
      child: Row(
        children: [
          AppIcon(AppIcons.search, size: mobile ? 16 : 14, strokeWidth: 2),
          const SizedBox(width: AppSpacing.x2),
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

/// 文本输入框（描边 1px、圆角 8）。[minLines] > 1 时为多行（附言、原因）。
/// 获得焦点时描边变为强调色并带 3pt 外圈（macOS 焦点环）。
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.minLines = 1,
    this.maxLines,
    this.autofocus = false,
    this.semanticLabel,
    this.mobile = false,
    this.focusNode,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.enabled = true,
    this.suffix,
    this.monospace = false,
  });

  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int minLines;
  final int? maxLines;
  final bool autofocus;
  final String? semanticLabel;

  /// 移动端字号 16（避免 iOS 聚焦时自动放大）。
  final bool mobile;

  /// 外部焦点（表单里按回车跳到下一项）；为空时内部创建。
  final FocusNode? focusNode;

  /// 密码。
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  /// 系统密码管理器自动填充（[AutofillHints.username] 等）。
  final Iterable<String>? autofillHints;
  final bool enabled;

  /// 输入框右侧的附件（如「显示密码」按钮）。
  final Widget? suffix;

  /// 等宽字体（验证码）。
  final bool monospace;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_changed);
  }

  @override
  void didUpdateWidget(AppTextField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_changed);
      _focus.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_changed);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = widget.mobile
        ? context.type.mobileBody.copyWith(fontSize: 16)
        : context.type.body.copyWith(fontSize: 12.5);
    final style =
        (widget.monospace
                ? context.type.monoLarge.copyWith(
                    fontSize: base.fontSize,
                    letterSpacing: 2,
                  )
                : base)
            .copyWith(color: widget.enabled ? c.label : c.secondaryLabel);
    final focused = _focus.hasFocus;
    final multiline = widget.minLines > 1;
    return AnimatedContainer(
      duration: AppMotion.highlight,
      curve: AppMotion.highlightCurve,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: widget.enabled ? c.surface : c.fillSecondary,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: focused ? c.accent : c.controlBorder),
        boxShadow: [
          BoxShadow(
            color: focused ? c.accentRing : c.accentRing.withValues(alpha: 0),
            spreadRadius: 3,
          ),
        ],
      ),
      child: Semantics(
        label: widget.semanticLabel ?? widget.hint,
        textField: true,
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  enabled: widget.enabled,
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmitted,
                  obscureText: widget.obscureText,
                  autocorrect: !widget.obscureText,
                  enableSuggestions: !widget.obscureText,
                  autofillHints: widget.autofillHints,
                  minLines: widget.minLines,
                  maxLines: multiline
                      ? (widget.maxLines ?? widget.minLines + 4)
                      : 1,
                  keyboardType:
                      widget.keyboardType ??
                      (multiline ? TextInputType.multiline : null),
                  textInputAction:
                      widget.textInputAction ??
                      (multiline ? null : TextInputAction.done),
                  style: style,
                  cursorColor: c.accent,
                  cursorHeight: style.fontSize! + 2,
                  decoration: InputDecoration.collapsed(
                    hintText: widget.hint,
                    hintStyle: style.copyWith(
                      color: c.secondaryLabel,
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ),
              if (widget.suffix != null) ...[
                const SizedBox(width: AppSpacing.x2),
                widget.suffix!,
              ],
            ],
          ),
        ),
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
          // 轨道颜色淡入，圆钮以弹簧滑动；按住时圆钮横向拉长（UISwitch 的按压反馈）。
          child: AnimatedContainer(
            duration: AppMotion.highlight * 1.5,
            curve: AppMotion.highlightCurve,
            width: 38,
            height: 22,
            padding: const EdgeInsets.all(AppSpacing.half),
            decoration: BoxDecoration(
              color: value ? c.switchOn : c.separator,
              borderRadius: BorderRadius.circular(11),
            ),
            child: AnimatedAlign(
              duration: AppMotion.move(context, AppMotion.snappy),
              curve: AppMotion.snappy,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: AnimatedContainer(
                duration: AppMotion.move(context, AppMotion.snappy),
                curve: AppMotion.snappy,
                width: st.pressed && !AppMotion.reduced(context) ? 22 : 18,
                height: 18,
                decoration: BoxDecoration(
                  color: c.knob,
                  borderRadius: BorderRadius.circular(9),
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
              AnimatedContainer(
                duration: AppMotion.highlight,
                curve: AppMotion.highlightCurve,
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: value ? c.accent : c.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: value ? c.accent : c.controlBorder,
                    width: 1.2,
                  ),
                ),
                child: AnimatedScale(
                  duration: AppMotion.move(context, AppMotion.snappy),
                  curve: AppMotion.snappy,
                  scale: value ? 1 : 0.4,
                  child: AnimatedOpacity(
                    duration: AppMotion.highlight,
                    opacity: value ? 1 : 0,
                    child: AppIcon(
                      AppIcons.check,
                      size: 14,
                      color: c.onAccent,
                      strokeWidth: 2.8,
                    ),
                  ),
                ),
              ),
              if (label != null) ...[
                const SizedBox(width: AppSpacing.x2),
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
              AnimatedContainer(
                duration: AppMotion.highlight,
                curve: AppMotion.highlightCurve,
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? c.accent : c.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: on ? c.accent : c.controlBorder,
                    width: 1.2,
                  ),
                ),
                // 选中时中心白点以弹簧放大出现。
                child: AnimatedScale(
                  duration: AppMotion.move(context, AppMotion.snappy),
                  curve: AppMotion.snappy,
                  scale: on ? 1 : 0,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: c.onAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              if (label != null) ...[
                const SizedBox(width: AppSpacing.x2),
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
