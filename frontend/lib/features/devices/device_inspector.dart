import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'device_widgets.dart';

/// 设备详情检查器（Main.dc.html 右栏）。
class DeviceInspector extends ConsumerWidget {
  const DeviceInspector({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = ref.watch(deviceProvider(deviceId));
    if (d == null) return const SizedBox.shrink();
    final groups = ref.watch(deviceGroupsProvider).value ?? const [];
    final group =
        groups.where((g) => g.id == d.groupId).firstOrNull?.name ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头图：设备照片 / 3D 模型占位。
        Container(
          height: 150,
          decoration: BoxDecoration(
            color: c.fillSecondary,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Stack(
            children: [
              Center(
                child: DeviceKindIcon(
                  d.kind,
                  size: 110,
                  color: c.decorativeGray,
                  strokeWidth: 0.9,
                ),
              ),
              Positioned(
                left: AppSpacing.x3,
                top: AppSpacing.x3,
                child: StatusPill(
                  tone: toneOf(d.status),
                  label: d.status.label,
                  onSurface: true,
                ),
              ),
              Positioned(
                right: AppSpacing.x3,
                bottom: AppSpacing.x3,
                child: Text(
                  '[设备照片 / 3D 模型]',
                  style: t.caption.copyWith(color: c.secondaryLabel),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.x4),
        Semantics(
          header: true,
          child: Text(d.name, style: t.detailTitle.copyWith(color: c.label)),
        ),
        const SizedBox(height: AppSpacing.half),
        Text(
          '${d.code} · ${d.model} · $group',
          style: t.body.copyWith(fontSize: 12.5, color: c.secondaryLabel),
        ),
        const SizedBox(height: AppSpacing.x4),
        DeviceActions(device: d),
        const SizedBox(height: AppSpacing.x4),
        _People(device: d),
        const SizedBox(height: AppSpacing.x4),
        GroupedList(
          header: '设备信息',
          children: [
            for (final (k, v) in deviceInfoRows(d))
              GroupedListRow(title: k, value: v),
          ],
        ),
        const SizedBox(height: AppSpacing.x4),
        DeviceEvents(deviceId: d.id),
      ],
    );
  }
}

List<(String, String)> deviceInfoRows(Device d) => [
  ('序列号', d.sn),
  ('固件版本', d.firmware),
  ('IP 地址', d.ip),
  ('链路延迟', d.latencyMs == null ? '—' : '${d.latencyMs} ms'),
  (
    '电机最高温度',
    d.maxMotorTemp == null || !d.status.isOnline ? '—' : '${d.maxMotorTemp} °C',
  ),
  ('本次运行', d.status.isOnline ? formatUptime(d.uptime) : '—'),
];

/// 接管控制 / 加入联调 / 传感器（54 高的三格操作）。
class DeviceActions extends ConsumerWidget {
  const DeviceActions({super.key, required this.device, this.mobile = false});

  final Device device;
  final bool mobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final session = ref.watch(fleetSessionsProvider).value?.firstOrNull?.id;
    final online = device.status.isOnline;

    Widget tile(
      String label,
      AppIcons icon,
      VoidCallback? onTap, {
      bool primary = false,
    }) => Expanded(
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        focusRadius: mobile ? AppRadius.tile : AppRadius.group,
        builder: (context, st) {
          final base = primary
              ? c.accentFill
              : (mobile ? c.surface : c.fillSecondary);
          final fg = primary ? c.onAccent : c.label;
          return AnimatedOpacity(
            duration: AppMotion.highlight,
            opacity: st.enabled ? 1 : 0.45,
            child: AnimatedContainer(
              duration: AppMotion.fade(pressed: st.pressed),
              curve: AppMotion.highlightCurve,
              height: mobile ? 64 : 54,
              decoration: BoxDecoration(
                color: st.pressed
                    ? Color.lerp(base, c.stateOverlay, 0.12)
                    : base,
                borderRadius: BorderRadius.circular(
                  mobile ? AppRadius.tile : AppRadius.group,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppIcon(icon, size: 18, color: fg),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    label,
                    style:
                        (mobile
                                ? context.type.mobileFootnote
                                : context.type.subhead)
                            .copyWith(color: fg, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    return Row(
      children: [
        tile(
          mobile ? '操控' : '接管控制',
          AppIcons.control,
          online
              ? () => context.push(Routes.control(device.id), extra: _push)
              : null,
          primary: true,
        ),
        SizedBox(width: mobile ? AppSpacing.x3 : AppSpacing.x2),
        tile(
          '加入联调',
          AppIcons.fleet,
          online && session != null
              ? () => context.go(Routes.fleet(session))
              : null,
        ),
        SizedBox(width: mobile ? AppSpacing.x3 : AppSpacing.x2),
        tile(
          '传感器',
          AppIcons.sensors,
          online
              ? () => context.push(Routes.sensors(device.id), extra: _push)
              : null,
        ),
      ],
    );
  }
}

// 从设备详情进入操控 / 传感器是层级推入（§13）。
const _push = NavIntent.push;

class _People extends ConsumerWidget {
  const _People({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final userId = ref.watch(deviceUserIdProvider(device.id));
    final owner = ref.watch(memberNameProvider(device.ownerId)) ?? '—';
    final user = ref.watch(memberNameProvider(userId));
    return GroupedList(
      header: '人员与权限',
      children: [
        GroupedListRow(
          leading: MemberAvatar(device.ownerId, size: 28),
          title: owner,
          titleWeight: FontWeight.w500,
          subtitle: '管理者 · 可分配使用权、修改配置',
          trailing: const Tag(label: 'Owner'),
        ),
        GroupedListRow(
          leading: MemberAvatar(userId, size: 28),
          title: user ?? '—',
          titleWeight: FontWeight.w500,
          subtitle: user == null ? '当前无人使用 · 可申请控制权' : '使用者 · 当前持有控制权',
          trailing: user == null
              ? null
              : AppIcon(
                  AppIcons.lock,
                  size: 14,
                  strokeWidth: 2.2,
                  color: c.secondaryLabel,
                ),
        ),
        GroupedListRow(title: '授权使用者', value: '3 人', onTap: () {}),
      ],
    );
  }
}

/// 最近事件（圆点 + 文字 + 相对时间）。
class DeviceEvents extends ConsumerWidget {
  const DeviceEvents({super.key, required this.deviceId, this.limit = 3});

  final String deviceId;
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final events = ref.watch(deviceEventsProvider(deviceId)).value ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.x1,
            0,
            AppSpacing.x1,
            AppSpacing.x2,
          ),
          child: Semantics(
            header: true,
            child: Text(
              '最近事件',
              style: t.subheadStrong.copyWith(color: c.secondaryLabel),
            ),
          ),
        ),
        if (events.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x1),
            child: Text(
              '暂无事件',
              style: t.footnote.copyWith(color: c.secondaryLabel),
            ),
          ),
        for (final e in events.take(limit))
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x1,
              0,
              AppSpacing.x1,
              AppSpacing.x3,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    top: AppSpacing.x1 + AppSpacing.half,
                  ),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: eventDot(context, e.tone),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.text, style: t.body.copyWith(color: c.label)),
                      const SizedBox(height: AppSpacing.half),
                      Text(
                        relativeTime(e.at),
                        style: t.footnote.copyWith(color: c.secondaryLabel),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
