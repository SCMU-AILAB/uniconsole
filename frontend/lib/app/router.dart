import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../core/layout/app_route_page.dart';
import '../core/widgets/widgets.dart';
import '../features/common/placeholder_page.dart';
import '../features/devices/devices_page.dart';
import '../features/gallery/gallery_page.dart';
import '../features/me/me_page.dart';
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
          GoRoute(
            path: Routes.devices,
            pageBuilder: (context, state) => page(
              state,
              DevicesPage(
                key: ValueKey(state.uri.query),
                groupId: state.uri.queryParameters['group'],
              ),
            ),
            routes: [
              placeholder(
                ':id',
                title: '设备详情',
                icon: AppIcons.dog,
                design: 'MobileDevice.dc.html',
                phase: 3,
                routes: [
                  placeholder(
                    'control',
                    title: '单机操控',
                    mobileTitle: '操控',
                    icon: AppIcons.control,
                    design: 'Control.dc.html · MobileControl.dc.html',
                    phase: 3,
                  ),
                  placeholder(
                    'sensors',
                    title: '感知中心',
                    icon: AppIcons.sensors,
                    design: 'Sensors.dc.html',
                    phase: 3,
                  ),
                ],
              ),
            ],
          ),
          placeholder(
            '/fleet/:sessionId',
            title: '多机联调',
            icon: AppIcons.fleet,
            design: 'Fleet.dc.html',
            phase: 4,
          ),
          placeholder(
            '/missions',
            title: '地图与任务',
            icon: AppIcons.missions,
            design: 'Missions.dc.html',
            phase: 5,
            inspector: '点位详情',
          ),
          placeholder(
            '/alerts',
            title: '告警中心',
            mobileTitle: '告警',
            icon: AppIcons.alerts,
            design: 'Alerts.dc.html · MobileAlerts.dc.html',
            phase: 5,
            routes: [
              placeholder(
                ':id',
                title: '告警详情',
                icon: AppIcons.alerts,
                design: 'MobileAlerts.dc.html',
                phase: 5,
              ),
            ],
          ),
          placeholder(
            '/recordings',
            title: '录制与回放',
            icon: AppIcons.replay,
            design: 'Replay.dc.html',
            phase: 5,
            routes: [
              placeholder(
                ':id',
                title: '录制回放',
                icon: AppIcons.replay,
                design: 'Replay.dc.html',
                phase: 5,
              ),
            ],
          ),
          placeholder(
            '/maintenance',
            title: '设备运维',
            icon: AppIcons.maintenance,
            design: 'Maintenance.dc.html',
            phase: 5,
          ),
          placeholder(
            '/safety',
            title: '安全策略',
            icon: AppIcons.safety,
            design: 'Safety.dc.html',
            phase: 4,
          ),
          placeholder(
            '/leases',
            title: '控制权',
            icon: AppIcons.lease,
            design: 'Lease.dc.html',
            phase: 4,
            inspector: '租约详情',
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
