import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'app_icon.dart';

class MenuOption<T> {
  const MenuOption(this.value, this.label);

  final T value;
  final String label;
}

/// 下拉菜单（NSMenu / UIMenu 风格）：白底圆角 10、选中项前打勾。
///
/// [anchor] 接收一个打开 / 关闭菜单的回调，通常交给按钮的 onPressed。
class AppMenu<T> extends StatelessWidget {
  const AppMenu({
    super.key,
    required this.options,
    required this.onSelected,
    required this.anchor,
    this.selected,
  });

  final List<MenuOption<T>> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  final Widget Function(BuildContext context, VoidCallback toggle) anchor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return MenuAnchor(
      alignmentOffset: const Offset(0, AppSpacing.x1),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shadowColor: WidgetStatePropertyAll(c.shadow),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(AppSpacing.x1)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.group),
            side: BorderSide(color: c.separator),
          ),
        ),
      ),
      menuChildren: [
        for (final o in options)
          MenuItemButton(
            onPressed: () => onSelected(o.value),
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(160, 28)),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: AppSpacing.x2),
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (s) =>
                    s.contains(WidgetState.hovered) ||
                        s.contains(WidgetState.focused)
                    ? c.accentFill
                    : Colors.transparent,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (s) =>
                    s.contains(WidgetState.hovered) ||
                        s.contains(WidgetState.focused)
                    ? c.onAccent
                    : c.label,
              ),
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              textStyle: WidgetStatePropertyAll(t.body),
            ),
            leadingIcon: SizedBox(
              width: 14,
              child: o.value == selected ? const _CurrentColorCheck() : null,
            ),
            child: Text(o.label),
          ),
      ],
      builder: (context, controller, _) => anchor(context, () {
        controller.isOpen ? controller.close() : controller.open();
      }),
    );
  }
}

class _CurrentColorCheck extends StatelessWidget {
  const _CurrentColorCheck();

  @override
  Widget build(BuildContext context) {
    final color =
        DefaultTextStyle.of(context).style.color ?? context.colors.label;
    return AppIcon(AppIcons.check, size: 14, color: color, strokeWidth: 2.4);
  }
}
