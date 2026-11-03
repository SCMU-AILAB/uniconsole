import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 电池满充容量低于该值建议更换。
const batteryThreshold = 80.0;

/// 已低于阈值，或按近 6 个月的趋势 8 周内会低于阈值。
bool needsReplacement(BatteryHealth b) {
  final w = b.weeksUntil(batteryThreshold);
  return b.health < batteryThreshold || (w != null && w <= 8);
}

/// 终端会话：设备 + 类型（ssh / journalctl）+ 输出。
class TermSession {
  const TermSession(this.deviceId, this.kind, [this.lines = const []]);

  final String deviceId;
  final String kind;
  final List<TerminalLine> lines;

  TermSession add(List<TerminalLine> more) =>
      TermSession(deviceId, kind, [...lines, ...more]);

  TermSession clear() => TermSession(deviceId, kind);
}

class MaintenanceUiState {
  const MaintenanceUiState({
    this.picked = const {'go2-02', 'g1-01'},
    this.level,
    this.logDevice,
    this.sessions = const [
      TermSession('go2-01', 'ssh'),
      TermSession('go2-03', 'journalctl'),
    ],
    this.tab = 0,
    this.notice,
  });

  /// 勾选的设备（设计稿默认 Bravo、Echo；Foxtrot 正在升级，锁定为已选）。
  final Set<String> picked;

  /// 日志级别筛选，null 为全部。
  final LogSeverity? level;

  /// 只看某台设备的日志（行内「查看日志」）。
  final String? logDevice;
  final List<TermSession> sessions;
  final int tab;
  final (BannerKind, String)? notice;

  MaintenanceUiState copyWith({
    Set<String>? picked,
    LogSeverity? level,
    bool clearLevel = false,
    String? logDevice,
    bool clearLogDevice = false,
    List<TermSession>? sessions,
    int? tab,
    (BannerKind, String)? notice,
  }) => MaintenanceUiState(
    picked: picked ?? this.picked,
    level: clearLevel ? null : level ?? this.level,
    logDevice: clearLogDevice ? null : logDevice ?? this.logDevice,
    sessions: sessions ?? this.sessions,
    tab: tab ?? this.tab,
    notice: notice ?? this.notice,
  );
}

class MaintenanceUi extends Notifier<MaintenanceUiState> {
  @override
  MaintenanceUiState build() {
    // 两个初始会话的开场输出（设计稿终端里的内容）。
    Future.microtask(() async {
      await _run(0, 'systemctl status uniconsole-agent');
      await _run(0, 'df -h /data');
      await _run(1, 'journalctl -u uniconsole-agent -n 5');
    });
    return const MaintenanceUiState();
  }

  void toggle(String id) {
    final p = {...state.picked};
    p.contains(id) ? p.remove(id) : p.add(id);
    state = state.copyWith(picked: p);
  }

  void clearPicked() => state = state.copyWith(picked: const {});

  void level(LogSeverity? l) => state = l == null
      ? state.copyWith(clearLevel: true)
      : state.copyWith(level: l);

  void logDevice(String? id) => state = id == null
      ? state.copyWith(clearLogDevice: true)
      : state.copyWith(logDevice: id);

  void notify(BannerKind kind, String text) =>
      state = state.copyWith(notice: (kind, text));

  void tab(int i) => state = state.copyWith(tab: i);

  /// 打开某台设备的 ssh 会话（已有则切换过去）。
  void open(String deviceId) {
    final i = state.sessions.indexWhere(
      (s) => s.deviceId == deviceId && s.kind == 'ssh',
    );
    if (i >= 0) {
      tab(i);
      return;
    }
    state = state.copyWith(
      sessions: [...state.sessions, TermSession(deviceId, 'ssh')],
      tab: state.sessions.length,
    );
  }

  Future<void> run(String command) => _run(state.tab, command);

