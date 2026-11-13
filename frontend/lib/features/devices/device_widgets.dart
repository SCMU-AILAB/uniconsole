import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 设备状态 → 状态色调（§3.3）。
StatusTone toneOf(DeviceStatus s) => switch (s) {
  DeviceStatus.online || DeviceStatus.charging => StatusTone.online,
  DeviceStatus.busy => StatusTone.busy,
  DeviceStatus.alert => StatusTone.warning,
  DeviceStatus.offline => StatusTone.offline,
};

Color eventDot(BuildContext context, EventTone tone) {
  final s = context.status;
  return switch (tone) {
    EventTone.info => s.busy.dot,
    EventTone.success => s.online.dot,
    EventTone.warning => s.warning.dot,
    EventTone.critical => s.critical.dot,
    EventTone.neutral => context.colors.decorativeGray,
  };
}

/// 「刚刚 / 2 分钟前 / 3 小时前 / 昨天 18:20」。
String relativeTime(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  String two(int v) => v.toString().padLeft(2, '0');
  if (d.inSeconds < 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  final today = DateTime(n.year, n.month, n.day);
  if (t.isAfter(today)) return '${d.inHours} 小时前';
  if (t.isAfter(today.subtract(const Duration(days: 1)))) {
    return '昨天 ${two(t.hour)}:${two(t.minute)}';
  }
  return '${t.month} 月 ${t.day} 日';
}

/// 「3 小时 12 分」「58 分」。
String formatUptime(Duration? d) {
  if (d == null) return '—';
  final h = d.inHours, m = d.inMinutes % 60;
  return h > 0 ? '$h 小时 ${m.toString().padLeft(2, '0')} 分' : '$m 分';
}

/// 「4:18」。
String formatCountdown(Duration d) {
  final s = d.inSeconds.clamp(0, 359999);
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

class DeviceKindIcon extends StatelessWidget {
  const DeviceKindIcon(
    this.kind, {
    super.key,
    this.size = 24,
    this.color,
    this.strokeWidth = 1.6,
  });

  final DeviceKind kind;
  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => AppIcon(
    kind == DeviceKind.dog ? AppIcons.dog : AppIcons.humanoid,
    size: size,
    color: color ?? context.colors.tertiaryLabel,
    strokeWidth: strokeWidth,
  );
}

/// 设备图标方块（38×38，灰底圆角 10），可带状态角标。
class DeviceIconTile extends StatelessWidget {
  const DeviceIconTile({
    super.key,
    required this.device,
    this.size = 38,
    this.showStatus = false,
  });

  final Device device;
  final double size;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.fillSecondary,
              borderRadius: BorderRadius.circular(AppRadius.group),
            ),
            child: DeviceKindIcon(device.kind, size: size * 0.62),
          ),
          if (showStatus)
            Positioned(
              right: 0,
              bottom: 0,
              child: StatusDot(toneOf(device.status), size: 9, ring: c.surface),
            ),
        ],
      ),
    );
  }
}

/// 成员头像：颜色取成员资料，未知成员显示「–」。
class MemberAvatar extends ConsumerWidget {
  const MemberAvatar(this.memberId, {super.key, this.size = 20});

  final String? memberId;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref
        .watch(membersProvider)
        .value
        ?.where((m) => m.id == memberId)
        .firstOrNull;
    return Avatar(
      name: m?.name ?? '—',
      size: size,
      color: m?.color == null ? null : Color(m!.color!),
    );
  }
}

/// 设备当前使用者：持有控制权的成员；联调 / 任务持有时退回设备资料里的使用者。
final deviceUserIdProvider = Provider.family<String?, String>((ref, id) {
  final lease = ref.watch(leaseProvider(id));
  if (lease == null) return null;
  if (lease.holderKind == LeaseHolderKind.user) return lease.holderId;
  if (lease.holderKind == LeaseHolderKind.session) {
    return ref.watch(deviceProvider(id))?.userId;
  }
  return null;
});

/// 设备卡片（Main.dc.html 网格）。
class DeviceCard extends ConsumerWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.selected,
    required this.onTap,
  });

  final Device device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final d = device;
    final off = !d.status.isOnline;
    final userId = ref.watch(deviceUserIdProvider(d.id));
    final owner = ref.watch(memberNameProvider(d.ownerId)) ?? '—';
    final user = ref.watch(memberNameProvider(userId)) ?? '—';

    Widget person(String role, String? id, String name) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MemberAvatar(id, size: 20),
        const SizedBox(width: AppSpacing.x2),
        Text('$role ', style: t.footnote.copyWith(color: c.secondaryLabel)),
        Text(name, style: t.footnote.copyWith(color: c.label)),
      ],
    );

    return AppCard(
      selected: selected,
      onTap: onTap,
      semanticLabel: '${d.name}，${d.status.label}，${d.currentTask}',
      padding: const EdgeInsets.all(AppSpacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeviceIconTile(device: d),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name, style: t.headline.copyWith(color: c.label)),
                    const SizedBox(height: AppSpacing.half),
                    Text(
                      '${d.code} · ${d.model}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.footnote.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              StatusPill(tone: toneOf(d.status), label: d.status.label),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          Text(
            d.currentTask,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.body.copyWith(fontSize: 12.5, color: c.label),
          ),
          const SizedBox(height: AppSpacing.x1),
          Row(
            children: [
              AppIcon(AppIcons.location, size: 11, strokeWidth: 2.2),
              const SizedBox(width: AppSpacing.x1),
              Expanded(
                child: Text(
                  d.location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.footnote.copyWith(color: c.secondaryLabel),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          Row(
            children: [
              Expanded(
                child: ProgressBar(
                  value: off ? 0 : (d.battery ?? 0) / 100,
                  semanticLabel: '电量',
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              SizedBox(
                width: 32,
                child: Text(
                  off || d.battery == null ? '—' : '${d.battery}%',
                  style: t.footnote.copyWith(color: c.tertiaryLabel),
                ),
              ),
              Text(
                d.latencyMs == null ? '—' : '${d.latencyMs} ms',
                style: t.footnote.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          Container(height: 1, color: c.separatorSubtle),
          const SizedBox(height: AppSpacing.x3),
          Wrap(
            spacing: AppSpacing.x4,
            runSpacing: AppSpacing.x1,
            children: [
              person('管理', d.ownerId, owner),
              person('使用', userId, user),
            ],
          ),
        ],
      ),
    );
  }
}
