import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../core/layout/app_route_page.dart';
import '../core/widgets/widgets.dart';
import '../core/theme/theme.dart';
import '../features/alerts/alert_detail_page.dart';
import '../features/alerts/alerts_page.dart';
import '../features/common/placeholder_page.dart';
import '../features/control/control_page.dart';
import '../features/devices/device_detail_page.dart';
import '../features/devices/devices_page.dart';
import '../features/fleet/fleet_page.dart';
import '../features/gallery/gallery_page.dart';
import '../features/leases/leases_page.dart';
import '../features/me/me_page.dart';
import '../features/replay/replay_page.dart';
import '../features/missions/missions_page.dart';
import '../features/sensors/sensors_page.dart';
import '../features/safety/safety_page.dart';
import '../features/settings/settings_page.dart';
import 'destinations.dart';
import 'shell.dart';

/// 路由表（HANDOFF.md §2）。桌面与移动共用同一套路由，只是布局不同。
GoRouter buildRouter({String initialLocation = Routes.devices}) {
  // 根页面瞬时切换，push 进入时 iOS 推入（§13）。
  Page<void> page(GoRouterState state, Widget child) => AppRoutePage(
    key: state.pageKey,
    push: state.extra == NavIntent.push,
    child: child,
  );

  GoRoute placeholder(
    String path, {
    required String title,
    String? mobileTitle,
    required AppIcons icon,
    required String design,
    required int phase,
    String? inspector,
    List<RouteBase> routes = const [],
  }) => GoRoute(
    path: path,
    pageBuilder: (context, state) => page(
      state,
      PlaceholderPage(
        title: title,
        mobileTitle: mobileTitle,
        icon: icon,
        design: design,
        phase: phase,
        params: state.pathParameters,
        inspectorTitle: inspector,
      ),
    ),
    routes: routes,
  );

  return GoRouter(
    initialLocation: initialLocation,
    redirect: (context, state) => state.uri.path == '/' ? Routes.devices : null,
    routes: [
      ShellRoute(
        // 外壳本身不做转场、不加遮罩（macOS / iOS 上默认的 CupertinoPage 会压暗整个窗口）。
        pageBuilder: (context, state, child) => NoTransitionPage(
          key: state.pageKey,
          child: ShellScaffold(location: state.uri, child: child),
        ),
        routes: [
          // 顺序有意义：更具体的设备子路由放在 /devices 之前。
          // 都是顶层路由：从侧边栏 go 过来是单个根页面（无返回按钮），
          // 从设备详情 / 移动端列表 push 进来才有返回。
          GoRoute(
            path: '/devices/:id/control',
            pageBuilder: (context, state) =>
                page(state, ControlPage(deviceId: state.pathParameters['id']!)),
          ),
          GoRoute(
            path: '/devices/:id/sensors',
            pageBuilder: (context, state) =>
                page(state, SensorsPage(deviceId: state.pathParameters['id']!)),
          ),
          GoRoute(
            path: '/devices/:id',
            pageBuilder: (context, state) {
              final id = state.pathParameters['id']!;
              // 移动端是设备详情页；桌面宽度下显示设备总览并选中该设备。
              final mobile = LayoutSize.ofContext(context).isMobile;
              return page(
                state,
                mobile
                    ? DeviceDetailPage(deviceId: id)
                    : DevicesPage(selectId: id),
              );
            },
          ),
          GoRoute(
            path: Routes.devices,
            pageBuilder: (context, state) => page(
              state,
              DevicesPage(
                key: ValueKey(state.uri.query),
                groupId: state.uri.queryParameters['group'],
              ),
            ),
          ),
          GoRoute(
            path: Routes.fleetHome,
            pageBuilder: (context, state) => page(state, const FleetPage()),
          ),
          GoRoute(
            path: '/fleet/:sessionId',
            pageBuilder: (context, state) => page(
              state,
              FleetPage(sessionId: state.pathParameters['sessionId']),
            ),
          ),
          GoRoute(
            path: Routes.missions,
            pageBuilder: (context, state) => page(state, const MissionsPage()),
          ),
          GoRoute(
            path: '/alerts/:id',
            pageBuilder: (context, state) {
              final id = state.pathParameters['id']!;
              // 移动端是告警详情；桌面宽度下显示告警中心并选中该告警。
              final mobile = LayoutSize.ofContext(context).isMobile;
              return page(
                state,
                mobile
                    ? AlertDetailPage(alertId: id)
                    : AlertsPage(selectId: id),
              );
            },
          ),
          GoRoute(
            path: Routes.alerts,
            pageBuilder: (context, state) => page(state, const AlertsPage()),
          ),
          GoRoute(
            path: '/recordings/:id',
            pageBuilder: (context, state) {
              final t = int.tryParse(state.uri.queryParameters['t'] ?? '');
              return page(
                state,
                ReplayPage(
                  // 换录制或时间点时重新开始播放状态。
                  key: ValueKey(state.uri.toString()),
                  recordingId: state.pathParameters['id'],
                  startAt: t == null ? null : Duration(seconds: t),
                ),
              );
            },
          ),
          GoRoute(
            path: Routes.recordings,
            pageBuilder: (context, state) => page(state, const ReplayPage()),
          ),
          placeholder(
            '/maintenance',
            title: '设备运维',
            icon: AppIcons.maintenance,
            design: 'Maintenance.dc.html',
            phase: 5,
          ),
          GoRoute(
            path: Routes.safety,
            pageBuilder: (context, state) => page(state, const SafetyPage()),
          ),
          GoRoute(
            path: Routes.leases,
            pageBuilder: (context, state) => page(state, const LeasesPage()),
          ),
          placeholder(
            '/members',
            title: '成员与权限',
            icon: AppIcons.members,
            design: 'Roles.dc.html',
            phase: 6,
          ),
          placeholder(
            '/agent',
            title: '智能体与对讲',
            mobileTitle: '智能体',
            icon: AppIcons.agent,
            design: 'Agent.dc.html · MobileAgent.dc.html',
            phase: 6,
          ),
          GoRoute(
            path: Routes.settings,
            pageBuilder: (context, state) => page(state, const SettingsPage()),
          ),
          GoRoute(
            path: Routes.me,
            pageBuilder: (context, state) => page(state, const MePage()),
          ),
          GoRoute(
            path: Routes.gallery,
            pageBuilder: (context, state) => page(state, const GalleryPage()),
          ),
        ],
      ),
    ],
  );
}
