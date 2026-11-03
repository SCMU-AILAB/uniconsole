import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'app_icon.dart';
import 'buttons.dart';
import 'pressable.dart';
import 'status.dart';
import 'surfaces.dart';

class SidebarItem {
  const SidebarItem({
    required this.id,
    required this.label,
    this.icon,
    this.dotColor,
    this.count,
    this.badge,
  });

  final String id;
  final String label;
  final AppIcons? icon;

  /// 设备分组用彩色圆点代替图标。
  final Color? dotColor;

  /// 灰色计数（如「多机联调 1」）。
  final int? count;

  /// 红色徽标计数（如「告警中心 2」）。
  final int? badge;
}

class SidebarSection {
  const SidebarSection({this.title, required this.items});

  final String? title;
  final List<SidebarItem> items;
}

class SidebarUser {
  const SidebarUser({required this.name, required this.role, this.color});

  final String name;
  final String role;
  final Color? color;
}

/// 桌面侧边栏（Main.dc.html 左栏）。[compact] 为 600–900 宽度下的 64px 图标栏。
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.sections,
    required this.selectedId,
    required this.onSelect,
    this.title = 'UniConsole',
    this.subtitle = '机器人管理与联控',
    this.user,
    this.onUserSettings,
    this.compact = false,
    this.topInset = 0,
  });

  final List<SidebarSection> sections;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final String title;
  final String subtitle;
  final SidebarUser? user;
  final VoidCallback? onUserSettings;
  final bool compact;

  /// 为 macOS 红黄绿按钮预留的顶部空间（第 2 阶段全尺寸内容视图时使用）。
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final brand = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.logo,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: AppIcon(AppIcons.sensors, size: 18, color: c.onLogo),
    );

    final children = <Widget>[
      Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : AppSpacing.x2),
        child: compact
            ? Center(
                child: Tooltip(message: title, child: brand),
              )
            : Row(
                children: [
                  brand,
                  const SizedBox(width: AppSpacing.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: t.headline.copyWith(color: c.label)),
                        const SizedBox(height: AppSpacing.half),
                        Text(
                          subtitle,
                          style: t.caption.copyWith(color: c.secondaryLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    ];

    for (final section in sections) {
      children.add(const SizedBox(height: AppSpacing.x4));
      if (section.title != null) {
        children.add(
          compact
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x2,
                  ),
                  child: Container(height: 1, color: c.sidebarBorder),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.x3,
                    0,
                    AppSpacing.x3,
                    AppSpacing.x1,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      section.title!,
                      style: t.captionStrong.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                ),
        );
        if (compact) children.add(const SizedBox(height: 8));
      }
      for (final item in section.items) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.half),
            child: _SidebarTile(
              item: item,
              selected: item.id == selectedId,
              compact: compact,
              onTap: () => onSelect(item.id),
            ),
          ),
        );
      }
    }

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '主导航',
      child: Container(
        width: compact ? AppSizes.sidebarRailWidth : AppSizes.sidebarWidth,
        decoration: BoxDecoration(
          color: c.sidebarBackground,
          border: Border(right: BorderSide(color: c.sidebarBorder)),
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.x3,
                  AppSpacing.x4 + topInset,
                  AppSpacing.x3,
                  AppSpacing.x4,
                ),
                children: children,
              ),
            ),
            if (user != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x3,
                  0,
                  AppSpacing.x3,
                  AppSpacing.x4,
                ),
                child: compact
                    ? Tooltip(
                        message: '${user!.name} · ${user!.role}',
                        child: Avatar(
                          name: user!.name,
                          size: 30,
                          color: user!.color,
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.all(AppSpacing.x2),
                        decoration: BoxDecoration(
                          color: c.sidebarUserCard,
                          borderRadius: BorderRadius.circular(AppRadius.group),
                        ),
                        child: Row(
                          children: [
                            Avatar(
                              name: user!.name,
                              size: 30,
                              color: user!.color,
                            ),
                            const SizedBox(width: AppSpacing.x3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    user!.name,
                                    style: t.body.copyWith(
                                      color: c.label,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    user!.role,
                                    style: t.caption.copyWith(
                                      color: c.secondaryLabel,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            AppIconButton(
                              icon: AppIcons.settings,
                              label: '设置',
                              onPressed: onUserSettings,
                            ),
                          ],
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.item,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final SidebarItem item;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final leading = item.icon != null
        ? AppIcon(item.icon!, color: selected ? c.accent : c.secondaryLabel)
        : SizedBox(
            width: AppSizes.icon,
            child: Center(
              child: StatusDot(
                StatusTone.offline,
                size: 9,
                color: item.dotColor,
              ),
            ),
          );
    final semantic = [
      item.label,
      if (item.badge != null) '${item.badge} 条未处理',
      if (item.count != null) '${item.count}',
    ].join('，');

    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: semantic,
      tooltip: compact ? item.label : null,
      focusRadius: AppRadius.sm,
      builder: (context, st) {
        // macOS 侧边栏没有悬停态；选中是瞬时的（不滑动、不渐变）。
        final bg = selected
            ? c.sidebarSelected
            : st.pressed
            ? c.sidebarSelected.withValues(alpha: 0.5)
            : c.sidebarSelected.withValues(alpha: 0);
        if (compact) {
          return Container(
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                leading,
                if (item.badge != null)
                  Positioned(
                    top: AppSpacing.half,
                    right: AppSpacing.x1,
                    child: CountBadge(item.badge!, small: true),
                  ),
              ],
            ),
          );
        }
        return Container(
          height: AppSizes.navItemHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.body.copyWith(
                    color: c.label,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              if (item.badge != null)
                CountBadge(item.badge!)
              else if (item.count != null)
                Text(
                  '${item.count}',
                  style: t.caption.copyWith(color: c.secondaryLabel),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 页面工具栏：最小高 52、标题 15 semibold + 11 号副标题，右侧操作自动换行。
class AppToolbar extends StatelessWidget {
  const AppToolbar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.titleWidget,
    this.titleAccessory,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// 自定义标题区（如操控页的设备切换按钮），替代 [title] / [subtitle]。
  final Widget? titleWidget;

  /// 紧跟标题的附件（如联调页的「4 台已同步」胶囊）。
  final Widget? titleAccessory;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Container(
      constraints: const BoxConstraints(minHeight: AppSizes.toolbarMinHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.section,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: c.toolbarBackground,
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final Widget heading = titleWidget != null
              ? Semantics(header: true, label: title, child: titleWidget)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: AppSpacing.x3),
                    ],
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              style: t.toolbarTitle.copyWith(color: c.label),
                            ),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.caption.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (titleAccessory != null) ...[
                      const SizedBox(width: AppSpacing.x3),
                      titleAccessory!,
                    ],
                  ],
                );
          if (actions.isEmpty) {
            return Align(alignment: Alignment.centerLeft, child: heading);
          }
          Widget wrap(WrapAlignment a) => Wrap(
            alignment: a,
            spacing: AppSpacing.x3,
            runSpacing: AppSpacing.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          );
          // 窄时操作项换到标题下方。
          if (box.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: AppSpacing.x2),
                wrap(WrapAlignment.start),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              const SizedBox(width: AppSpacing.x3),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * 0.72),
                child: wrap(WrapAlignment.end),
              ),
            ],
          );
        },
      ),
    );
  }
}

