import 'package:flutter/material.dart';

import '../platform/window_chrome.dart';
import '../theme/theme.dart';
import '../widgets/widgets.dart';

/// 应用外壳（HANDOFF.md §4 / §11）：
/// - ≥ 900：完整侧边栏（224）
/// - 600–900：64px 图标栏
/// - < 600：隐藏侧边栏，底部标签栏
///
/// 只负责布局；导航数据由 lib/app/ 组装后传入。
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.sidebarSections,
    required this.selectedSidebarId,
    required this.onSidebarSelect,
    required this.tabs,
    required this.selectedTabId,
    required this.onTabSelect,
    this.user,
    this.onUserSettings,
  });

  final Widget child;
  final List<SidebarSection> sidebarSections;
  final String? selectedSidebarId;
  final ValueChanged<String> onSidebarSelect;
  final List<TabItem> tabs;
  final String selectedTabId;
  final ValueChanged<String> onTabSelect;
  final SidebarUser? user;
  final VoidCallback? onUserSettings;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final size = LayoutSize.of(MediaQuery.sizeOf(context).width);

    if (size.isMobile) {
      return Scaffold(
        backgroundColor: c.mobileBackground,
        // 内容延伸到半透明标签栏下方；页面按 MediaQuery 底部内边距留白。
        extendBody: true,
        body: child,
        bottomNavigationBar: MobileTabBar(
          items: tabs,
          selectedId: selectedTabId,
          onSelect: onTabSelect,
        ),
      );
    }

    final band = WindowChrome.titlebarHeight;
    return Scaffold(
      backgroundColor: c.windowBackground,
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSidebar(
                compact: size == LayoutSize.medium,
                topInset: band,
                sections: sidebarSections,
                selectedId: selectedSidebarId,
                onSelect: onSidebarSelect,
                user: user,
                onUserSettings: onUserSettings,
              ),
              Expanded(child: child),
            ],
          ),
          // macOS 标题栏区域：拖动窗口、双击缩放。
          Positioned(left: 0, right: 0, top: 0, child: WindowDragArea(height: band)),
        ],
      ),
    );
  }
}
