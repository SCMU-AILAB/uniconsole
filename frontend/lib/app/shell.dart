import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/layout/app_shell.dart';
import '../core/theme/theme.dart';
import '../core/widgets/widgets.dart';
import '../data/providers.dart';
import '../features/alerts/alert_push.dart';
import '../features/fleet/fleet_widgets.dart';
import 'command_palette.dart';
import 'destinations.dart';

/// 「单机操控」「感知中心」默认打开的设备：当前用户正在使用的第一台，否则第一台。
final focusedDeviceIdProvider = Provider<String?>((ref) {
  final devices = ref.watch(devicesProvider).value ?? const [];
  final me = ref.watch(currentUserProvider).value;
  if (devices.isEmpty) return null;
  return devices
          .where((d) => me != null && d.userId == me.id)
          .firstOrNull
          ?.id ??
      devices.first.id;
});

/// 侧边栏 / 标签栏入口 id → 路由。
String? locationFor(String id, WidgetRef ref) {
  final device = ref.read(focusedDeviceIdProvider);
  final session = ref.read(fleetSessionsProvider).value?.firstOrNull?.id;
  if (id.startsWith('group:')) {
    return '${Routes.devices}?group=${id.substring(6)}';
  }
  return switch (id) {
    'devices' => Routes.devices,
    'control' => device == null ? Routes.devices : Routes.control(device),
    'sensors' => device == null ? Routes.devices : Routes.sensors(device),
    'fleet' => session == null ? Routes.fleetHome : Routes.fleet(session),
    'missions' => Routes.missions,
    'alerts' => Routes.alerts,
    'replay' => Routes.recordings,
    'maintenance' => Routes.maintenance,
    'safety' => Routes.safety,
    'leases' => Routes.leases,
    'members' => Routes.members,
    'agent' => Routes.agent,
    'settings' => Routes.settings,
    'me' => Routes.me,
    'gallery' => Routes.gallery,
    _ => null,
  };
}

/// 把导航数据（计数来自同一数据源，§8.5）组装进 [AppShell]，并注册全局快捷键。
class ShellScaffold extends ConsumerWidget {
  const ShellScaffold({super.key, required this.location, required this.child});

  final Uri location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(fleetSummaryProvider);
    final groups = ref.watch(deviceGroupsProvider).value ?? const [];
    final presets = ref.watch(fleetPresetsProvider).value ?? const [];
    final onFleet = sidebarIdFor(location) == 'fleet';
    final me = ref.watch(currentUserProvider).value;
    final status = context.status;

    void go(String id) {
      if (id.startsWith('preset:')) {
        startFleetPreset(context, ref, id.substring(7));
        return;
      }
      final loc = locationFor(id, ref);
      if (loc != null) context.go(loc);
    }

    // ⌘⇧E 全局急停（Settings.dc.html 快捷键）：只触发，解除需要到安全策略页确认。
    void globalEstop() =>
        ref.read(safetyRepositoryProvider).setGlobalEstop(active: true);

    int? positive(int n) => n > 0 ? n : null;

    SidebarItem item(NavEntry e) => SidebarItem(
      id: e.id,
      label: e.label,
      icon: e.icon,
      count: switch (e.id) {
        'fleet' => positive(summary.fleetSessions),
        'leases' => positive(summary.pendingLeaseRequests),
        _ => null,
      },
      badge: e.id == 'alerts' ? positive(summary.openAlerts) : null,
    );

    final sections = [
      SidebarSection(title: '工作台', items: [for (final e in workbench) item(e)]),
      SidebarSection(title: '运维', items: [for (final e in operations) item(e)]),
      SidebarSection(title: '管理', items: [for (final e in management) item(e)]),
      // 第四组随页面变化：联调页显示「联调预设」（Fleet.dc.html），其余显示设备分组。
      if (onFleet && presets.isNotEmpty)
        SidebarSection(
          title: '联调预设',
          items: [
            for (final p in presets)
              SidebarItem(
                id: 'preset:${p.id}',
                label: '${p.name} · ${p.deviceIds.length} 台',
              ),
          ],
        )
      else if (groups.isNotEmpty)
        SidebarSection(
          title: '设备分组',
          items: [
            for (final g in groups)
              SidebarItem(
                id: 'group:${g.id}',
                label: g.name,
                dotColor: status.of(StatusTone.values.byName(g.tone)).dot,
                count: summary.groupCounts[g.id],
              ),
          ],
        ),
      if (showDevEntries)
        const SidebarSection(
          title: '开发',
          items: [
            SidebarItem(id: 'gallery', label: '组件预览', icon: AppIcons.devices),
          ],
        ),
    ];

    final tabs = [
      for (final t in MobileTabBar.defaultItems)
        t.id == 'alerts'
            ? TabItem(
                id: t.id,
                label: t.label,
                icon: t.icon,
                badge: positive(summary.openAlerts),
              )
            : t,
    ];

    final prefs = ref.watch(preferencesProvider);
    final shell = CallbackShortcuts(
      bindings: {
        // Settings.dc.html 快捷键：⌘J 呼出智能体；⌘, 为 macOS 通用的设置。
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): () =>
            go('agent'),
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): () =>
            go('agent'),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            go('settings'),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            go('settings'),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true, shift: true):
            globalEstop,
        const SingleActivator(
          LogicalKeyboardKey.keyE,
          control: true,
          shift: true,
        ): globalEstop,
      },
      child: Focus(
        autofocus: true,
        child: AlertPushOverlay(
          child: AppShell(
            sidebarSections: sections,
            selectedSidebarId: sidebarIdFor(location),
            onSidebarSelect: go,
            tabs: tabs,
            selectedTabId: tabIdFor(location),
            onTabSelect: go,
            user: me == null
                ? null
                : SidebarUser(
                    name: me.name,
                    role: me.role.label,
                    color: context.colors.avatarPalette.first,
                  ),
            onUserSettings: () => go('settings'),
            immersive: tabIdFor(location) == 'control',
            sidebarIconSize: prefs.sidebarIconSize.icon,
            child: child,
          ),
        ),
      ),
    );
    // 设置 › 外观「操控时保持深色」：操控页整窗使用深色。
    if (!prefs.darkWhileControlling || tabIdFor(location) != 'control') {
      return shell;
    }
    return Theme(
      data: AppTheme.dark(swatch: ref.watch(accentProvider)),
      child: shell,
    );
  }
}
