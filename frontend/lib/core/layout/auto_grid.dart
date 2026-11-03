import 'package:flutter/widgets.dart';

import '../theme/theme.dart';

/// 等价于 CSS `grid-template-columns: repeat(auto-fit, minmax(<min>, 1fr))`：
/// 按最小列宽决定列数，列数不超过子项数，子项拉伸填满一行。
class AutoGrid extends StatelessWidget {
  const AutoGrid({
    super.key,
    required this.minItemWidth,
    required this.children,
    this.gap = AppSpacing.x2,
  });

  final double minItemWidth;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = ((box.maxWidth + gap) / (minItemWidth + gap))
            .floor()
            .clamp(1, children.isEmpty ? 1 : children.length);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in children) SizedBox(width: w, child: c)],
        );
      },
    );
  }
}

/// 灰底信息小格：小标签 + 中粗值（Lease.dc.html「租约规则」、Safety.dc.html 围栏详情）。
class InfoTile extends StatelessWidget {
  const InfoTile({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: c.windowBackground,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.caption.copyWith(color: c.secondaryLabel)),
          const SizedBox(height: AppSpacing.half),
          Text(value, style: t.bodyMedium.copyWith(color: c.label)),
        ],
      ),
    );
  }
}
