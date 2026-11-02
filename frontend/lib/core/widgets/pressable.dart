import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// 交互状态，供可点击组件按状态绘制外观。
@immutable
class PressState {
  const PressState({
    required this.hovered,
    required this.pressed,
    required this.focused,
    required this.enabled,
  });

  final bool hovered;
  final bool pressed;
  final bool focused;
  final bool enabled;
}

/// 所有可点击组件的底层：鼠标悬停、按下、键盘焦点（空格/回车触发）、语义。
///
/// 焦点时外圈绘制 accentRing，满足 §10「可用键盘遍历主要操作」。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.onTap,
    required this.builder,
    this.semanticLabel,
    this.tooltip,
    this.selected,
    this.toggled,
    this.isButton = true,
    this.focusRadius = AppRadius.md,
    this.cursor = SystemMouseCursors.click,
    this.autofocus = false,
  });

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, PressState state) builder;
  final String? semanticLabel;
  final String? tooltip;
  final bool? selected;

  /// 开关类按钮的按下状态（aria-pressed）。
  final bool? toggled;
  final bool isButton;
  final double focusRadius;
  final MouseCursor cursor;
  final bool autofocus;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final state = PressState(
      hovered: _hovered && _enabled,
      pressed: _pressed && _enabled,
      focused: _focused && _enabled,
      enabled: _enabled,
    );
    Widget child = FocusableActionDetector(
      enabled: _enabled,
      autofocus: widget.autofocus,
      mouseCursor: _enabled ? widget.cursor : SystemMouseCursors.basic,
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.focusRadius),
            border: state.focused
                ? Border.all(
                    color: context.colors.accent.withValues(alpha: 0.5),
                    width: 2.5,
                    strokeAlign: BorderSide.strokeAlignOutside,
                  )
                : null,
          ),
          child: widget.builder(context, state),
        ),
      ),
    );
    child = Semantics(
      button: widget.isButton,
      enabled: _enabled,
      selected: widget.selected,
      toggled: widget.toggled,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      child: child,
    );
    if (widget.tooltip != null) {
      child = Tooltip(
        message: widget.tooltip!,
        excludeFromSemantics: true,
        child: child,
      );
    }
    return child;
  }
}
