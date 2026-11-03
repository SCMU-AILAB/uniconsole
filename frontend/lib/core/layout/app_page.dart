import 'package:flutter/material.dart';

import '../platform/window_chrome.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';
import 'large_title_scroll_view.dart';

/// 页面骨架：按断点（HANDOFF.md §11）组织工具栏、内容与右栏。
///
/// - ≥ 1280：内容 + 右侧检查器（340 宽，贯通到窗口顶部）。
/// - 600–1280：检查器堆到内容下方。
/// - < 600：iOS 大标题滚动视图，检查器同样堆在下方。
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.title,
    this.mobileTitle,
    this.subtitle,
    this.actions = const [],
    this.mobileActions = const [],
    required this.children,
    this.inspector,
    this.inspectorLabel,
    this.gap = AppSpacing.section,
    this.largeTitle = true,
    this.backLabel,
    this.toolbarTitle,
    this.titleAccessory,
  });

  /// 桌面工具栏标题。
  final String title;

  /// 移动端大标题，默认同 [title]（如桌面「设备总览」、移动「设备」）。
  final String? mobileTitle;
  final String? subtitle;

  /// 桌面工具栏右侧操作。
  final List<Widget> actions;

  /// 移动端标题栏右侧操作（圆形图标按钮）。
  final List<Widget> mobileActions;
  final List<Widget> children;

  /// 右栏 / 检查器内容。
  final Widget? inspector;

  /// 检查器的读屏标签，如「设备详情」。
  final String? inspectorLabel;
  final double gap;

  /// 移动端是否使用大标题；二级页面用 false（内联 17pt 标题）。
  final bool largeTitle;

  /// 移动端返回按钮上显示的上一级标题（iOS「‹ 设备」）。
  final String? backLabel;

  /// 桌面工具栏的自定义标题区。
  final Widget? toolbarTitle;

  /// 桌面工具栏标题右侧的附件。
  final Widget? titleAccessory;

  @override
  Widget build(BuildContext context) {
    final size = LayoutSize.ofContext(context);
    return size.isMobile ? _mobile(context) : _desktop(context, size);
  }

  /// 从「我的」等入口 push 进来的页面显示返回按钮。
  Widget? _back(BuildContext context, {required bool mobile}) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    if (!canPop) return null;
    if (mobile) return _BackLink(label: backLabel);
    return AppIconButton(
      icon: AppIcons.chevronLeft,
      label: '返回',
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }

  List<Widget> _spaced(List<Widget> items) => [
    for (var i = 0; i < items.length; i++) ...[
      if (i > 0) SizedBox(height: gap),
      items[i],
    ],
  ];

  Widget _inspectorCard(BuildContext context) {
    final c = context.colors;
    return Semantics(
      container: true,
      label: inspectorLabel,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.section),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        child: inspector,
      ),
    );
  }

  Widget _desktop(BuildContext context, LayoutSize size) {
    final c = context.colors;
    final band = WindowChrome.titlebarHeight;
    final sideBySide = inspector != null && size == LayoutSize.wide;

    final content = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.section,
        AppSpacing.page,
        28,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _spaced([
          ...children,
          if (inspector != null && !sideBySide) _inspectorCard(context),
        ]),
      ),
    );

    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (band > 0) Container(height: band, color: c.toolbarBackground),
        AppToolbar(
          title: title,
          titleWidget: toolbarTitle,
          titleAccessory: titleAccessory,
          subtitle: subtitle,
          leading: _back(context, mobile: false),
          actions: actions,
        ),
        Expanded(child: content),
      ],
    );
    if (!sideBySide) return main;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: main),
        Semantics(
          container: true,
          label: inspectorLabel,
          child: Container(
            width: AppSizes.inspectorWidth,
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(left: BorderSide(color: c.separator)),
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.section,
                AppSpacing.section + band,
                AppSpacing.section,
                AppSpacing.section,
              ),
              child: inspector,
            ),
          ),
        ),
      ],
    );
  }

  Widget _mobile(BuildContext context) {
    final c = context.colors;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return LargeTitleScrollView(
      large: largeTitle,
      title: mobileTitle ?? title,
      leading: _back(context, mobile: true),
      actions: mobileActions,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.x4,
            0,
            AppSpacing.x4,
            bottom + AppSpacing.page,
          ),
          sliver: SliverList.list(
            children: [
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.x3),
                  child: Text(
                    subtitle!,
                    style: context.type.mobileFootnote.copyWith(
                      color: c.secondaryLabel,
                    ),
                  ),
                ),
              ..._spaced([
                ...children,
                if (inspector != null) _inspectorCard(context),
              ]),
            ],
          ),
        ),
      ],
    );
  }
}

/// iOS 返回按钮：强调色箭头 + 上一级标题。
class _BackLink extends StatelessWidget {
  const _BackLink({required this.label});

  /// 上一级标题；为空时显示「返回」。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: () => Navigator.of(context).maybePop(),
      semanticLabel: label == null ? '返回' : '返回$label',
      focusRadius: AppRadius.md,
      builder: (context, st) => AnimatedOpacity(
        duration: AppMotion.fade(pressed: st.pressed),
        opacity: st.pressed ? 0.4 : 1,
        child: SizedBox(
          height: AppSizes.minTouchTarget,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                AppIcons.chevronLeft,
                size: 22,
                color: c.link,
                strokeWidth: 2.2,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 88),
                child: Text(
                  label ?? '返回',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.type.mobileBodyLarge.copyWith(color: c.link),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