  Future<void> _run(int i, String command) async {
    if (i >= state.sessions.length) return;
    final s = state.sessions[i];
    final cmd = command.trim();
    if (cmd == 'clear') {
      _replace(i, s.clear());
      return;
    }
    final prompt = 'unitree@${s.deviceId}:~';
    _replace(i, s.add([TerminalLine(cmd, prompt: prompt)]));
    final out = await ref
        .read(maintenanceRepositoryProvider)
        .run(s.deviceId, cmd);
    _replace(i, state.sessions[i].add(out));
  }

  void _replace(int i, TermSession s) => state = state.copyWith(
    sessions: [for (final (j, x) in state.sessions.indexed) j == i ? s : x],
  );
}

final maintenanceUiProvider =
    NotifierProvider.autoDispose<MaintenanceUi, MaintenanceUiState>(
      MaintenanceUi.new,
    );

String _shortModel(String m) => m.replaceFirst('Unitree ', '');

/// 维护窗口设置：每天的开始时刻与时长（固件升级、重启只在窗口内进行）。
Future<void> showWindowDialog(BuildContext context, WidgetRef ref) async {
  final current =
      ref.read(maintenanceWindowProvider).value ??
      const MaintenanceWindow(Duration(hours: 2), Duration(hours: 4));
  final next = await showAppDialog<MaintenanceWindow?>(
    context: context,
    builder: (context) => _WindowDialog(initial: current),
  );
  if (next == null) return;
  await ref.read(maintenanceRepositoryProvider).setWindow(next);
  ref
      .read(maintenanceUiProvider.notifier)
      .notify(BannerKind.success, '维护窗口已改为每天 ${next.label}');
}

class _WindowDialog extends StatefulWidget {
  const _WindowDialog({required this.initial});

  final MaintenanceWindow initial;

  @override
  State<_WindowDialog> createState() => _WindowDialogState();
}

class _WindowDialogState extends State<_WindowDialog> {
  late var _start = widget.initial.start.inHours;
  late var _hours = (widget.initial.end - widget.initial.start).inHours;

  MaintenanceWindow get _window => MaintenanceWindow(
    Duration(hours: _start),
    Duration(hours: _start + _hours),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    Widget row(String label, Widget menu) => Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: t.body.copyWith(color: c.label)),
          ),
          menu,
        ],
      ),
    );
    Widget menu(
      int value,
      List<(int, String)> options,
      ValueChanged<int> set,
    ) => AppMenu<int>(
      options: [for (final (v, l) in options) MenuOption(v, l)],
      selected: value,
      onSelected: (v) => setState(() => set(v)),
      anchor: (context, toggle) => SecondaryButton(
        label: options.firstWhere((o) => o.$1 == value).$2,
        trailingIcon: AppIcons.chevronDown,
        onPressed: toggle,
      ),
    );
    return AppAlert<MaintenanceWindow?>(
      title: '维护窗口',
      message: '固件升级、计划重启只在窗口内进行；窗口内不排巡检任务。',
      content: Column(
        children: [
          row(
            '开始',
            menu(_start, [
              for (final h in const [0, 1, 2, 3, 22, 23])
                (h, '${h.toString().padLeft(2, '0')}:00'),
            ], (v) => _start = v),
          ),
          row(
            '时长',
            menu(_hours, [
              for (final h in const [1, 2, 3, 4]) (h, '$h 小时'),
            ], (v) => _hours = v),
          ),
          row(
            '结果',
            Text(
              '每天 ${_window.label}',
              style: t.body.copyWith(color: c.secondaryLabel),
            ),
          ),
        ],
      ),
      actions: [
        const AlertAction<MaintenanceWindow?>(
          label: '取消',
          value: null,
          kind: AlertActionKind.cancel,
        ),
        AlertAction<MaintenanceWindow?>(label: '保存', value: _window),
      ],
    );
  }
}

// ---- 固件与软件 ----

