import 'package:flutter/material.dart';

import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';

/// 尚未实现的页面：保留标题、路由和设计稿出处，按 HANDOFF.md §9 的阶段逐个替换。
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({
    super.key,
    required this.title,
    this.mobileTitle,
    required this.icon,
    required this.design,
    required this.phase,
    this.subtitle,
    this.params = const {},
    this.inspectorTitle,
  });

  final String title;
  final String? mobileTitle;
  final AppIcons icon;

  /// 对应的设计稿文件名。
  final String design;
  final int phase;
  final String? subtitle;

  /// 路由参数（设备 id 等），用于确认路由已正确解析。
  final Map<String, String> params;

  /// 设计稿里带右栏的页面，显示右栏占位，便于检查断点切换。
  final String? inspectorTitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final paramText = params.entries
        .map((e) => '${e.key} = ${e.value}')
        .join(' · ');
    return AppPage(
      title: title,
      mobileTitle: mobileTitle,
      subtitle: subtitle,
      inspectorLabel: inspectorTitle,
      inspector: inspectorTitle == null
          ? null
          : _InspectorPlaceholder(title: inspectorTitle!),
      children: [
        AppCard(
          child: EmptyState(
            icon: icon,
            title: '「$title」将在第 $phase 阶段实现',
            message: [
              '设计稿：$design',
              if (paramText.isNotEmpty) '路由参数：$paramText',
            ].join('\n'),
          ),
        ),
        Text(
          '第 2 阶段只搭建外壳与路由；此页内容按 HANDOFF.md §9 第 $phase 阶段实现。',
          style: context.type.footnote.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }
}

class _InspectorPlaceholder extends StatelessWidget {
  const _InspectorPlaceholder({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 150,
          decoration: BoxDecoration(
            color: c.fillSecondary,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          alignment: Alignment.center,
          child: Text(
            title,
            style: context.type.cardTitle.copyWith(color: c.secondaryLabel),
          ),
        ),
        const SizedBox(height: AppSpacing.x3),
        Text(
          '右栏：≥ 1280 显示在右侧，900–1280 及以下堆到内容下方。',
          style: context.type.footnote.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }
}
