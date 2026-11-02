import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import 'gallery_sections.dart';

/// 第 1 阶段组件预览页：展示设计规范与全部通用组件。
///
/// 布局按 §11 断点切换：≥ 900 完整侧边栏，600–900 图标栏，< 600 移动布局 + 底部标签栏。
class GalleryPage extends ConsumerStatefulWidget {
  const GalleryPage({super.key});

  @override
  ConsumerState<GalleryPage> createState() => _GalleryPageState();
}

class _Entry {
  const _Entry(this.id, this.label, this.icon);

  final String id;
  final String label;
  final AppIcons icon;
}

const _groups = <(String, List<_Entry>)>[
  (
    '设计规范',
    [
      _Entry('colors', '颜色', AppIcons.sun),
      _Entry('type', '字体', AppIcons.agent),
      _Entry('metrics', '尺寸与圆角', AppIcons.devices),
    ],
  ),
  (
    '基础组件',
    [
      _Entry('buttons', '按钮', AppIcons.plus),
      _Entry('inputs', '输入控件', AppIcons.settings),
      _Entry('status', '状态与标签', AppIcons.info),
      _Entry('cards', '卡片与统计', AppIcons.devices),
      _Entry('lists', '分组列表', AppIcons.list),
      _Entry('feedback', '横幅与空状态', AppIcons.alerts),
      _Entry('table', '数据表', AppIcons.members),
    ],
  ),
  (
    '专用组件',
    [
      _Entry('charts', '图表', AppIcons.replay),
      _Entry('timeline', '时间轴', AppIcons.missions),
      _Entry('control', '操控', AppIcons.control),
      _Entry('pointcloud', '点云', AppIcons.sensors),
      _Entry('map', '地图', AppIcons.location),
      _Entry('logs', '日志', AppIcons.maintenance),
      _Entry('navigation', '导航', AppIcons.fleet),
    ],
  ),
];

class _GalleryPageState extends ConsumerState<GalleryPage> {
  final _keys = {
    for (final g in _groups)
      for (final e in g.$2) e.id: GlobalKey(),
  };
  String _selected = 'colors';
  String _tab = 'devices';
  bool _estop = false;

  void _jump(String id) {
    setState(() => _selected = id);
    final ctx = _keys[id]!.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _toggleStop() => setState(() => _estop = !_estop);

  Widget _section(String id, Widget child) =>
      KeyedSubtree(key: _keys[id], child: child);

  List<Widget> _sections() => [
    _section('colors', const ColorsSection()),
    _section('type', const TypographySection()),
    _section('metrics', const MetricsSection()),
    _section(
      'buttons',
      ButtonsSection(estop: _estop, onToggleStop: _toggleStop),
    ),
    _section('inputs', const InputsSection()),
    _section('status', const StatusSection()),
    _section('cards', const CardsSection()),
    _section('lists', const ListsSection()),
    _section('feedback', FeedbackSection(estop: _estop)),
    _section('table', const TableSection()),
    _section('charts', const ChartsSection()),
    _section('timeline', const TimelineSection()),
    _section('control', ControlSection(estop: _estop)),
    _section('pointcloud', const PointCloudSection()),
    _section('map', const MapSection()),
    _section('logs', const LogsSection()),
    _section('navigation', const NavigationSection()),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mode = ref.watch(themeModeProvider);
    final dark = mode == ThemeMode.dark;
    final size = LayoutSize.of(MediaQuery.sizeOf(context).width);

    final themeToggle = SegmentedControl<bool>(
      semanticLabel: '外观',
      value: dark,
      onChanged: (v) => ref
          .read(themeModeProvider.notifier)
          .set(v ? ThemeMode.dark : ThemeMode.light),
      options: const [SegmentOption(false, '浅色'), SegmentOption(true, '深色')],
    );

    final sections = _sections();
    final pad = size.isMobile
        ? const EdgeInsets.fromLTRB(16, 8, 16, 32)
        : const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.section,
            AppSpacing.page,
            28,
          );
    final content = SingleChildScrollView(
      padding: pad,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_estop) ...[
            AppBanner(
              kind: BannerKind.emergency,
              message: '已触发急停 · 所有运动按钮已禁用（再次点击急停或按空格解除）',
            ),
            const SizedBox(height: AppSpacing.section),
          ],
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 36),
            sections[i],
          ],
        ],
      ),
    );

    Widget body;
    if (size.isMobile) {
      body = Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      EmergencyStopButton(
                        engaged: _estop,
                        compact: true,
                        onPressed: _toggleStop,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      AppIconButton(
                        icon: dark ? AppIcons.sun : AppIcons.moon,
                        label: dark ? '切换到浅色' : '切换到深色',
                        style: IconButtonStyle.circle,
                        onPressed: () =>
                            ref.read(themeModeProvider.notifier).toggle(),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Semantics(
                    header: true,
                    child: Text(
                      '组件',
                      style: context.type.largeTitle.copyWith(color: c.label),
                    ),
                  ),
                  Text(
                    '第 1 阶段 · 设计规范与通用组件',
                    style: context.type.mobileFootnote.copyWith(
                      color: c.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: content),
          MobileTabBar(
            items: [
              for (final it in MobileTabBar.defaultItems)
                it.id == 'alerts'
                    ? TabItem(
                        id: it.id,
                        label: it.label,
                        icon: it.icon,
                        badge: 1,
                      )
                    : it,
            ],
            selectedId: _tab,
            onSelect: (v) => setState(() => _tab = v),
          ),
        ],
      );
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSidebar(
            compact: size == LayoutSize.medium,
            selectedId: _selected,
            onSelect: _jump,
            user: SidebarUser(
              name: 'Kanade',
              role: '平台管理员',
              color: c.avatarPalette[0],
            ),
            onUserSettings: () {},
            sections: [
              for (final (title, entries) in _groups)
                SidebarSection(
                  title: title,
                  items: [
                    for (final e in entries)
                      SidebarItem(
                        id: e.id,
                        label: e.label,
                        icon: e.icon,
                        badge: e.id == 'feedback' && _estop ? 1 : null,
                      ),
                  ],
                ),
            ],
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppToolbar(
                  title: '组件预览',
                  subtitle: '第 1 阶段 · 设计规范与通用组件 · ${size.name} 布局',
                  actions: [
                    themeToggle,
                    EmergencyStopButton(
                      engaged: _estop,
                      onPressed: _toggleStop,
                    ),
                  ],
                ),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      );
    }

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.space): _toggleStop},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: size.isMobile
              ? c.mobileBackground
              : c.windowBackground,
          body: body,
        ),
      ),
    );
  }
}
