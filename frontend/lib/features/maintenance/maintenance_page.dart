import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import 'maintenance_widgets.dart';

/// 设备运维（Maintenance.dc.html）：批量固件升级、电池健康、远程终端、日志。
class MaintenancePage extends ConsumerWidget {
  const MaintenancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firmware = ref.watch(firmwareProvider).value ?? const [];
    final battery = ref.watch(batteryHealthProvider).value ?? const [];
    final window = ref.watch(maintenanceWindowProvider).value;
    final ui = ref.watch(maintenanceUiProvider);
    bool online(String id) =>
        ref.watch(deviceProvider(id))?.status.isOnline ?? false;

    final upgradable = firmware
        .where((f) => f.upgradable && online(f.deviceId))
        .length;
    final replace = battery.where(needsReplacement).length;
    final subtitle = [
      '$upgradable 台可升级',
      if (replace > 0) '$replace 台建议更换电池',
      if (window != null) '维护窗口 每天 ${window.label}',
    ].join(' · ');

    Future<void> export() async {
      final ids = ui.picked.isEmpty
          ? [for (final f in firmware) f.deviceId]
          : ui.picked.toList();
      final name = await ref
          .read(maintenanceRepositoryProvider)
          .exportDiagnostics(ids);
      ref
          .read(maintenanceUiProvider.notifier)
          .notify(BannerKind.info, '正在打包 ${ids.length} 台设备的日志与配置：$name');
    }

    final notice = Presence(
      child: ui.notice == null
          ? null
          : Padding(
              key: ValueKey(ui.notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
            ),
    );

    return AppPage(
      title: '设备运维',
      mobileTitle: '运维',
      subtitle: subtitle,
      actions: [
        SecondaryButton(
          label: '维护窗口设置',
          onPressed: () => showWindowDialog(context, ref),
        ),
        SecondaryButton(label: '导出诊断包', onPressed: export),
      ],
      mobileActions: [
        AppMenu<int>(
          options: const [MenuOption(0, '维护窗口设置'), MenuOption(1, '导出诊断包')],
          onSelected: (v) => v == 0 ? showWindowDialog(context, ref) : export(),
          anchor: (context, toggle) => AppIconButton(
            icon: AppIcons.more,
            label: '更多操作',
            style: IconButtonStyle.circle,
            onPressed: toggle,
          ),
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            notice,
            FlexColumns(
              mainMin: 560,
              trailingWidth: 320,
              main: const FirmwareCard(),
              trailing: const BatteryCard(),
            ),
            const SizedBox(height: AppSpacing.x4),
            FlexColumns(
              mainMin: 480,
              // 设计稿 360；中文字体下标题与级别筛选并排需要 400。
              trailingWidth: 400,
              main: const TerminalCard(),
              trailing: const DeviceLogCard(),
            ),
          ],
        ),
      ],
    );
  }
}