class FirmwareCard extends ConsumerWidget {
  const FirmwareCard({super.key});

  static const _flex = [14, 10, 10, 16];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final firmware =
        ref.watch(firmwareProvider).value ?? const <FirmwareStatus>[];
    final release = ref.watch(firmwareReleaseProvider).value;
    final window = ref.watch(maintenanceWindowProvider).value;
    final ui = ref.watch(maintenanceUiProvider);
    final uiNotifier = ref.read(maintenanceUiProvider.notifier);
    final repo = ref.read(maintenanceRepositoryProvider);

    bool locked(FirmwareStatus f) =>
        f.state == FirmwareState.latest ||
        f.state == FirmwareState.upgrading ||
        f.state == FirmwareState.queued;
    final selected = [
      for (final f in firmware)
        if (ui.picked.contains(f.deviceId) && !locked(f)) f.deviceId,
    ];

    (String, Color) status(FirmwareStatus f) => switch (f.state) {
      FirmwareState.available => ('可升级', s.busy.fg),
      FirmwareState.waitingTask => ('任务中 · 将在任务结束后升级', c.secondaryLabel),
      FirmwareState.waitingOnline => ('离线 · 上线后自动升级', c.secondaryLabel),
      FirmwareState.scheduled => (
        '已排入维护窗口 · ${window?.startLabel ?? ''} 开始',
        s.busy.fg,
      ),
      FirmwareState.queued => ('排队中 · 等待灰度设备自检通过', c.secondaryLabel),
      FirmwareState.upgrading => (
        '正在升级 · 写入分区 ${(f.progress * 100).round()}%',
        s.busy.fg,
      ),
      FirmwareState.failed => (
        '上次升级失败${f.error == null ? '' : ' · ${f.error}'}',
        s.critical.fg,
      ),
      FirmwareState.latest => ('已是最新', s.online.fg),
    };

    Future<void> upgrade() async {
      final names = [
        for (final id in selected) ref.read(deviceProvider(id))?.name ?? id,
      ];
      final ok = await confirmAction(
        context,
        title: '立即升级 ${selected.length} 台设备？',
        message:
            '${names.join('、')}。先升级 1 台，自检通过后其余并行；任务中的设备会在任务结束后升级。升级在备用分区进行，失败自动回滚。',
        confirmLabel: '开始升级',
      );
      if (!ok) return;
      await repo.upgrade(selected);
      uiNotifier.clearPicked();
      uiNotifier.notify(BannerKind.success, '已开始灰度升级：${names.join('、')}');
    }

    Future<void> schedule() async {
      await repo.schedule(selected);
      uiNotifier.clearPicked();
      uiNotifier.notify(
        BannerKind.success,
        '已加入维护窗口，将在每天 ${window?.label ?? ''} 升级',
      );
    }

    Widget grid(List<Widget> cells) => Row(
      children: [
        SizedBox(width: 28, child: cells[0]),
        for (var i = 1; i < 5; i++) ...[
          const SizedBox(width: AppSpacing.x2),
          Expanded(flex: _flex[i - 1], child: cells[i]),
        ],
        const SizedBox(width: AppSpacing.x2),
        SizedBox(width: 112, child: cells[5]),
      ],
    );
    final header = t.footnote.copyWith(color: c.secondaryLabel);
    final mono = t.monoLarge;

