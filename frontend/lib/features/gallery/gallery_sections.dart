import 'package:flutter/material.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import 'demo_data.dart';

/// 响应式网格：按最小列宽自动决定列数（等价于 CSS auto-fill minmax）。
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.minItemWidth,
    required this.children,
    this.gap = AppSpacing.x3,
    this.maxColumns = 6,
  });

  final double minItemWidth;
  final List<Widget> children;
  final double gap;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = ((box.maxWidth + gap) / (minItemWidth + gap))
            .floor()
            .clamp(1, maxColumns);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in children) SizedBox(width: w, child: c)],
        );
      },
    );
  }
}

/// 预览区块：标题 17 semibold + 说明 + 内容。
class GallerySection extends StatelessWidget {
  const GallerySection({
    super.key,
    required this.title,
    this.description,
    required this.child,
  });

  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: context.type.sectionTitle.copyWith(color: c.label),
          ),
        ),
        if (description != null) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(
            description!,
            style: context.type.subhead.copyWith(color: c.secondaryLabel),
          ),
        ],
        const SizedBox(height: AppSpacing.x3),
        child,
      ],
    );
  }
}

/// 卡片里带小标题的一组示例。
class _Demo extends StatelessWidget {
  const _Demo(this.label, this.child);

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.type.subheadStrong.copyWith(
            color: context.colors.secondaryLabel,
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        child,
      ],
    );
  }
}

Widget _wrap(List<Widget> children, {double spacing = AppSpacing.x2}) => Wrap(
  spacing: spacing,
  runSpacing: AppSpacing.x2,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: children,
);

/// 设计稿里的人员配色（Main.dc.html `COLORS`）。
Color? _personColor(String name) => const {
  'Kanade': Color(0xFF5856D6),
  '林悦': Color(0xFFFF2D55),
  '周明': Color(0xFF248A3D),
}[name];

/// 数值格式：两位小数，负号用「−」，避免出现 -0.00。
String _num(double v) {
  final s = (v.abs() < 0.005 ? 0.0 : v).toStringAsFixed(2);
  return s.replaceFirst('-', '−');
}

String _hex(Color c) {
  final a = (c.a * 255).round();
  final rgb = c.toARGB32() & 0xFFFFFF;
  final h = rgb.toRadixString(16).padLeft(6, '0').toUpperCase();
  return a == 255 ? '#$h' : '#$h · ${(a / 255 * 100).round()}%';
}

// ---------------------------------------------------------------- 颜色

