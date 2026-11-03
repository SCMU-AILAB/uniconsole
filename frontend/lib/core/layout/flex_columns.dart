import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// 设计稿里的 flex-wrap 分栏：主栏 `flex: 999 1 <mainMin>`，左右栏 `flex: 1 0 <宽度>`。
///
/// 放得下时并排（左右栏固定宽、主栏占满其余）；放不下时先把右栏换到下方，
/// 仍放不下则全部纵向堆叠，换行后的栏占满宽度。
class FlexColumns extends StatelessWidget {
  const FlexColumns({
    super.key,
    required this.main,
    this.leading,
    this.trailing,
    this.mainMin = 520,
    this.leadingWidth = 260,
    this.trailingWidth = 300,
    this.gap = AppSpacing.x4,
  });

  final Widget main;
  final Widget? leading;
  final Widget? trailing;
  final double mainMin;
  final double leadingWidth;
  final double trailingWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final lead = leading == null ? 0.0 : leadingWidth + gap;
        final trail = trailing == null ? 0.0 : trailingWidth + gap;

        Widget row({required bool withTrailing}) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[
              SizedBox(width: leadingWidth, child: leading),
              SizedBox(width: gap),
            ],
            Expanded(child: main),
            if (withTrailing && trailing != null) ...[
              SizedBox(width: gap),
              SizedBox(width: trailingWidth, child: trailing),
            ],
          ],
        );

        Widget stack(List<Widget?> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, item) in items.nonNulls.indexed) ...[
              if (i > 0) SizedBox(height: gap),
              item,
            ],
          ],
        );

        if (w >= lead + mainMin + trail) return row(withTrailing: true);
        if (leading != null && w >= lead + mainMin) {
          return stack([row(withTrailing: false), trailing]);
        }
        return stack([leading, main, trailing]);
      },
    );
  }
}