    return AppCard(
      semanticLabel: '固件升级',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x1,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Semantics(
                header: true,
                child: Text(
                  '固件与软件',
                  style: t.cardTitle.copyWith(color: c.label),
                ),
              ),
              if (release != null)
                Wrap(
                  spacing: AppSpacing.x2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '最新：机身固件 ${release.latest['Unitree Go2 EDU'] ?? ''} · UniConsole Agent ${release.agentVersion}',
                      style: t.subhead.copyWith(color: c.secondaryLabel),
                    ),
                    Pressable(
                      onTap: () => showAppDialog<void>(
                        context: context,
                        builder: (context) => AppAlert<void>(
                          title: '发行说明',
                          content: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final n in release.notes)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: AppSpacing.x2,
                                  ),
                                  child: Text(
                                    n,
                                    style: t.body.copyWith(color: c.label),
                                  ),
                                ),
                            ],
                          ),
                          actions: const [
                            AlertAction(label: '完成', value: null),
                          ],
                        ),
                      ),
                      semanticLabel: '发行说明',
                      focusRadius: AppRadius.xs,
                      builder: (context, st) => Text(
                        '发行说明',
                        style: t.subhead.copyWith(color: c.link),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          if (LayoutSize.ofContext(context).isMobile)
            // 手机：列表代替表格（与控制权页一致），状态写在副标题。
            Column(
              children: [
                for (final f in firmware)
                  Builder(
                    builder: (context) {
                      final d = ref.watch(deviceProvider(f.deviceId));
                      final (label, color) = status(f);
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.x2,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: c.separatorSubtle),
                          ),
                        ),
                        child: Row(
                          children: [
                            AppCheckbox(
                              value:
                                  ui.picked.contains(f.deviceId) ||
                                  f.state == FirmwareState.upgrading ||
                                  f.state == FirmwareState.queued,
                              semanticLabel: '选择 ${d?.name ?? f.deviceId}',
                              onChanged: locked(f)
                                  ? null
                                  : (_) => uiNotifier.toggle(f.deviceId),
                            ),
                            const SizedBox(width: AppSpacing.x3),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${d?.name ?? f.deviceId} · ${f.current} → ${f.target}',
                                    style: t.mobileBody.copyWith(
                                      color: c.label,
                                    ),
                                  ),
                                  Text(
                                    label,
                                    style: t.mobileFootnote.copyWith(
                                      color: color,
                                    ),
                                  ),
                                  if (f.state == FirmwareState.upgrading) ...[
                                    const SizedBox(height: AppSpacing.x1),
                                    ProgressBar(
                                      value: f.progress,
                                      height: 4,
                                      battery: false,
                                      semanticLabel: '${d?.name ?? ''} 升级进度',
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.x2),
                            _RowActions(firmware: f, device: d),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            )
          else
            LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth < 640 ? 640.0 : box.maxWidth;
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: w,
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.x1,
                            vertical: AppSpacing.x2,
                          ),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: c.separator),
                            ),
                          ),
                          child: grid([
                            const SizedBox(),
                            Text('设备', style: header),
                            Text('当前版本', style: header),
                            Text('目标版本', style: header),
                            Text('状态', style: header),
                            Text(
                              '操作',
                              style: header,
                              textAlign: TextAlign.right,
                            ),
                          ]),
                        ),
                        for (final f in firmware)
                          Builder(
                            builder: (context) {
                              final d = ref.watch(deviceProvider(f.deviceId));
                              final (label, color) = status(f);
                              final checked =
                                  ui.picked.contains(f.deviceId) ||
                                  f.state == FirmwareState.upgrading ||
                                  f.state == FirmwareState.queued;
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.x1,
                                  vertical: AppSpacing.x2,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: c.separatorSubtle,
                                    ),
                                  ),
                                ),
                                child: grid([
                                  AppCheckbox(
                                    value: checked,
                                    semanticLabel:
                                        '选择 ${d?.name ?? f.deviceId}',
                                    onChanged: locked(f)
                                        ? null
                                        : (_) => uiNotifier.toggle(f.deviceId),
                                  ),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        d?.name ?? f.deviceId,
                                        style: t.bodyMedium.copyWith(
                                          color: c.label,
                                        ),
                                      ),
                                      Text(
                                        _shortModel(d?.model ?? ''),
                                        style: t.caption.copyWith(
                                          color: c.secondaryLabel,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    f.current,
                                    style: mono.copyWith(color: c.label),
                                  ),
                                  Text(
                                    f.target,
                                    style: mono.copyWith(
                                      color: c.secondaryLabel,
                                    ),
                                  ),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        label,
                                        style: t.subheadMedium.copyWith(
                                          color: color,
                                        ),
                                      ),
                                      if (f.state ==
                                          FirmwareState.upgrading) ...[
                                        const SizedBox(height: AppSpacing.x1),
                                        ProgressBar(
                                          value: f.progress,
                                          height: 4,
                                          battery: false,
                                          semanticLabel:
                                              '${d?.name ?? ''} 升级进度',
                                        ),
                                      ],
                                    ],
                                  ),
                                  _RowActions(firmware: f, device: d),
                                ]),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: AppSpacing.x3),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x3,
            ),
            decoration: BoxDecoration(
              color: c.windowBackground,
              borderRadius: BorderRadius.circular(AppRadius.group),
            ),
            child: Wrap(
              spacing: AppSpacing.x3,
              runSpacing: AppSpacing.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Text(
                  '已选 ${selected.length} 台 · 灰度发布：先升级 1 台，自检通过后其余并行',
                  style: t.bodyMedium.copyWith(color: c.label),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SecondaryButton(
                      label: '加入维护窗口',
                      onPressed: selected.isEmpty ? null : schedule,
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    PrimaryButton(
                      label: '立即升级',
                      onPressed: selected.isEmpty ? null : upgrade,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 行内操作：重启 + 「⋯」（查看日志、打开终端、回滚、导出诊断包）。
class _RowActions extends ConsumerWidget {
  const _RowActions({required this.firmware, required this.device});

  final FirmwareStatus firmware;
  final Device? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = device;
    final id = firmware.deviceId;
    final name = d?.name ?? id;
    final online = d?.status.isOnline ?? false;
    final repo = ref.read(maintenanceRepositoryProvider);
    final ui = ref.read(maintenanceUiProvider.notifier);

    Future<void> reboot() async {
      final busy =
          d?.status == DeviceStatus.busy || d?.status == DeviceStatus.alert;
      final ok = await confirmAction(
        context,
        title: '重启 $name？',
        message: busy
            ? '$name 正在执行任务，重启会中断任务并释放控制权，约 1 分钟后重新上线。'
            : '约 1 分钟后重新上线。',
        confirmLabel: '重启',
        destructive: busy,
      );
      if (!ok) return;
      await repo.reboot(id);
      ui.notify(BannerKind.info, '$name 正在重启');
    }

    Future<void> more(int v) async {
      switch (v) {
        case 0:
          ui.logDevice(id);
        case 1:
          ui.open(id);
        case 2:
          final ok = await confirmAction(
            context,
            title: '回滚 $name 的固件？',
            message: '切换回上一个分区的版本，设备会重启。',
            confirmLabel: '回滚',
            destructive: true,
          );
          if (!ok) return;
          await repo.rollback(id);
          ui.notify(BannerKind.info, '$name 已回滚，重启后生效');
        case _:
          final file = await repo.exportDiagnostics([id]);
          ui.notify(BannerKind.info, '正在打包 $name 的诊断信息：$file');
      }
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SecondaryButton(label: '重启', onPressed: online ? reboot : null),
        const SizedBox(width: AppSpacing.x1),
        AppMenu<int>(
          options: [
            const MenuOption(0, '查看日志'),
            if (online) const MenuOption(1, '打开终端'),
            const MenuOption(2, '回滚到上一版本'),
            const MenuOption(3, '导出诊断包'),
          ],
          onSelected: more,
          anchor: (context, toggle) => AppIconButton(
            icon: AppIcons.more,
            label: '$name 更多操作',
            style: IconButtonStyle.filled,
            onPressed: toggle,
          ),
        ),
      ],
    );
  }
}

// ---- 电池健康 ----

class BatteryCard extends ConsumerWidget {
  const BatteryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final list = [
      ...ref.watch(batteryHealthProvider).value ?? const <BatteryHealth>[],
    ]..sort((a, b) => b.health.compareTo(a.health));
    String name(String id) => ref.watch(deviceProvider(id))?.name ?? id;

    // 健康的用中性色，接近阈值的用警告 / 严重色（与设计稿的四条线一致）。
    final neutral = [c.decorativeGray, c.accent];
    var n = 0;
    Color line(BatteryHealth b) => needsReplacement(b)
        ? s.critical.dot
        : b.health < 90
        ? s.warning.dot
        : neutral[n++ % neutral.length];
    final colors = {for (final b in list) b.deviceId: line(b)};
    Color fg(BatteryHealth b) => needsReplacement(b)
        ? s.critical.fg
        : b.health < 90
        ? s.warning.fg
        : s.online.fg;

    final warn = list.where(needsReplacement).toList();

    return AppCard(
      title: '电池健康',
      semanticLabel: '电池健康',
      trailing: Text(
        '满充容量 · 近 6 个月',
        style: t.footnote.copyWith(color: c.secondaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LineChart(
            semanticLabel: '各设备电池满充容量趋势，虚线为 80% 更换线',
            height: 130,
            background: false,
            minY: 60,
            maxY: 100,
            threshold: batteryThreshold,
            series: [
              for (final b in list)
                ChartSeries(values: b.monthly, color: colors[b.deviceId]),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          for (final b in list)
            MergeSemantics(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.separatorSubtle)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 10,
                      height: 3,
                      decoration: BoxDecoration(
                        color: colors[b.deviceId],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: Text(
                        name(b.deviceId),
                        style: t.bodyMedium.copyWith(color: c.label),
                      ),
                    ),
                    Text(
                      '${b.cycles} 次循环',
                      style: t.subhead.copyWith(
                        color: c.secondaryLabel,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${b.health.round()}%',
                        textAlign: TextAlign.right,
                        style: t.cardTitle.copyWith(
                          color: fg(b),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (final b in warn)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x1),
              child: Text(
                b.health < batteryThreshold
                    ? '${name(b.deviceId)} 已低于 ${batteryThreshold.round()}%，建议尽快更换。'
                    : '${name(b.deviceId)} 预计 ${b.weeksUntil(batteryThreshold)!.round()} 周后低于 ${batteryThreshold.round()}%，建议安排更换。',
                style: t.footnote.copyWith(color: s.warning.fg),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- 远程终端 ----

class TerminalCard extends ConsumerStatefulWidget {
  const TerminalCard({super.key});

  @override
  ConsumerState<TerminalCard> createState() => _TerminalCardState();
}

class _TerminalCardState extends ConsumerState<TerminalCard> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(maintenanceUiProvider);
    final notifier = ref.read(maintenanceUiProvider.notifier);
    final tc = context.colors.terminal;
    final t = context.type;
    String name(String id) => ref.watch(deviceProvider(id))?.name ?? id;
    final session = ui.sessions.isEmpty ? null : ui.sessions[ui.tab];
    final style = t.monoLarge.copyWith(height: 1.5, color: tc.cursor);

    return Semantics(
      container: true,
      label: '远程终端',
      child: LogConsole(
        terminal: true,
        semanticLabel: '远程终端输出',
        tabs: [for (final s in ui.sessions) '${name(s.deviceId)} · ${s.kind}'],
        selectedTab: ui.tab,
        onTabSelected: notifier.tab,
        headerNote: '已二次验证 · 操作写入审计日志',
        maxHeight: 260,
        lines: [
          for (final l in session?.lines ?? const <TerminalLine>[])
            l.prompt != null
                ? LogLine.command(l.prompt, l.text)
                : LogLine(
                    l.text,
                    level: switch (l.tone) {
                      TerminalTone.normal => LogLevel.normal,
                      TerminalTone.success => LogLevel.success,
                      TerminalTone.warning => LogLevel.warning,
                      TerminalTone.error => LogLevel.error,
                    },
                  ),
        ],
        inputPrompt: session == null ? null : 'unitree@${session.deviceId}:~',
        input: session == null
            ? null
            : Material(
                type: MaterialType.transparency,
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  style: style,
                  cursorColor: tc.cursor,
                  cursorWidth: 8,
                  cursorHeight: 14,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration.collapsed(
                    hintText: '输入命令，help 查看可用命令',
                    hintStyle: style.copyWith(color: tc.textSecondary),
                  ),
                  onSubmitted: (v) {
                    _input.clear();
                    notifier.run(v);
                    _focus.requestFocus();
                  },
                ),
              ),
      ),
    );
  }
}

// ---- 日志 ----

class DeviceLogCard extends ConsumerWidget {
  const DeviceLogCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final logs =
        ref.watch(deviceLogsProvider).value ?? const <DeviceLogEntry>[];
    final ui = ref.watch(maintenanceUiProvider);
    final notifier = ref.read(maintenanceUiProvider.notifier);
    String name(String id) => ref.watch(deviceProvider(id))?.name ?? id;
    final shown = logs
        .where(
          (e) =>
              (ui.level == null || e.level == ui.level) &&
              (ui.logDevice == null || e.deviceId == ui.logDevice),
        )
        .take(12)
        .toList();

    return AppCard(
      semanticLabel: '设备日志',
      title: ui.logDevice == null ? '日志 · 全部设备' : '日志 · ${name(ui.logDevice!)}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (ui.logDevice != null) ...[
            AppIconButton(
              icon: AppIcons.close,
              label: '显示全部设备',
              onPressed: () => notifier.logDevice(null),
            ),
            const SizedBox(width: AppSpacing.x1),
          ],
          SegmentedControl<LogSeverity?>(
            semanticLabel: '日志级别',
            options: const [
              SegmentOption(null, '全部'),
              SegmentOption(LogSeverity.info, 'INFO'),
              SegmentOption(LogSeverity.warn, 'WARN'),
              SegmentOption(LogSeverity.error, 'ERROR'),
            ],
            value: ui.level,
            onChanged: notifier.level,
          ),
        ],
      ),
      child: shown.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(AppSpacing.x4),
              child: Text(
                '没有符合条件的日志',
                textAlign: TextAlign.center,
                style: context.type.subhead.copyWith(color: c.secondaryLabel),
              ),
            )
          : SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, e) in shown.indexed) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.x1),
                    _LogRow(entry: e, device: name(e.deviceId)),
                  ],
                ],
              ),
            ),
    );
  }
}

/// 一行日志：时间 · 级别（着色）· 设备 · 内容（Maintenance.dc.html）。
class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.device});

  final DeviceLogEntry entry;
  final String device;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final base = context.type.mono;
    final e = entry;
    String two(int v) => v.toString().padLeft(2, '0');
    final (label, color) = switch (e.level) {
      LogSeverity.info => ('INFO', s.busy.fg),
      LogSeverity.warn => ('WARN', s.warning.fg),
      LogSeverity.error => ('ERROR', s.critical.fg),
    };
    return Row(
      children: [
        Text(
          '${two(e.at.hour)}:${two(e.at.minute)}:${two(e.at.second)}',
          style: base.copyWith(color: c.secondaryLabel),
        ),
        const SizedBox(width: AppSpacing.x2),
        SizedBox(
          width: 40,
          child: Text(
            label,
            style: base.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: AppSpacing.x2),
        SizedBox(
          width: 56,
          child: Text(
            device,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: c.tertiaryLabel),
          ),
        ),
        const SizedBox(width: AppSpacing.x2),
        Expanded(
          child: Text(
            e.message,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: base.copyWith(color: c.label),
          ),
        ),
      ],
    );
  }
}
