import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'device_inspector.dart';
import 'device_widgets.dart';

/// 移动端设备详情（MobileDevice.dc.html）。桌面宽度下 /devices/:id 显示设备总览并选中该设备。
class DeviceDetailPage extends ConsumerWidget {
  const DeviceDetailPage({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = ref.watch(deviceProvider(deviceId));
    if (d == null) {
      return const AppPage(
        title: '设备详情',
        largeTitle: false,
        backLabel: '设备',
        children: [EmptyState(title: '找不到该设备')],
      );
    }
    final online = d.status.isOnline;
    final telemetry = online ? ref.watch(telemetryProvider(d.id)).value : null;
    final groups = ref.watch(deviceGroupsProvider).value ?? const [];
    final group =
        groups.where((g) => g.id == d.groupId).firstOrNull?.name ?? '';
    final battery = telemetry?.battery ?? d.battery.toDouble();
    final latency = telemetry?.latencyMs ?? d.latencyMs;

    void openControl() =>
        context.push(Routes.control(d.id), extra: NavIntent.push);
    void openSensors() =>
        context.push(Routes.sensors(d.id), extra: NavIntent.push);

    return AppPage(
      title: d.name,
      largeTitle: false,
      backLabel: '设备',
      gap: AppSpacing.x5,
      mobileActions: [
        AppIconButton(
          icon: AppIcons.more,
          label: '更多',
          size: AppSizes.minTouchTarget,
          onPressed: () {},
        ),
      ],
      children: [
        VideoPanel(
          placeholder: online ? '[实时画面]' : '[设备离线]',
          showCrosshair: false,
          hideBottomRightWhenNarrow: false,
          topLeft: online ? const _LiveChip() : null,
          bottomRight: online
              ? _PillButton(
                  label: '横屏操控',
                  icon: AppIcons.fullscreen,
                  onTap: openControl,
                )
              : null,
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.name,
                    style: t.detailTitle.copyWith(fontSize: 24, color: c.label),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    '${d.code} · ${d.model} · $group',
                    style: t.mobileFootnote.copyWith(color: c.secondaryLabel),
                  ),
                ],
              ),
            ),
            StatusPill(
              tone: toneOf(d.status),
              label: d.status.label,
              large: true,
            ),
          ],
        ),
        DeviceActions(device: d, mobile: true),
        InsetGroupedSection(
          header: '状态',
          children: [
            GroupedListRow(
              title: '电量',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 80,
                    child: ProgressBar(
                      value: online ? battery / 100 : 0,
                      height: 6,
                      semanticLabel: '电量',
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      online ? '${battery.round()}%' : '—',
                      textAlign: TextAlign.right,
                      style: t.mobileBody.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                ],
              ),
            ),
            GroupedListRow(
              title: '链路延迟',
              value: latency == null ? '—' : '$latency ms · 5 GHz Wi-Fi',
            ),
            GroupedListRow(title: '位置', value: d.location),
            GroupedListRow(title: '当前任务', value: d.currentTask),
          ],
        ),
        _MobilePeople(device: d),
        InsetGroupedSection(
          header: '传感器',
          dividerIndent: 36,
          children: [
            for (final (name, value, tone) in _sensorRows(d, telemetry, ref))
              GroupedListRow(
                leading: StatusDot(tone, size: 8),
                title: name,
                value: value,
                onTap: online ? openSensors : null,
              ),
          ],
        ),
        InsetGroupedSection(
          header: '设备信息',
          children: [
            for (final (k, v) in deviceInfoRows(d))
              GroupedListRow(title: k, value: v),
          ],
        ),
      ],
    );
  }

  List<(String, String, StatusTone)> _sensorRows(
    Device d,
    Telemetry? tm,
    WidgetRef ref,
  ) {
    if (!d.status.isOnline) {
      return const [
        ('摄像头', '离线', StatusTone.offline),
        ('激光雷达', '离线', StatusTone.offline),
        ('IMU 姿态', '—', StatusTone.offline),
        ('关节温度', '—', StatusTone.offline),
      ];
    }
    final status = ref.watch(sensorStatusProvider(d.id)).value;
    final maxTemp = tm?.maxJointTemp ?? d.maxMotorTemp?.toDouble();
    final pitch = tm?.pitch;
    return [
      (
        '摄像头',
        status == null ? '—' : '${status.liveCameras} 路在线',
        StatusTone.online,
      ),
      ('激光雷达', '10 Hz', StatusTone.online),
      (
        'IMU 姿态',
        pitch == null
            ? '—'
            : '俯仰 ${pitch.toStringAsFixed(1).replaceFirst('-', '−')}°',
        StatusTone.online,
      ),
      (
        '关节温度',
        maxTemp == null ? '—' : '最高 ${maxTemp.round()} °C',
        maxTemp == null
            ? StatusTone.offline
            : maxTemp >= 60
            ? StatusTone.critical
            : maxTemp >= 50
            ? StatusTone.warning
            : StatusTone.online,
      ),
    ];
  }
}

