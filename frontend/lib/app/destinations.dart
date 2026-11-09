import 'package:flutter/foundation.dart';

import '../core/widgets/widgets.dart';

/// 侧边栏 / 标签栏的导航目标与路由（HANDOFF.md §2）。
abstract final class Routes {
  static const devices = '/devices';
  static String device(String id) => '/devices/$id';
  static String control(String deviceId) => '/devices/$deviceId/control';
  static String sensors(String deviceId) => '/devices/$deviceId/sensors';
  static const fleetHome = '/fleet';
  static String fleet(String sessionId) => '/fleet/$sessionId';
  static const missions = '/missions';
  static const alerts = '/alerts';
  static String alert(String id) => '/alerts/$id';
  static const recordings = '/recordings';
  static String recording(String id) => '/recordings/$id';
  static const maintenance = '/maintenance';
  static const safety = '/safety';
  static const leases = '/leases';
  static const members = '/members';
  static const agent = '/agent';
  static const settings = '/settings';
  static const me = '/me';
  static const gallery = '/gallery';
  static const login = '/login';
  static const register = '/register';
  static String invite(String token) => '/invite/$token';
}

class NavEntry {
  const NavEntry(this.id, this.label, this.icon);

  final String id;
  final String label;
  final AppIcons icon;
}

/// 侧边栏三组固定入口（Main.dc.html）。
const workbench = [
  NavEntry('devices', '设备总览', AppIcons.devices),
  NavEntry('control', '单机操控', AppIcons.control),
  NavEntry('fleet', '多机联调', AppIcons.fleet),
  NavEntry('sensors', '感知中心', AppIcons.sensors),
];
const operations = [
  NavEntry('missions', '地图与任务', AppIcons.missions),
  NavEntry('alerts', '告警中心', AppIcons.alerts),
  NavEntry('replay', '录制与回放', AppIcons.replay),
  NavEntry('maintenance', '设备运维', AppIcons.maintenance),
];
const management = [
  NavEntry('safety', '安全策略', AppIcons.safety),
  NavEntry('leases', '控制权', AppIcons.lease),
  NavEntry('members', '成员与权限', AppIcons.members),
  NavEntry('agent', '智能体与对讲', AppIcons.agent),
  NavEntry('settings', '设置', AppIcons.settings),
];

/// 移动端在「我的」页里列出的、标签栏之外的入口。
const mobileMoreEntries = [
  NavEntry('fleet', '多机联调', AppIcons.fleet),
  NavEntry('sensors', '感知中心', AppIcons.sensors),
  NavEntry('missions', '地图与任务', AppIcons.missions),
  NavEntry('replay', '录制与回放', AppIcons.replay),
  NavEntry('maintenance', '设备运维', AppIcons.maintenance),
  NavEntry('safety', '安全策略', AppIcons.safety),
  NavEntry('leases', '控制权', AppIcons.lease),
  NavEntry('members', '成员与权限', AppIcons.members),
  NavEntry('settings', '设置', AppIcons.settings),
];

/// 组件预览只在 debug 版本出现。
const showDevEntries = kDebugMode;

/// 由当前地址得到侧边栏选中项。设备分组选中项为 `group:<id>`。
String? sidebarIdFor(Uri uri) {
  final p = uri.path;
  final seg = uri.pathSegments;
  if (seg.length >= 3 && seg[0] == 'devices') {
    if (seg[2] == 'control') return 'control';
    if (seg[2] == 'sensors') return 'sensors';
  }
  if (p.startsWith('/devices')) {
    final g = uri.queryParameters['group'];
    return g == null ? 'devices' : 'group:$g';
  }
  for (final (prefix, id) in const [
    ('/fleet', 'fleet'),
    ('/missions', 'missions'),
    ('/alerts', 'alerts'),
    ('/recordings', 'replay'),
    ('/maintenance', 'maintenance'),
    ('/safety', 'safety'),
    ('/leases', 'leases'),
    ('/members', 'members'),
    ('/agent', 'agent'),
    ('/settings', 'settings'),
    ('/gallery', 'gallery'),
  ]) {
    if (p.startsWith(prefix)) return id;
  }
  return null;
}

/// 由当前地址得到移动端标签栏选中项（设备 / 操控 / 智能体 / 告警 / 我的）。
String tabIdFor(Uri uri) {
  final seg = uri.pathSegments;
  if (seg.length >= 3 && seg[0] == 'devices' && seg[2] == 'control') {
    return 'control';
  }
  if (uri.path.startsWith('/devices')) return 'devices';
  if (uri.path.startsWith('/agent')) return 'agent';
  if (uri.path.startsWith('/alerts')) return 'alerts';
  return 'me';
}