class TabItem {
  const TabItem({
    required this.id,
    required this.label,
    required this.icon,
    this.badge,
  });

  final String id;
  final String label;
  final AppIcons icon;
  final int? badge;
}

/// 移动端底部标签栏：半透明毛玻璃底、5 等分、图标 24 + 10 号字。
class MobileTabBar extends StatelessWidget {
  const MobileTabBar({
    super.key,
    required this.items,
    required this.selectedId,
    required this.onSelect,
  });

  final List<TabItem> items;
  final String selectedId;
  final ValueChanged<String> onSelect;

  /// 设计稿默认 5 个标签：设备 / 操控 / 智能体 / 告警 / 我的。
  static const defaultItems = [
    TabItem(id: 'devices', label: '设备', icon: AppIcons.devices),
    TabItem(id: 'control', label: '操控', icon: AppIcons.control),
    TabItem(id: 'agent', label: '智能体', icon: AppIcons.agent),
    TabItem(id: 'alerts', label: '告警', icon: AppIcons.alerts),
    TabItem(id: 'me', label: '我的', icon: AppIcons.person),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: EdgeInsets.only(
            top: AppSpacing.x2,
            bottom: bottom > 0 ? bottom : AppSpacing.x2,
          ),
          decoration: BoxDecoration(
            color: c.tabBarBackground,
            border: Border(top: BorderSide(color: c.tabBarBorder)),
          ),
          child: Semantics(
            container: true,
            label: '标签栏',
            explicitChildNodes: true,
            child: Row(
              children: [
                for (final it in items)
                  Expanded(
                    child: Pressable(
                      onTap: () => onSelect(it.id),
                      selected: it.id == selectedId,
                      semanticLabel: it.badge == null
                          ? it.label
                          : '${it.label}，${it.badge} 条新告警',
                      focusRadius: AppRadius.md,
                      builder: (context, st) {
                        final color = it.id == selectedId
                            ? c.accent
                            : c.secondaryLabel;
                        return SizedBox(
                          height: 42,
                          child: Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.topCenter,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppIcon(it.icon, size: 24, color: color),
                                  const SizedBox(height: AppSpacing.x1),
                                  Text(
                                    it.label,
                                    style: context.type.tabLabel.copyWith(
                                      color: color,
                                    ),
                                  ),
                                ],
                              ),
                              if (it.badge != null)
                                Positioned(
                                  top: -3,
                                  left: 0,
                                  right: 0,
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    child: Transform.translate(
                                      offset: const Offset(14, 0),
                                      child: CountBadge(it.badge!, small: true),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