class _MobilePeople extends ConsumerWidget {
  const _MobilePeople({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final me = ref.watch(currentUserProvider).value;
    final lease = ref.watch(leaseProvider(device.id));
    final userId = ref.watch(deviceUserIdProvider(device.id));
    final owner = ref.watch(memberNameProvider(device.ownerId)) ?? '—';
    final user = ref.watch(memberNameProvider(userId));
    final mine = ref.watch(holdsLeaseProvider(device.id));
    final held = lease?.acquiredAt == null
        ? null
        : DateTime.now().difference(lease!.acquiredAt!);

    return InsetGroupedSection(
      header: '人员与权限',
      dividerIndent: 60,
      children: [
        GroupedListRow(
          leading: MemberAvatar(device.ownerId, size: 32),
          title: owner,
          subtitle: '管理者',
          trailing: const Tag(label: 'Owner', large: true),
        ),
        GroupedListRow(
          leading: MemberAvatar(userId, size: 32),
          title: user == null ? '无人使用' : (userId == me?.id ? '$user（你）' : user),
          subtitle: user == null
              ? '可申请控制权'
              : held == null
              ? '使用者 · 持有控制权'
              : '使用者 · 持有控制权 ${held.inMinutes} 分钟',
        ),
        GroupedListRow(title: '授权使用者', value: '3 人', onTap: () {}),
        if (mine)
          Pressable(
            onTap: () {},
            semanticLabel: '转移控制权',
            focusRadius: 0,
            builder: (context, st) => Container(
              constraints: const BoxConstraints(
                minHeight: AppSizes.minTouchTarget,
              ),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
              alignment: Alignment.centerLeft,
              color: st.pressed ? c.label.withValues(alpha: 0.08) : null,
              child: Text(
                '转移控制权…',
                style: context.type.mobileBody.copyWith(color: c.link),
              ),
            ),
          ),
      ],
    );
  }
}

class _LiveChip extends StatelessWidget {
  const _LiveChip();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x2,
        vertical: AppSpacing.x1,
      ),
      decoration: BoxDecoration(
        color: c.hudOverlay,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c.live, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.x1),
          Text(
            'LIVE · 前置',
            style: context.type.caption.copyWith(
              color: c.hudText,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 视频上的白色胶囊按钮（「横屏操控」）。
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final AppIcons icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      focusRadius: AppSpacing.x4,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
        decoration: BoxDecoration(
          color: c.hudText.withValues(alpha: st.pressed ? 0.75 : 0.92),
          borderRadius: BorderRadius.circular(AppSpacing.x4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(icon, size: 15, color: c.videoBackground),
            const SizedBox(width: AppSpacing.x2),
            Text(
              label,
              style: context.type.mobileFootnote.copyWith(
                color: c.videoBackground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