class ColorsSection extends StatelessWidget {
  const ColorsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final tokens = <(String, Color)>[
      ('windowBackground', c.windowBackground),
      ('surface', c.surface),
      ('sidebarBackground', c.sidebarBackground),
      ('sidebarSelected', c.sidebarSelected),
      ('separator', c.separator),
      ('separatorSubtle', c.separatorSubtle),
      ('fillSecondary', c.fillSecondary),
      ('segmentedTrack', c.segmentedTrack),
      ('controlBorder', c.controlBorder),
      ('label', c.label),
      ('secondaryLabel', c.secondaryLabel),
      ('tertiaryLabel', c.tertiaryLabel),
      ('decorativeGray', c.decorativeGray),
      ('accent', c.accent),
      ('accentFill', c.accentFill),
      ('link', c.link),
      ('emergency', c.emergency),
      ('rowSelected', c.rowSelected),
      ('switchOn', c.switchOn),
      ('videoBackground', c.videoBackground),
      ('hudOverlay', c.hudOverlay),
    ];
    final tones = <(String, StatusTone)>[
      ('在线 / 正常', StatusTone.online),
      ('任务中 / 信息', StatusTone.busy),
      ('警告', StatusTone.warning),
      ('严重', StatusTone.critical),
      ('离线', StatusTone.offline),
      ('动作 / 白名单', StatusTone.action),
    ];
    return GallerySection(
      title: '颜色',
      description: '全部通过 ThemeExtension 提供（context.colors / context.status），切换右上角浅色/深色查看两套值。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResponsiveGrid(
            minItemWidth: 150,
            gap: AppSpacing.x2,
            children: [
              for (final (name, color) in tokens)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.x2),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.group),
                    border: Border.all(color: c.separator),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                          border: Border.all(color: c.separator),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.footnoteMedium.copyWith(
                                color: c.label,
                              ),
                            ),
                            Text(
                              _hex(color),
                              style: context.type.mono.copyWith(
                                fontSize: 10.5,
                                color: c.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          ResponsiveGrid(
            minItemWidth: 190,
            gap: AppSpacing.x2,
            children: [
              for (final (name, tone) in tones)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.x3),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(AppRadius.group),
                    border: Border.all(color: c.separator),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StatusPill(tone: tone, label: name),
                      const SizedBox(height: AppSpacing.x2),
                      Text(
                        'dot ${_hex(s.of(tone).dot)}\nfg  ${_hex(s.of(tone).fg)}\nbg  ${_hex(s.of(tone).bg)}',
                        style: context.type.mono.copyWith(
                          fontSize: 10.5,
                          color: c.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 字体

class TypographySection extends StatelessWidget {
  const TypographySection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final ramp = <(String, TextStyle, String)>[
      ('statLarge 30', t.statLarge, '86 %'),
      ('stat 26', t.stat, '128'),
      ('detailTitle 22', t.detailTitle, 'Alpha'),
      ('detailTitleSmall 20', t.detailTitleSmall, '左后腿电机过热'),
      ('sectionTitle 17', t.sectionTitle, '全部设备'),
      ('toolbarTitle 15', t.toolbarTitle, '设备总览'),
      ('metric 15', t.metric, '0.62 m/s'),
      ('headline 14', t.headline, 'UniConsole'),
      ('cardTitle 13', t.cardTitle, '机身姿态 IMU'),
      ('body 13', t.body, '巡检路线 B-2 · 第 3/8 点位'),
      ('subhead 12', t.subhead, '3 个分组 · 4 种型号'),
      ('footnote 11.5', t.footnote, 'GO2-01 · Unitree Go2 EDU'),
      ('caption 11', t.caption, '机器人管理与联控'),
      ('mono 11.5', t.mono, '14:32:08  sport.Move(vx=0.62, vy=0, wz=-0.15)'),
    ];
    final mobile = <(String, TextStyle, String)>[
      ('largeTitle 34', t.largeTitle, '设备'),
      ('mobileBodyLarge 17', t.mobileBodyLarge, '横屏操控'),
      ('mobileBody 15', t.mobileBody, '巡检路线 B-2'),
      ('mobileFootnote 13', t.mobileFootnote, '8 台设备 · 按状态排序'),
      ('tabLabel 10', t.tabLabel, '智能体'),
    ];
    Widget rows(List<(String, TextStyle, String)> list) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (name, style, sample) in list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    name,
                    style: t.mono.copyWith(color: c.secondaryLabel),
                  ),
                ),
                Expanded(
                  child: Text(
                    sample,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.copyWith(color: c.label),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    return GallerySection(
      title: '字体',
      description: '系统字体（Apple：SF Pro + PingFang SC），所有样式开启等宽数字；日志与指令使用等宽字体。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          AppCard(title: '桌面', child: rows(ramp)),
          AppCard(title: '移动', child: rows(mobile)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 尺寸

class MetricsSection extends StatelessWidget {
  const MetricsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final radii = <(String, double)>[
      ('xs 6', AppRadius.xs),
      ('sm 7', AppRadius.sm),
      ('md 8', AppRadius.md),
      ('lg 9', AppRadius.lg),
      ('group 10', AppRadius.group),
      ('tile 12', AppRadius.tile),
      ('card 14', AppRadius.card),
    ];
    final spaces = [
      AppSpacing.x1,
      AppSpacing.x2,
      AppSpacing.x3,
      AppSpacing.x4,
      AppSpacing.section,
      AppSpacing.page,
    ];
    return GallerySection(
      title: '尺寸、圆角、间距',
      description: '侧边栏 224 · 图标栏 64 · 导航项 30 · 工具栏 ≥52 · 移动触控目标 ≥44。断点 600 / 900 / 1280。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          AppCard(
            title: '圆角',
            child: _wrap(spacing: AppSpacing.x3, [
              for (final (name, r) in radii)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 52,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.fillSecondary,
                        borderRadius: BorderRadius.circular(r),
                        border: Border.all(color: c.controlBorder),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x1),
                    Text(
                      name,
                      style: t.caption.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
            ]),
          ),
          AppCard(
            title: '间距',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in spaces)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x1,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 36,
                          child: Text(
                            '${s.round()}',
                            style: t.mono.copyWith(color: c.secondaryLabel),
                          ),
                        ),
                        Container(
                          width: s * 4,
                          height: 10,
                          decoration: BoxDecoration(
                            color: c.accent.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 按钮

class ButtonsSection extends StatelessWidget {
  const ButtonsSection({
    super.key,
    required this.estop,
    required this.onToggleStop,
  });

  final bool estop;
  final VoidCallback onToggleStop;

  @override
  Widget build(BuildContext context) {
    void noop() {}
    return GallerySection(
      title: '按钮',
      description: '主按钮 / 次级按钮 / 危险按钮 / 急停 / 图标按钮（图标按钮必须带 tooltip 与语义标签）。Tab 键可遍历，空格或回车触发。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Demo(
                  '小号 · 工具栏（28）',
                  _wrap([
                    PrimaryButton(
                      label: '添加设备',
                      icon: AppIcons.plus,
                      onPressed: noop,
                    ),
                    SecondaryButton(label: '录制', onPressed: noop),
                    SecondaryButton(
                      label: '按状态排序',
                      trailingIcon: AppIcons.chevronDown,
                      onPressed: noop,
                    ),
                    const PrimaryButton(label: '禁用', onPressed: null),
                  ]),
                ),
                const SizedBox(height: AppSpacing.x4),
                _Demo(
                  '常规 · 详情操作（32）',
                  _wrap([
                    PrimaryButton(
                      label: '确认处理',
                      size: ButtonSize.regular,
                      onPressed: noop,
                    ),
                    SecondaryButton(
                      label: '指派给…',
                      size: ButtonSize.regular,
                      onPressed: noop,
                    ),
                    SecondaryButton(
                      label: '−10 s',
                      size: ButtonSize.regular,
                      filled: true,
                      onPressed: noop,
                    ),
                    DestructiveButton(
                      label: '远程趴下',
                      size: ButtonSize.regular,
                      onPressed: noop,
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.x4),
                _Demo(
                  '大号 · 姿态动作（40）',
                  _wrap([
                    PrimaryButton(
                      label: '行走',
                      size: ButtonSize.large,
                      onPressed: estop ? null : noop,
                    ),
                    SecondaryButton(
                      label: '站立',
                      size: ButtonSize.large,
                      onPressed: estop ? null : noop,
                    ),
                    SecondaryButton(
                      label: '趴下',
                      size: ButtonSize.large,
                      onPressed: estop ? null : noop,
                    ),
                  ]),
                ),
              ],
            ),
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Demo(
                  '急停（点击切换；触发后运动按钮全部禁用）',
                  _wrap([
                    EmergencyStopButton(
                      engaged: estop,
                      onPressed: onToggleStop,
                    ),
                    EmergencyStopButton(
                      engaged: false,
                      compact: true,
                      label: '全局急停',
                      onPressed: onToggleStop,
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.x4),
                _Demo(
                  '图标按钮',
                  _wrap([
                    AppIconButton(
                      icon: AppIcons.settings,
                      label: '设置',
                      onPressed: noop,
                    ),
                    AppIconButton(
                      icon: AppIcons.devices,
                      label: '卡片视图',
                      selected: true,
                      onPressed: noop,
                    ),
                    AppIconButton(
                      icon: AppIcons.list,
                      label: '列表视图',
                      onPressed: noop,
                    ),
                    AppIconButton(
                      icon: AppIcons.more,
                      label: '更多操作',
                      style: IconButtonStyle.filled,
                      onPressed: noop,
                    ),
                    AppIconButton(
                      icon: AppIcons.filter,
                      label: '筛选',
                      style: IconButtonStyle.circle,
                      onPressed: noop,
                    ),
                    AppIconButton(
                      icon: AppIcons.plus,
                      label: '添加设备',
                      style: IconButtonStyle.circle,
                      onPressed: noop,
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.x4),
                _Demo(
                  '图标（AppIcon · 1.8px 描边，取自设计稿）',
                  _wrap(spacing: AppSpacing.x3, [
                    for (final i in AppIcons.values)
                      Tooltip(
                        message: i.name,
                        child: AppIcon(
                          i,
                          size: 20,
                          color: context.colors.tertiaryLabel,
                        ),
                      ),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 输入控件

class InputsSection extends StatefulWidget {
  const InputsSection({super.key});

  @override
  State<InputsSection> createState() => _InputsSectionState();
}

class _InputsSectionState extends State<InputsSection> {
  String _filter = 'all';
  String _speed = 'normal';
  bool _rule1 = true, _rule2 = false;
  bool _check1 = true, _check2 = false;
  String _target = 'self';
  double _opacity = 72, _deadzone = 10;
  bool _avoid = true, _light = false, _voice = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GallerySection(
      title: '输入控件',
      description: '分段控件 · 搜索框 · 开关 · 复选框 · 单选 · 滑块 · 芯片。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Demo(
                  '分段控件 · 工具栏',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedControl<String>(
                        semanticLabel: '状态筛选',
                        value: _filter,
                        onChanged: (v) => setState(() => _filter = v),
                        options: const [
                          SegmentOption('all', '全部'),
                          SegmentOption('online', '在线'),
                          SegmentOption('alert', '告警'),
                          SegmentOption('offline', '离线'),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                _Demo(
                  '分段控件 · 撑满（速度档位）',
                  SegmentedControl<String>(
                    semanticLabel: '速度档位',
                    size: SegmentedSize.regular,
                    expand: true,
                    value: _speed,
                    onChanged: (v) => setState(() => _speed = v),
                    options: const [
                      SegmentOption('slow', '慢 0.3 m/s'),
                      SegmentOption('normal', '标准 0.8 m/s'),
                      SegmentOption('fast', '快 1.5 m/s'),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                _Demo(
                  '分段控件 · 移动',
                  SegmentedControl<String>(
                    semanticLabel: '状态筛选',
                    size: SegmentedSize.mobile,
                    expand: true,
                    value: _filter,
                    onChanged: (v) => setState(() => _filter = v),
                    options: const [
                      SegmentOption('all', '全部'),
                      SegmentOption('online', '在线'),
                      SegmentOption('alert', '告警'),
                      SegmentOption('offline', '离线'),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.x3),
                _Demo(
                  '搜索框',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SearchField(
                        hint: '搜索名称、编号、使用者',
                        semanticLabel: '搜索设备',
                        width: 200,
                      ),
                      const SizedBox(height: AppSpacing.x2),
                      const SearchField(
                        hint: '搜索',
                        semanticLabel: '搜索设备',
                        mobile: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Demo(
                  '开关',
                  Column(
                    children: [
                      _row(
                        context,
                        '电机过温',
                        '任一关节 > 60 °C 持续 10 秒',
                        AppSwitch(
                          value: _rule1,
                          semanticLabel: '电机过温',
                          onChanged: (v) => setState(() => _rule1 = v),
                        ),
                      ),
                      Container(height: 1, color: c.separatorSubtle),
                      _row(
                        context,
                        '网络延迟',
                        '延迟 > 150 ms 持续 30 秒',
                        AppSwitch(
                          value: _rule2,
                          semanticLabel: '网络延迟',
                          onChanged: (v) => setState(() => _rule2 = v),
                        ),
                      ),
                      Container(height: 1, color: c.separatorSubtle),
                      _row(
                        context,
                        '禁用状态',
                        null,
                        const AppSwitch(
                          value: true,
                          semanticLabel: '禁用示例',
                          onChanged: null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.x2),
                _Demo(
                  '复选框 / 单选',
                  _wrap(spacing: AppSpacing.x4, [
                    AppCheckbox(
                      value: _check1,
                      label: 'Alpha',
                      onChanged: (v) => setState(() => _check1 = v),
                    ),
                    AppCheckbox(
                      value: _check2,
                      label: 'Bravo',
                      onChanged: (v) => setState(() => _check2 = v),
                    ),
                    const AppCheckbox(
                      value: true,
                      label: '锁定',
                      onChanged: null,
                    ),
                    AppRadio<String>(
                      value: 'self',
                      groupValue: _target,
                      label: '转给我',
                      onChanged: (v) => setState(() => _target = v),
                    ),
                    AppRadio<String>(
                      value: 'other',
                      groupValue: _target,
                      label: '转给其他成员',
                      onChanged: (v) => setState(() => _target = v),
                    ),
                  ]),
                ),
                const SizedBox(height: AppSpacing.x3),
                _Demo(
                  '滑块',
                  Column(
                    children: [
                      _row(
                        context,
                        '视频信息层透明度',
                        null,
                        AppSlider(
                          value: _opacity,
                          semanticLabel: '视频信息层透明度',
                          width: 160,
                          onChanged: (v) => setState(() => _opacity = v),
                        ),
                      ),
                      _row(
                        context,
                        '摇杆死区',
                        null,
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppSlider(
                              value: _deadzone,
                              max: 30,
                              semanticLabel: '摇杆死区',
                              width: 120,
                              valueLabel: (v) => '${v.round()}%',
                              onChanged: (v) => setState(() => _deadzone = v),
                            ),
                            SizedBox(
                              width: 40,
                              child: Text(
                                '${_deadzone.round()}%',
                                textAlign: TextAlign.right,
                                style: context.type.body.copyWith(
                                  color: c.secondaryLabel,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.x2),
                _Demo(
                  '芯片（辅助功能开关）',
                  _wrap(spacing: AppSpacing.x2, [
                    AppChip(
                      label: _avoid ? '避障 开' : '避障 关',
                      selected: _avoid,
                      onChanged: (v) => setState(() => _avoid = v),
                    ),
                    AppChip(
                      label: '灯光',
                      selected: _light,
                      onChanged: (v) => setState(() => _light = v),
                    ),
                    AppChip(
                      label: '语音',
                      selected: _voice,
                      onChanged: (v) => setState(() => _voice = v),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String title,
    String? sub,
    Widget trailing,
  ) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.type.bodyMedium.copyWith(color: c.label),
                ),
                if (sub != null)
                  Text(
                    sub,
                    style: context.type.footnote.copyWith(
                      color: c.secondaryLabel,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          trailing,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 状态

class StatusSection extends StatelessWidget {
  const StatusSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GallerySection(
      title: '状态与标签',
      description:
          'StatusPill · StatusDot · Tag · CountBadge · Avatar · ProgressBar。',
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Demo(
              '状态胶囊',
              _wrap([
                const StatusPill(tone: StatusTone.online, label: '在线'),
                const StatusPill(tone: StatusTone.busy, label: '任务中'),
                const StatusPill(tone: StatusTone.warning, label: '告警'),
                const StatusPill(tone: StatusTone.online, label: '充电中'),
                const StatusPill(tone: StatusTone.offline, label: '离线'),
                const StatusPill(tone: StatusTone.critical, label: '严重'),
                const StatusPill(tone: StatusTone.action, label: '动作'),
                const StatusPill(
                  tone: StatusTone.busy,
                  label: '你持有控制权 · 租约 4:18 后自动续期',
                  large: true,
                ),
              ]),
            ),
            const SizedBox(height: AppSpacing.x3),
            _Demo(
              '标签 / 圆点 / 徽标',
              _wrap([
                const Tag(
                  label: '严重',
                  tone: StatusTone.critical,
                  strong: true,
                  large: true,
                ),
                const Tag(
                  label: '警告',
                  tone: StatusTone.warning,
                  strong: true,
                  large: true,
                ),
                const Tag(
                  label: '提示',
                  tone: StatusTone.busy,
                  strong: true,
                  large: true,
                ),
                const Tag(label: '处理中'),
                const Tag(label: 'Owner'),
                const Tag(label: '联调', tone: StatusTone.action),
                const SizedBox(width: AppSpacing.x2),
                for (final t in StatusTone.values) StatusDot(t, size: 9),
                StatusDot(StatusTone.online, size: 11, ring: c.surface),
                const SizedBox(width: AppSpacing.x2),
                const CountBadge(2),
                const CountBadge(1, small: true),
              ]),
            ),
            const SizedBox(height: AppSpacing.x3),
            _Demo(
              '头像',
              _wrap([
                Avatar(name: 'Kanade', size: 30, color: _personColor('Kanade')),
                Avatar(name: '林悦', size: 28, color: _personColor('林悦')),
                Avatar(name: '周明', size: 28, color: _personColor('周明')),
                const Avatar(name: 'Echo', size: 20),
                const Avatar(name: '—', size: 20),
              ]),
            ),
            const SizedBox(height: AppSpacing.x3),
            _Demo(
              '电量条',
              Column(
                children: [
                  for (final (v, label) in [
                    (0.86, '86%'),
                    (0.41, '41%'),
                    (0.18, '18%'),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: ProgressBar(value: v, semanticLabel: '电量'),
                          ),
                          const SizedBox(width: AppSpacing.x2),
                          SizedBox(
                            width: 34,
                            child: Text(
                              label,
                              style: context.type.footnote.copyWith(
                                color: c.tertiaryLabel,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: ProgressBar(
                            value: 0.62,
                            height: 4,
                            battery: false,
                            semanticLabel: '升级进度',
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        SizedBox(
                          width: 34,
                          child: Text(
                            '62%',
                            style: context.type.footnote.copyWith(
                              color: c.tertiaryLabel,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 卡片

class CardsSection extends StatefulWidget {
  const CardsSection({super.key});

  @override
  State<CardsSection> createState() => _CardsSectionState();
}

class _CardsSectionState extends State<CardsSection> {
  String _selected = 'Alpha';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final devices = [
      (
        'Alpha',
        'GO2-01 · Unitree Go2 EDU',
        StatusTone.busy,
        '任务中',
        '巡检路线 B-2 · 第 3/8 点位',
        'B 区 · 2 号走廊',
        0.86,
        '18 ms',
        'Kanade',
        'Kanade',
        true,
      ),
      (
        'Charlie',
        'GO2-03 · Unitree Go2 EDU',
        StatusTone.warning,
        '告警',
        '左后腿电机温度 68 °C，已降速',
        'C 区 · 仓库',
        0.41,
        '64 ms',
        '林悦',
        '周明',
        true,
      ),
      (
        'Echo',
        'G1-01 · Unitree G1',
        StatusTone.busy,
        '任务中',
        '联调会话 #12 · 编队跟随',
        '展厅 · 中央',
        0.64,
        '20 ms',
        '周明',
        '周明',
        false,
      ),
    ];
    return GallerySection(
      title: '卡片与统计',
      description:
          'StatTile（统计卡）· AppCard（可选中卡片，下面三张是用通用组件拼出的设备卡）· MetricCell。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ResponsiveGrid(
            minItemWidth: 170,
            maxColumns: 4,
            children: [
              StatTile(label: '设备总数', value: '8', caption: '3 个分组 · 4 种型号'),
              StatTile(
                label: '在线',
                value: '6',
                caption: '2 台离线',
                tone: StatusTone.online,
              ),
              StatTile(
                label: '告警',
                value: '1',
                caption: 'Charlie · 电机过热',
                tone: StatusTone.warning,
              ),
              StatTile(
                label: '控制会话',
                value: '3',
                caption: '含 1 个联调会话',
                tone: StatusTone.busy,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          ResponsiveGrid(
            minItemWidth: 250,
            maxColumns: 3,
            children: [
              for (final d in devices)
                AppCard(
                  selected: _selected == d.$1,
                  onTap: () => setState(() => _selected = d.$1),
                  semanticLabel: '${d.$1}，${d.$4}，${d.$5}',
                  padding: const EdgeInsets.all(AppSpacing.card),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: c.fillSecondary,
                              borderRadius: BorderRadius.circular(
                                AppRadius.group,
                              ),
                            ),
                            child: AppIcon(
                              d.$11 ? AppIcons.dog : AppIcons.humanoid,
                              size: 24,
                              color: c.tertiaryLabel,
                              strokeWidth: 1.6,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.x3),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.$1,
                                  style: context.type.headline.copyWith(
                                    color: c.label,
                                  ),
                                ),
                                Text(
                                  d.$2,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.type.footnote.copyWith(
                                    color: c.secondaryLabel,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          StatusPill(tone: d.$3, label: d.$4),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.x3),
                      Text(
                        d.$5,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.body.copyWith(
                          fontSize: 12.5,
                          color: c.label,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.x1),
                      Row(
                        children: [
                          AppIcon(
                            AppIcons.location,
                            size: 11,
                            strokeWidth: 2.2,
                          ),
                          const SizedBox(width: AppSpacing.x1),
                          Text(
                            d.$6,
                            style: context.type.footnote.copyWith(
                              color: c.secondaryLabel,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.x3),
                      Row(
                        children: [
                          Expanded(
                            child: ProgressBar(
                              value: d.$7,
                              semanticLabel: '电量',
                            ),
                          ),
                          const SizedBox(width: AppSpacing.x2),
                          SizedBox(
                            width: 30,
                            child: Text(
                              '${(d.$7 * 100).round()}%',
                              style: context.type.footnote.copyWith(
                                color: c.tertiaryLabel,
                              ),
                            ),
                          ),
                          Text(
                            d.$8,
                            style: context.type.footnote.copyWith(
                              color: c.secondaryLabel,
                            ),
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
                          for (final (role, who) in [
                            ('管理', d.$9),
                            ('使用', d.$10),
                          ])
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Avatar(
                                  name: who,
                                  size: 20,
                                  color: _personColor(who),
                                ),
                                const SizedBox(width: AppSpacing.x2),
                                Text(
                                  '$role ',
                                  style: context.type.footnote.copyWith(
                                    color: c.secondaryLabel,
                                  ),
                                ),
                                Text(
                                  who,
                                  style: context.type.footnote.copyWith(
                                    color: c.label,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x3),
          ResponsiveGrid(
            minItemWidth: 300,
            maxColumns: 2,
            children: [
              AppCard(
                title: '机身姿态 IMU',
                child: Row(
                  children: const [
                    Expanded(
                      child: MetricCell(label: '横滚 Roll', value: '1.2°'),
                    ),
                    SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: MetricCell(label: '俯仰 Pitch', value: '−3.4°'),
                    ),
                    SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: MetricCell(label: '航向 Yaw', value: '87.5°'),
                    ),
                  ],
                ),
              ),
              AppCard(
                title: '电源',
                trailing: Text(
                  '预计剩余 1 小时 52 分',
                  style: context.type.subhead.copyWith(color: c.secondaryLabel),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '86',
                          style: context.type.statLarge.copyWith(
                            color: c.label,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        Text(
                          '%',
                          style: context.type.metric.copyWith(
                            color: c.secondaryLabel,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.x2),
                    const ProgressBar(
                      value: 0.86,
                      height: 6,
                      semanticLabel: '电量',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 分组列表

class ListsSection extends StatelessWidget {
  const ListsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    void noop() {}
    return GallerySection(
      title: '分组列表',
      description: 'GroupedList（桌面检查器）· InsetGroupedSection（移动端 iOS 风格）。',
      child: ResponsiveGrid(
        minItemWidth: 340,
        maxColumns: 2,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.section),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.separator),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GroupedList(
                  header: '人员与权限',
                  children: [
                    const GroupedListRow(
                      leading: Avatar(
                        name: 'Kanade',
                        size: 28,
                        color: Color(0xFF5856D6),
                      ),
                      title: 'Kanade',
                      titleWeight: FontWeight.w500,
                      subtitle: '管理者 · 可分配使用权、修改配置',
                      trailing: Tag(label: 'Owner'),
                    ),
                    GroupedListRow(
                      leading: Avatar(
                        name: '周明',
                        size: 28,
                        color: _personColor('周明'),
                      ),
                      title: '周明',
                      titleWeight: FontWeight.w500,
                      subtitle: '使用者 · 持有控制权',
                      trailing: AppIcon(
                        AppIcons.lock,
                        size: 14,
                        strokeWidth: 2.2,
                      ),
                    ),
                    GroupedListRow(title: '授权使用者', value: '3 人', onTap: noop),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                const GroupedList(
                  header: '设备信息',
                  children: [
                    GroupedListRow(title: '序列号', value: 'GO2E-24A0137'),
                    GroupedListRow(title: '固件版本', value: 'v1.1.7'),
                    GroupedListRow(title: 'IP 地址', value: '192.168.123.161'),
                    GroupedListRow(title: '最高电机温度', value: '42 °C'),
                    GroupedListRow(title: '运行时长', value: '3 小时 12 分'),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(AppSpacing.x4),
            decoration: BoxDecoration(
              color: c.mobileBackground,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.separator),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InsetGroupedSection(
                  header: '8 台设备 · 按状态排序',
                  dividerIndent: 66,
                  children: [
                    for (final (name, tone, label, task, bat) in [
                      (
                        'Alpha',
                        StatusTone.busy,
                        '任务中',
                        '巡检路线 B-2 · 第 3/8 点位',
                        '86%',
                      ),
                      (
                        'Charlie',
                        StatusTone.warning,
                        '告警',
                        '左后腿电机温度 68 °C',
                        '41%',
                      ),
                      ('Golf', StatusTone.offline, '离线', '离线 2 小时 · 维修间', '—'),
                    ])
                      GroupedListRow(
                        leading: SizedBox(
                          width: 40,
                          height: 40,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: c.fillSecondary,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.group,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: AppIcon(
                                  AppIcons.dog,
                                  size: 24,
                                  color: c.tertiaryLabel,
                                  strokeWidth: 1.6,
                                ),
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: StatusDot(
                                  tone,
                                  size: 9,
                                  ring: c.surface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        title: '$name  ·  $label',
                        titleWeight: FontWeight.w600,
                        subtitle: task,
                        value: bat,
                        onTap: noop,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.page),
                const InsetGroupedSection(
                  header: '通知',
                  footer: '严重告警会突破专注模式。',
                  children: [
                    GroupedListRow(title: '严重告警', value: '横幅 + 声音'),
                    GroupedListRow(title: '控制权申请', value: '横幅'),
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

// ---------------------------------------------------------------- 横幅与空状态

class FeedbackSection extends StatelessWidget {
  const FeedbackSection({super.key, required this.estop});

  final bool estop;

  @override
  Widget build(BuildContext context) {
    return GallerySection(
      title: '横幅与空状态',
      description: 'Banner：急停（实底红）/ 成功 / 信息 / 警告。急停横幅会随上方急停按钮出现。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Presence(
                child: estop
                    ? const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.x2),
                        child: AppBanner(
                          kind: BannerKind.emergency,
                          message: '已触发急停 · 电机进入阻尼模式，所有运动指令被拒绝',
                        ),
                      )
                    : null,
              ),
              const AppBanner(kind: BannerKind.success, message: 'SLAM 地图同步完成'),
              const SizedBox(height: AppSpacing.x2),
              const AppBanner(
                kind: BannerKind.info,
                message: '你持有控制权 · 租约 4:18 后自动续期',
              ),
              const SizedBox(height: AppSpacing.x2),
              AppBanner(
                kind: BannerKind.warning,
                message: 'Charlie 电机过热，已自动移出候选列表。',
                action: SecondaryButton(label: '查看', onPressed: () {}),
              ),
            ],
          ),
          AppCard(
            child: EmptyState(
              title: '没有符合条件的告警',
              message: '调整筛选条件，或查看已关闭的告警。',
              icon: AppIcons.alerts,
              action: SecondaryButton(label: '清除筛选', onPressed: () {}),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 输入框与提示框

class DialogsSection extends StatelessWidget {
  const DialogsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return GallerySection(
      title: '输入框与提示框',
      description: 'AppTextField：聚焦时强调色描边 + 外圈；多行用于附言。提示框从 104% 缩小淡入，Esc 关闭、回车确认；危险操作用红色按钮，必填原因为空时不能确认。',
      child: ResponsiveGrid(
        minItemWidth: 300,
        maxColumns: 2,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(hint: '预设名称'),
              SizedBox(height: AppSpacing.x2),
              AppTextField(hint: '附言（可选）', minLines: 2),
            ],
          ),
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: [
              SecondaryButton(
                label: '确认框',
                onPressed: () => confirmAction(
                  context,
                  title: '结束联调会话 #12？',
                  message: '2 台设备会停止当前动作，并释放会话持有的控制权。',
                  confirmLabel: '结束会话',
                  destructive: true,
                ),
              ),
              SecondaryButton(
                label: '输入框',
                onPressed: () => promptText(
                  context,
                  title: '强制收回 Charlie 的控制权？',
                  message: '会立即停止设备、通知周明，并写入审计日志。',
                  hint: '原因（必填）',
                  confirmLabel: '强制收回',
                  destructive: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 数据表

class TableSection extends StatefulWidget {
  const TableSection({super.key});

  @override
  State<TableSection> createState() => _TableSectionState();
}

class _TableSectionState extends State<TableSection> {
  int _selected = 0;
  final _checked = {0, 2};

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final members = [
      ('Kanade', '@kanade · 在线', '管理员', StatusTone.critical, '全部设备（8）', '长期'),
      (
        '林悦',
        '@linyue · 10 分钟前',
        '设备管理者',
        StatusTone.busy,
        'Charlie、Delta',
        '长期',
      ),
      (
        '周明',
        '@zhouming · 在线',
        '使用者',
        StatusTone.online,
        'Echo、Charlie（授权）',
        '2026-12-31',
      ),
      (
        '访客 · 王',
        '@guest-wang · 昨天',
        '观察者',
        StatusTone.offline,
        '展厅设备（只读）',
        '11-08 到期',
      ),
    ];
    return GallerySection(
      title: '数据表',
      description: '表头 · 行选中 · 批量勾选 · 宽度不足时容器内横向滚动（拖窄窗口试试）。',
      child: AppCard(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x2,
          vertical: AppSpacing.x2,
        ),
        child: AppDataTable(
          checkboxes: true,
          columns: const [
            AppDataColumn('成员', flex: 1.5),
            AppDataColumn('角色'),
            AppDataColumn('可访问设备', flex: 1.6),
            AppDataColumn('有效期'),
            AppDataColumn('', width: 60, alignEnd: true),
          ],
          rows: [
            for (var i = 0; i < members.length; i++)
              AppDataRow(
                selected: _selected == i,
                onTap: () => setState(() => _selected = i),
                semanticLabel: members[i].$1,
                checked: _checked.contains(i),
                onCheckedChanged: (v) =>
                    setState(() => v ? _checked.add(i) : _checked.remove(i)),
                cells: [
                  Row(
                    children: [
                      Avatar(
                        name: members[i].$1,
                        size: 30,
                        color: _personColor(members[i].$1),
                      ),
                      const SizedBox(width: AppSpacing.x3),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              members[i].$1,
                              style: t.body.copyWith(
                                color: c.label,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              members[i].$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.caption.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Tag(label: members[i].$3, tone: members[i].$4, large: true),
                  Text(
                    members[i].$5,
                    style: t.subhead.copyWith(color: c.tertiaryLabel),
                  ),
                  Text(
                    members[i].$6,
                    style: t.subhead.copyWith(color: c.secondaryLabel),
                  ),
                  SecondaryButton(label: '编辑', onPressed: () {}),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 图表

class ChartsSection extends StatelessWidget {
  const ChartsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    return GallerySection(
      title: '图表',
      description: 'LineChart（阈值虚线、多曲线、游标）· Sparkline，CustomPainter 自绘。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          AppCard(
            title: 'RL_calf 电机温度（°C）',
            trailing: Text(
              '近 30 分钟 · 红线为阈值',
              style: context.type.footnote.copyWith(color: c.secondaryLabel),
            ),
            child: LineChart(
              semanticLabel: 'RL_calf 电机温度变化曲线，阈值 60 °C',
              series: [ChartSeries(values: DemoData.motorTemp, fill: true)],
              threshold: 60,
              minY: 30,
              maxY: 75,
            ),
          ),
          AppCard(
            title: 'RL_calf 温度 · 速度',
            child: LineChart(
              semanticLabel: '温度与速度曲线',
              background: false,
              showLegend: true,
              height: 124,
              cursor: 0.334,
              series: [
                ChartSeries(
                  values: DemoData.motorTemp,
                  color: s.warning.dot,
                  label: '温度',
                ),
                ChartSeries(values: DemoData.velocity, label: '速度'),
              ],
            ),
          ),
          AppCard(
            title: 'Sparkline',
            child: Column(
              children: [
                for (final (label, values, color, th, unit) in [
                  ('延迟', DemoData.latency, null, 28.0, '18 ms'),
                  ('电量', DemoData.battery, s.online.dot, null, '86%'),
                  ('电机温度', DemoData.motorTemp, s.warning.dot, 60.0, '68 °C'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x2,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(
                            label,
                            style: context.type.body.copyWith(color: c.label),
                          ),
                        ),
                        Expanded(
                          child: Sparkline(
                            values: values,
                            color: color,
                            threshold: th,
                            semanticLabel: '$label 趋势',
                            width: double.infinity,
                          ),
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(
                            unit,
                            textAlign: TextAlign.right,
                            style: context.type.body.copyWith(
                              color: c.secondaryLabel,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 时间轴

class TimelineSection extends StatefulWidget {
  const TimelineSection({super.key});

  @override
  State<TimelineSection> createState() => _TimelineSectionState();
}

class _TimelineSectionState extends State<TimelineSection> {
  double _pos = 0.334;
  bool _playing = false;
  String _speed = '1';

  String get _time {
    final secs = (_pos * 38 * 60).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '00:${two(secs ~/ 60)}:${two(secs % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    return GallerySection(
      title: '时间轴',
      description: 'TimelineTrack：事件标记（点击跳转）+ 多轨数据 + 播放头（点击/拖动定位）；同一组件也用于任务排期。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppCard(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: AppSpacing.x3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: AppSpacing.x3,
                  runSpacing: AppSpacing.x2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SecondaryButton(
                      label: '−10 s',
                      filled: true,
                      onPressed: () =>
                          setState(() => _pos = (_pos - 10 / 2280).clamp(0, 1)),
                    ),
                    AppIconButton(
                      icon: _playing ? AppIcons.pause : AppIcons.play,
                      label: _playing ? '暂停' : '播放',
                      style: IconButtonStyle.primary,
                      iconSize: 15,
                      onPressed: () => setState(() => _playing = !_playing),
                    ),
                    SecondaryButton(
                      label: '+10 s',
                      filled: true,
                      onPressed: () =>
                          setState(() => _pos = (_pos + 10 / 2280).clamp(0, 1)),
                    ),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: _time,
                            style: TextStyle(
                              color: c.label,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text: ' / 00:38:00',
                            style: TextStyle(color: c.secondaryLabel),
                          ),
                        ],
                      ),
                      style: context.type.body,
                    ),
                    SegmentedControl<String>(
                      semanticLabel: '倍速',
                      value: _speed,
                      onChanged: (v) => setState(() => _speed = v),
                      options: const [
                        SegmentOption('0.5', '0.5×'),
                        SegmentOption('1', '1×'),
                        SegmentOption('2', '2×'),
                        SegmentOption('4', '4×'),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x3),
                TimelineTrack(
                  position: _pos,
                  positionLabel: _time,
                  onSeek: (v) => setState(() => _pos = v),
                  events: const [
                    TimelineEvent(
                      position: 0.12,
                      label: '开始巡检',
                      tone: StatusTone.busy,
                    ),
                    TimelineEvent(
                      position: 0.48,
                      label: '温度告警',
                      tone: StatusTone.critical,
                    ),
                    TimelineEvent(
                      position: 0.62,
                      label: '降速',
                      tone: StatusTone.warning,
                    ),
                    TimelineEvent(
                      position: 0.86,
                      label: '返回',
                      tone: StatusTone.online,
                    ),
                  ],
                  tracks: [
                    TimelineTrackData(
                      name: '前置 RGB',
                      color: c.accent,
                      segments: const [TimelineSegment(0, 1)],
                    ),
                    TimelineTrackData(
                      name: '点云',
                      color: c.cloudMid,
                      segments: const [
                        TimelineSegment(0, 0.55),
                        TimelineSegment(0.6, 1),
                      ],
                    ),
                    TimelineTrackData(
                      name: '遥测',
                      color: s.online.dot,
                      segments: const [TimelineSegment(0, 1)],
                    ),
                    TimelineTrackData(
                      name: '指令',
                      color: s.action.dot,
                      segments: const [
                        TimelineSegment(0.05, 0.12),
                        TimelineSegment(0.3, 0.34),
                        TimelineSegment(0.6, 0.7),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          AppCard(
            title: '今日排期',
            trailing: Text(
              '11 月 2 日 周一',
              style: context.type.subhead.copyWith(color: c.secondaryLabel),
            ),
            child: TimelineTrack(
              position: 0.6,
              labelWidth: 64,
              trackHeight: 22,
              ticks: const ['00:00', '06:00', '12:00', '18:00'],
              tracks: const [
                TimelineTrackData(
                  name: 'Alpha',
                  segments: [
                    TimelineSegment(
                      0.375,
                      0.45,
                      label: '巡检 B-2',
                      tone: StatusTone.busy,
                    ),
                    TimelineSegment(
                      0.58,
                      0.66,
                      label: '巡检 B-2',
                      tone: StatusTone.busy,
                    ),
                  ],
                ),
                TimelineTrackData(
                  name: 'Charlie',
                  segments: [
                    TimelineSegment(
                      0,
                      0.25,
                      label: '充电',
                      tone: StatusTone.online,
                    ),
                    TimelineSegment(
                      0.91,
                      1,
                      label: '夜巡 C-1',
                      tone: StatusTone.busy,
                    ),
                  ],
                ),
                TimelineTrackData(
                  name: '联调预设',
                  segments: [
                    TimelineSegment(
                      0.41,
                      0.5,
                      label: '展厅迎宾',
                      tone: StatusTone.action,
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

// ---------------------------------------------------------------- 操控

class ControlSection extends StatefulWidget {
  const ControlSection({super.key, required this.estop});

  final bool estop;

  @override
  State<ControlSection> createState() => _ControlSectionState();
}

class _ControlSectionState extends State<ControlSection> {
  String _cam = 'front';
  Offset _move = Offset.zero;
  Offset _turn = Offset.zero;
  static final _miniPts = DemoData.lidarMeters(140, 11);

  static const _cams = [
    ('front', '前置 RGB'),
    ('wide', '广角'),
    ('depth', '深度'),
    ('overlay', '雷达叠加'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final camLabel = _cams.firstWhere((e) => e.$1 == _cam).$2;
    final vx = _num(_move.dy * 0.8);
    final vy = _num(-_move.dx * 0.8);
    final wz = _num(-_turn.dx * 1.0);
    return GallerySection(
      title: '操控',
      description: 'VideoPanel（占位 + HUD 叠加）· Joystick（拖动后松手回中；急停时禁用）。',
      child: ResponsiveGrid(
        minItemWidth: 420,
        maxColumns: 2,
        children: [
          VideoPanel(
            placeholder: '[$camLabel视频流 · WebRTC]',
            topLeft: HudSegmented<String>(
              semanticLabel: '摄像头',
              options: _cams,
              value: _cam,
              onChanged: (v) => setState(() => _cam = v),
            ),
            topRight: const LiveIndicator(
              detail: '1280×720 · 30 fps · 端到端 48 ms',
            ),
            bottomLeft: HudMetrics(
              metrics: [
                HudMetric('前进 vx', '$vx m/s'),
                HudMetric('横移 vy', '$vy m/s'),
                HudMetric('转向 ωz', '$wz rad/s'),
                const HudMetric('步态', '行走'),
              ],
            ),
            bottomRight: SizedBox(
              width: 150,
              height: 96,
              child: PointCloudView(
                points: _miniPts,
                label: '雷达俯视',
                semanticLabel: '雷达俯视小窗',
              ),
            ),
            overlay: widget.estop
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: AppSpacing.x3,
                    ),
                    decoration: BoxDecoration(
                      color: c.emergency,
                      borderRadius: BorderRadius.circular(AppRadius.group),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppIcon(
                          AppIcons.stopAlert,
                          size: 17,
                          color: c.onAccent,
                          strokeWidth: 2,
                        ),
                        const SizedBox(width: AppSpacing.x2),
                        Flexible(
                          child: Text(
                            '已触发急停 · 电机进入阻尼模式，所有运动指令被拒绝',
                            style: context.type.body.copyWith(
                              color: c.onAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
          ),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.x5),
            child: Column(
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceAround,
                  spacing: AppSpacing.page,
                  runSpacing: AppSpacing.x4,
                  children: [
                    Joystick(
                      semanticLabel: '移动摇杆',
                      caption: '移动 · W A S D',
                      value: _move,
                      onChanged: widget.estop
                          ? null
                          : (v) => setState(() => _move = v),
                    ),
                    Joystick(
                      semanticLabel: '转向摇杆',
                      caption: '转向 · Q E',
                      axis: JoystickAxis.horizontal,
                      value: _turn,
                      onChanged: widget.estop
                          ? null
                          : (v) => setState(() => _turn = v),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                Text(
                  '支持键盘、手柄与触控 · 空格键 = 急停 · 松开所有输入 300 ms 后自动停止',
                  textAlign: TextAlign.center,
                  style: context.type.footnote.copyWith(
                    color: c.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 点云

class PointCloudSection extends StatelessWidget {
  const PointCloudSection({super.key});

  static final _pts = DemoData.lidarMeters(900, 7);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GallerySection(
      title: '点云',
      description: 'PointCloudView：按到机器人的距离着色（近 / 中 / 远），可显示距离环。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 7,
            child: PointCloudView(
              points: _pts,
              rangeMeters: 2.4,
              rings: const [1, 2, 4],
              showHeading: true,
              label: 'LiDAR · 俯视 · 10 Hz',
              pointSize: 2.2,
              robotSize: 14,
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          Wrap(
            spacing: AppSpacing.x4,
            children: [
              for (final (label, color) in [
                ('近 < 1 m', c.cloudNear),
                ('中 1–2 m', c.cloudMid),
                ('远 > 2 m', c.cloudFar),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, color: color),
                    const SizedBox(width: AppSpacing.x2),
                    Text(
                      label,
                      style: context.type.footnote.copyWith(
                        color: c.secondaryLabel,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 地图

class MapSection extends StatefulWidget {
  const MapSection({super.key});

  @override
  State<MapSection> createState() => _MapSectionState();
}

class _MapSectionState extends State<MapSection> {
  int _point = 3;
  String _tool = 'select';

  static const _points = [
    (1, Offset(18, 78)),
    (2, Offset(18, 40)),
    (3, Offset(34, 22)),
    (4, Offset(58, 22)),
    (5, Offset(80, 30)),
    (6, Offset(80, 60)),
    (7, Offset(58, 80)),
    (8, Offset(36, 80)),
  ];
  static const _tools = [
    ('select', '选择'),
    ('point', '添加点位'),
    ('route', '绘制路线'),
    ('ban', '禁行区'),
    ('slow', '限速区'),
    ('measure', '测距'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return GallerySection(
      title: '地图',
      description: 'FloorMapView：网格 · 墙体 · 区域（禁行 / 限速 / 白名单）· 已走 / 计划路线 · 点位（可选中）· 设备 · 充电桩。',
      child: SizedBox(
        height: 460,
        child: FloorMapView(
          rooms: const [
            MapRoom(Rect.fromLTRB(10, 10, 88, 90), filled: false),
            MapRoom(Rect.fromLTWH(26, 32, 44, 34), label: '设备间（不可通行）'),
          ],
          zones: [
            MapZone.rect(
              const Rect.fromLTWH(70, 70, 14, 16),
              kind: ZoneKind.ban,
              label: '禁行区 · 配电柜',
            ),
            MapZone.rect(
              const Rect.fromLTWH(12, 12, 12, 14),
              kind: ZoneKind.slow,
              label: '限速 0.3',
            ),
          ],
          routes: [
            MapRoute([for (final p in _points) p.$2, _points.first.$2]),
            const MapRoute([
              Offset(18, 78),
              Offset(18, 40),
              Offset(18, 22),
              Offset(34, 22),
            ], done: true),
          ],
          waypoints: [for (final p in _points) MapWaypoint(p.$1, p.$2)],
          selectedWaypoint: _point,
          onWaypointTap: (i) => setState(() => _point = i),
          robots: const [MapRobot('Alpha', Offset(26, 22))],
          chargers: const [Offset(13, 80)],
          footer:
              'B 区 · 2 层 · 分辨率 5 cm · 更新于今天 07:12 · 当前工具：${_tools.firstWhere((e) => e.$1 == _tool).$2}',
          overlays: [
            Positioned(
              left: AppSpacing.x4,
              top: AppSpacing.x4,
              child: MapOverlayPanel(
                child: Semantics(
                  label: '地图工具',
                  container: true,
                  child: IntrinsicWidth(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (id, label) in _tools)
                          Pressable(
                            onTap: () => setState(() => _tool = id),
                            selected: _tool == id,
                            semanticLabel: label,
                            focusRadius: AppRadius.xs,
                            builder: (context, st) => Container(
                              height: 30,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.x3,
                              ),
                              alignment: Alignment.centerLeft,
                              margin: const EdgeInsets.only(
                                bottom: AppSpacing.half,
                              ),
                              decoration: BoxDecoration(
                                color: _tool == id
                                    ? c.accentFill
                                    : st.pressed
                                    ? c.fillSecondary
                                    : null,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.xs,
                                ),
                              ),
                              child: Text(
                                label,
                                style: t.subhead.copyWith(
                                  color: _tool == id ? c.onAccent : c.label,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: AppSpacing.x4,
              top: AppSpacing.x4,
              child: MapOverlayPanel(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x3,
                ),
                child: DefaultTextStyle.merge(
                  style: t.footnote.copyWith(color: c.tertiaryLabel),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '巡检路线 B-2',
                        style: t.footnote.copyWith(
                          color: c.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.x1),
                      const Text('8 个点位 · 全长 64 m · 预计 18 分钟'),
                      const SizedBox(height: AppSpacing.x1),
                      Text('选中点位 $_point'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 日志

class LogsSection extends StatelessWidget {
  const LogsSection({super.key});

  @override
  Widget build(BuildContext context) {
    return GallerySection(
      title: '日志',
      description: 'LogConsole：卡片内指令日志（等宽、时间灰色）与深色远程终端。',
      child: ResponsiveGrid(
        minItemWidth: 380,
        maxColumns: 2,
        children: [
          AppCard(
            title: '指令日志',
            gap: AppSpacing.x2,
            trailing: Semantics(
              link: true,
              child: Text(
                '全部',
                style: context.type.subhead.copyWith(
                  color: context.colors.link,
                ),
              ),
            ),
            child: LogConsole(
              semanticLabel: '指令日志',
              lines: [
                for (final (t, m) in DemoData.commandLog) LogLine(m, time: t),
                const LogLine(
                  'RL_calf 温度 68 °C 超过阈值',
                  time: '14:31:02',
                  level: LogLevel.warning,
                ),
                const LogLine(
                  'heartbeat timeout · Golf',
                  time: '12:20:44',
                  level: LogLevel.error,
                ),
              ],
            ),
          ),
          const LogConsole(
            terminal: true,
            showCursor: true,
            semanticLabel: '远程终端',
            tabs: ['Alpha · ssh', 'Charlie · journalctl'],
            headerNote: '已二次验证 · 操作写入审计日志',
            lines: [
              LogLine.command(
                'unitree@go2-01:~',
                'systemctl status uniconsole-agent',
              ),
              LogLine('● uniconsole-agent.service — UniConsole Bridge'),
              LogLine(
                '   Active: active (running) since 11:20:14; 3h 12min ago',
                level: LogLevel.success,
              ),
              LogLine('   Memory: 182.4M   CPU: 11.6%'),
              LogLine.command('unitree@go2-01:~', 'df -h /data'),
              LogLine('/dev/nvme0n1p3   229G   97G  121G  45% /data'),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 导航

class NavigationSection extends StatefulWidget {
  const NavigationSection({super.key});

  @override
  State<NavigationSection> createState() => _NavigationSectionState();
}

class _NavigationSectionState extends State<NavigationSection> {
  String _tab = 'devices';
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GallerySection(
      title: '导航',
      description: 'AppToolbar（窄时操作项换行）· MobileTabBar（< 600 时替代侧边栏）。侧边栏见本页左侧；600–900 宽度时收为 64px 图标栏。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.group),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: c.separator),
                borderRadius: BorderRadius.circular(AppRadius.group),
              ),
              child: AppToolbar(
                title: '设备总览',
                subtitle: '8 台设备 · 6 台在线 · 1 条告警',
                actions: [
                  SegmentedControl<String>(
                    semanticLabel: '状态筛选',
                    value: _filter,
                    onChanged: (v) => setState(() => _filter = v),
                    options: const [
                      SegmentOption('all', '全部'),
                      SegmentOption('online', '在线'),
                      SegmentOption('alert', '告警'),
                      SegmentOption('offline', '离线'),
                    ],
                  ),
                  const SearchField(
                    hint: '搜索名称、编号、使用者',
                    semanticLabel: '搜索设备',
                    width: 200,
                  ),
                  PrimaryButton(
                    label: '添加设备',
                    icon: AppIcons.plus,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 390),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.group),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: c.mobileBackground),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: MobileTabBar(
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
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
