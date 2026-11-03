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

enum DeviceFilter {
  all('全部'),
  online('在线'),
  alert('告警'),
  offline('离线');

  const DeviceFilter(this.label);

  final String label;

  bool matches(Device d) => switch (this) {
    all => true,
    online => d.status.isOnline,
    alert => d.status == DeviceStatus.alert,
    offline => !d.status.isOnline,
  };
}

enum DeviceSort {
  status('按状态排序'),
  name('按名称排序'),
  battery('按电量排序');

  const DeviceSort(this.label);

  final String label;
}

/// 「按状态」：任务中、告警在前，其次在线、充电，离线最后（MobileFleet.dc.html 的顺序）。
int _statusRank(DeviceStatus s) => switch (s) {
  DeviceStatus.busy || DeviceStatus.alert => 0,
  DeviceStatus.online => 1,
  DeviceStatus.charging => 2,
  DeviceStatus.offline => 3,
};

/// 当前选中的设备（检查器显示它）。
class SelectedDevice extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String id) => state = id;
}

final selectedDeviceProvider = NotifierProvider<SelectedDevice, String?>(
  SelectedDevice.new,
);

/// 设备总览（Main.dc.html · MobileFleet.dc.html）。
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key, this.groupId, this.selectId});

  /// 侧边栏「设备分组」筛选。
  final String? groupId;

  /// 打开时选中的设备（桌面宽度下的 /devices/:id）。
  final String? selectId;

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  DeviceFilter _filter = DeviceFilter.all;
  DeviceSort _sort = DeviceSort.status;
  bool _listView = false;
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    final id = widget.selectId;
    if (id != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(selectedDeviceProvider.notifier).select(id);
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<Device> _visible(List<Device> all) {
    final q = _query.text.trim().toLowerCase();
    final names = {
      for (final m in ref.read(membersProvider).value ?? const <Member>[])
        m.id: m.name,
    };
    bool hit(Device d) {
      if (q.isEmpty) return true;
      final user = names[ref.read(deviceUserIdProvider(d.id))] ?? '';
      final owner = names[d.ownerId] ?? '';
      return [
        d.name,
        d.code,
        user,
        owner,
      ].any((s) => s.toLowerCase().contains(q));
    }

    final list = [
      for (final d in all)
        if ((widget.groupId == null || d.groupId == widget.groupId) &&
            _filter.matches(d) &&
            hit(d))
          d,
    ];
    switch (_sort) {
      case DeviceSort.status:
        // 稳定排序：同一状态内保持原有顺序。
        final indexed = list.asMap().entries.toList()
          ..sort((a, b) {
            final r = _statusRank(a.value.status)
                .compareTo(_statusRank(b.value.status));
            return r != 0 ? r : a.key.compareTo(b.key);
          });
        return [for (final e in indexed) e.value];
      case DeviceSort.name:
        return list..sort((a, b) => a.name.compareTo(b.name));
      case DeviceSort.battery:
        return list..sort((a, b) => b.battery.compareTo(a.battery));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final all = ref.watch(devicesProvider).value ?? const <Device>[];
    final s = ref.watch(fleetSummaryProvider);
    final groups = ref.watch(deviceGroupsProvider).value ?? const [];
    final group = groups.where((g) => g.id == widget.groupId).firstOrNull;
    ref.watch(leasesProvider); // 搜索使用者时依赖租约
    final devices = _visible(all);
    final picked = ref.watch(selectedDeviceProvider);
    final selectedId = all.any((d) => d.id == picked)
        ? picked
        : (devices.firstOrNull?.id ?? all.firstOrNull?.id);
    final mobile = LayoutSize.ofContext(context).isMobile;
    final alerts = ref.watch(alertsProvider).value ?? const [];

    final filter = SegmentedControl<DeviceFilter>(
      semanticLabel: '状态筛选',
      size: mobile ? SegmentedSize.mobile : SegmentedSize.small,
      expand: mobile,
      value: _filter,
      onChanged: (f) => setState(() => _filter = f),
      options: [for (final f in DeviceFilter.values) SegmentOption(f, f.label)],
    );
    final search = SearchField(
      hint: mobile ? '搜索' : '搜索名称、编号、使用者',
      semanticLabel: '搜索设备',
      width: mobile ? null : 200,
      mobile: mobile,
      controller: _query,
      onChanged: (_) => setState(() {}),
    );

    if (mobile) {
      return AppPage(
        title: '设备总览',
        mobileTitle: group?.name ?? '设备',
        mobileActions: [
          AppMenu<DeviceSort>(
            options: [
              for (final o in DeviceSort.values) MenuOption(o, o.label),
            ],
            selected: _sort,
            onSelected: (v) => setState(() => _sort = v),
            anchor: (context, toggle) => AppIconButton(
              icon: AppIcons.filter,
              label: '排序',
              style: IconButtonStyle.circle,
              onPressed: toggle,
            ),
          ),
          AppIconButton(
            icon: AppIcons.plus,
            label: '添加设备',
            style: IconButtonStyle.circle,
            onPressed: () {},
          ),
        ],
        gap: AppSpacing.x3,
        children: [
          search,
          filter,
          _MobileList(
            devices: devices,
            caption: '${devices.length} 台设备 · ${_sort.label}',
          ),
        ],
      );
    }

    final models = all.map((d) => d.model).toSet().length;
    final alertDevice = s.alertDevices.firstOrNull;
    final alertTitle = alertDevice == null
        ? null
        : alerts
              .where(
                (a) =>
                    a.deviceId == alertDevice.id &&
                    a.state != AlertState.closed,
              )
              .firstOrNull
              ?.title;

    return AppPage(
      title: '设备总览',
      subtitle: group == null
          ? '${s.total} 台设备 · ${s.online} 台在线'
          : '分组「${group.name}」· ${s.groupCounts[group.id] ?? 0} 台设备',
      actions: [
        filter,
        search,
        PrimaryButton(label: '添加设备', icon: AppIcons.plus, onPressed: () {}),
      ],
      inspectorLabel: '设备详情',
      inspector: selectedId == null
          ? null
          : DeviceInspector(deviceId: selectedId),
      children: [
        // 统计数字与侧边栏计数来自同一个 fleetSummaryProvider（§8.5）。
        _TileGrid(
          minWidth: 170,
          maxColumns: 4,
          children: [
            StatTile(
              label: '设备总数',
              value: '${s.total}',
              caption: '${s.groupCounts.length} 个分组 · $models 种型号',
            ),
            StatTile(
              label: '在线',
              value: '${s.online}',
              caption: '${s.offline} 台离线',
              tone: StatusTone.online,
            ),
            StatTile(
              label: '告警',
              value: '${s.alertDevices.length}',
              caption: alertDevice == null
                  ? '没有告警设备'
                  : '${alertDevice.name} · ${alertTitle ?? '告警中'}',
              tone: StatusTone.warning,
            ),
            StatTile(
              label: '控制会话',
              value: '${s.controlSessions}',
              caption: '含 ${s.fleetSessions} 个联调会话',
              tone: StatusTone.busy,
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      '${_filter.label}设备 · ${devices.length}',
                      style: t.sectionTitle.copyWith(color: c.label),
                    ),
                  ),
                ),
                AppMenu<DeviceSort>(
                  options: [
                    for (final o in DeviceSort.values) MenuOption(o, o.label),
                  ],
                  selected: _sort,
                  onSelected: (v) => setState(() => _sort = v),
                  anchor: (context, toggle) => SecondaryButton(
                    label: _sort.label,
                    trailingIcon: AppIcons.chevronDown,
                    onPressed: toggle,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                _ViewToggle(
                  listView: _listView,
                  onChanged: (v) => setState(() => _listView = v),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.x3),
            if (devices.isEmpty)
              const AppCard(
                child: EmptyState(title: '没有符合条件的设备', message: '调整筛选条件或搜索关键字。'),
              )
            else if (_listView)
              _DeviceTable(
                devices: devices,
                selectedId: selectedId,
                onSelect: (id) =>
                    ref.read(selectedDeviceProvider.notifier).select(id),
              )
            else
              _TileGrid(
                minWidth: 250,
                children: [
                  for (final d in devices)
                    DeviceCard(
                      device: d,
                      selected: d.id == selectedId,
                      onTap: () => ref
                          .read(selectedDeviceProvider.notifier)
                          .select(d.id),
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// repeat(auto-fill, minmax(minWidth, 1fr))。
class _TileGrid extends StatelessWidget {
  const _TileGrid({
    required this.minWidth,
    required this.children,
    this.maxColumns = 6,
  });

  final double minWidth;
  final int maxColumns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = AppSpacing.x3;
      final cols = ((box.maxWidth + gap) / (minWidth + gap)).floor().clamp(
        1,
        maxColumns,
      );
      final w = (box.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: w, child: child),
        ],
      );
    },
  );
}

class _DeviceTable extends StatelessWidget {
  const _DeviceTable({
    required this.devices,
    required this.selectedId,
    required this.onSelect,
  });

  final List<Device> devices;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x2,
        vertical: AppSpacing.x1,
      ),
      child: AppDataTable(
        minWidth: 700,
        columns: const [
          AppDataColumn('设备', flex: 1.6),
          AppDataColumn('状态'),
          AppDataColumn('当前任务', flex: 2),
          AppDataColumn('电量', width: 96),
          AppDataColumn('延迟', width: 56, alignEnd: true),
        ],
        rows: [
          for (final d in devices)
            AppDataRow(
              selected: d.id == selectedId,
              onTap: () => onSelect(d.id),
              semanticLabel: d.name,
              cells: [
                Row(
                  children: [
                    DeviceIconTile(device: d, size: 28),
                    const SizedBox(width: AppSpacing.x3),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.name,
                            style: t.body.copyWith(
                              color: c.label,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            d.code,
                            style: t.caption.copyWith(color: c.secondaryLabel),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                StatusPill(tone: toneOf(d.status), label: d.status.label),
                Text(
                  d.currentTask,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.subhead.copyWith(color: c.label),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ProgressBar(
                        value: d.status.isOnline ? d.battery / 100 : 0,
                        semanticLabel: '电量',
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    SizedBox(
                      width: 32,
                      child: Text(
                        d.status.isOnline ? '${d.battery}%' : '—',
                        style: t.footnote.copyWith(color: c.tertiaryLabel),
                      ),
                    ),
                  ],
                ),
                Text(
                  d.latencyMs == null ? '—' : '${d.latencyMs} ms',
                  style: t.footnote.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 卡片 / 列表视图切换（描边的两段按钮组）。
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.listView, required this.onChanged});

  final bool listView;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget seg(bool isList, AppIcons icon, String label) {
      final on = listView == isList;
      return Pressable(
        onTap: () => onChanged(isList),
        semanticLabel: label,
        tooltip: label,
        selected: on,
        focusRadius: AppRadius.xs,
        builder: (context, st) => AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          width: 30,
          height: 24,
          alignment: Alignment.center,
          color: on
              ? c.segmentedTrack
              : (st.pressed ? c.fillSecondary : c.surface),
          child: AppIcon(
            icon,
            size: 13,
            strokeWidth: 2,
            color: on ? c.label : c.secondaryLabel,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.controlBorder),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(false, AppIcons.devices, '卡片视图'),
          Container(width: 1, height: 24, color: c.controlBorder),
          seg(true, AppIcons.list, '列表视图'),
        ],
      ),
    );
  }
}

/// 移动端设备列表（MobileFleet.dc.html）。
class _MobileList extends ConsumerWidget {
  const _MobileList({required this.devices, required this.caption});

  final List<Device> devices;
  final String caption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.type;
    if (devices.isEmpty) {
      return const EmptyState(title: '没有符合条件的设备', message: '调整筛选条件或搜索关键字。');
    }
    return InsetGroupedSection(
      header: caption,
      dividerIndent: 66,
      children: [
        for (final d in devices)
          Consumer(
            builder: (context, ref, _) {
              final owner = ref.watch(memberNameProvider(d.ownerId)) ?? '—';
              final user =
                  ref.watch(
                    memberNameProvider(ref.watch(deviceUserIdProvider(d.id))),
                  ) ??
                  '—';
              final sw = context.status.of(toneOf(d.status));
              return GroupedListRow(
                leading: DeviceIconTile(device: d, size: 40, showStatus: true),
                title: d.name,
                titleWeight: FontWeight.w600,
                titleTrailing: Text(
                  d.status.label,
                  style: t.subheadMedium.copyWith(color: sw.fg),
                ),
                subtitle: d.currentTask,
                detail: '管理 $owner · 使用 $user',
                value: d.status.isOnline ? '${d.battery}%' : '—',
                onTap: () =>
                    context.push(Routes.device(d.id), extra: NavIntent.push),
              );
            },
          ),
      ],
    );
  }
}
