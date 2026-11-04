import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../auth/sign_out.dart';
import 'settings_widgets.dart';

/// 类别对应的内容。
Widget settingsContent(SettingsCategory c) => switch (c) {
  SettingsCategory.look => const AppearanceSettings(),
  SettingsCategory.pad => const ControlSettings(),
  SettingsCategory.keys => const KeyboardSettings(),
  SettingsCategory.net => const NetworkSettings(),
  SettingsCategory.notify => const NotifySettings(),
  SettingsCategory.account => const AccountSettings(),
};

// ---- 外观 ----

class AppearanceSettings extends ConsumerWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final accent = ref.watch(accentProvider);
    final prefs = ref.watch(preferencesProvider);
    return SettingsSection(
      title: '外观',
      children: [
        SettingsGroup(
          padding: const EdgeInsets.all(AppSpacing.x4),
          children: [
            Wrap(
              spacing: AppSpacing.x4,
              runSpacing: AppSpacing.x4,
              alignment: WrapAlignment.spaceEvenly,
              children: [
                for (final (m, label) in const [
                  (ThemeMode.light, '浅色'),
                  (ThemeMode.dark, '深色'),
                  (ThemeMode.system, '跟随系统'),
                ])
                  _ThemeCard(
                    mode: m,
                    label: label,
                    selected: mode == m,
                    onTap: () => ref.read(themeModeProvider.notifier).set(m),
                  ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          children: [
            SettingsRow(
              label: '强调色',
              trailing: Semantics(
                container: true,
                label: '强调色',
                child: Wrap(
                  spacing: AppSpacing.x2 + AppSpacing.half,
                  children: [
                    for (final sw in AccentSwatch.values)
                      _Swatch(
                        swatch: sw,
                        selected: sw == accent,
                        onTap: () => ref.read(accentProvider.notifier).set(sw),
                      ),
                  ],
                ),
              ),
            ),
            SettingsRow(
              label: '侧边栏图标大小',
              trailing: SegmentedControl<SidebarIconSize>(
                semanticLabel: '侧边栏图标大小',
                options: [
                  for (final s in SidebarIconSize.values)
                    SegmentOption(s, s.label),
                ],
                value: prefs.sidebarIconSize,
                onChanged: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(sidebarIconSize: v)),
              ),
            ),
            SettingsRow(
              label: '视频画面信息层透明度',
              trailing: AppSlider(
                semanticLabel: '视频画面信息层透明度',
                value: prefs.hudOpacity * 100,
                valueLabel: (v) => '${v.round()}%',
                onChanged: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(hudOpacity: v / 100)),
              ),
            ),
            SettingsRow(
              label: '操控时保持深色',
              subtitle: '进入操控页面时始终使用深色界面，减少画面干扰',
              trailing: AppSwitch(
                value: prefs.darkWhileControlling,
                semanticLabel: '操控时保持深色',
                onChanged: (v) => updatePrefs(
                  ref,
                  (p) => p.copyWith(darkWhileControlling: v),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 外观缩略图（Settings.dc.html themes）：侧边栏 + 四张卡片的迷你窗口。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // 缩略图展示的是对应模式本身的颜色，而不是当前主题。
    final light = AppColors.light, dark = AppColors.dark;
    final (win, side, card, line) = switch (mode) {
      ThemeMode.light => (
        light.surface,
        light.sidebarBackground,
        light.separator,
        light.controlBorder,
      ),
      ThemeMode.dark => (
        dark.windowBackground,
        dark.surface,
        dark.separator,
        dark.controlBorder,
      ),
      ThemeMode.system => (
        dark.windowBackground,
        light.sidebarBackground,
        dark.separator,
        light.controlBorder,
      ),
    };
    Widget bar(Color color) => Container(
      height: 5,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      focusRadius: AppRadius.group,
      builder: (context, st) => SizedBox(
        width: 150,
        child: Column(
          children: [
            Container(
              height: 96,
              decoration: BoxDecoration(
                color: win,
                borderRadius: BorderRadius.circular(AppRadius.group),
                boxShadow: [
                  BoxShadow(
                    color: selected ? c.accent : c.separator,
                    spreadRadius: selected ? 3 : 1,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 48,
                    color: side,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x2,
                      vertical: AppSpacing.x3,
                    ),
                    child: Column(
                      children: [
                        bar(c.accent),
                        const SizedBox(height: AppSpacing.x1),
                        bar(line),
                        const SizedBox(height: AppSpacing.x1),
                        bar(line),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.x2,
                        vertical: AppSpacing.x3,
                      ),
                      child: GridView.count(
                        crossAxisCount: 2,
                        mainAxisSpacing: AppSpacing.x1,
                        crossAxisSpacing: AppSpacing.x1,
                        childAspectRatio: 1.25,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          for (var i = 0; i < 4; i++)
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: card,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              label,
              style: context.type.body.copyWith(
                color: c.label,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.swatch,
    required this.selected,
    required this.onTap,
  });

  final AccentSwatch swatch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = swatch.forBrightness(c.brightness);
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: swatch.label,
      tooltip: swatch.label,
      focusRadius: 11,
      builder: (context, st) => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: selected
              ? [
                  BoxShadow(color: c.surface, spreadRadius: 2),
                  BoxShadow(color: color, spreadRadius: 4),
                ]
              : null,
        ),
      ),
    );
  }
}

// ---- 控制与手柄 ----

class ControlSettings extends ConsumerWidget {
  const ControlSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final prefs = ref.watch(preferencesProvider);
    final pad = ref.watch(gamepadProvider).value;
    final mobile = LayoutSize.ofContext(context).isMobile;

    void rebind(int i, String control) => updatePrefs(ref, (p) {
      final b = [...p.bindings];
      final j = b.indexWhere((x) => x.control == control);
      final old = b[i].control;
      b[i] = GamepadBinding(control, b[i].action);
      // 该按键原来绑定了别的动作：两者互换。
      if (j >= 0 && j != i) b[j] = GamepadBinding(old, b[j].action);
      return p.copyWith(bindings: b);
    });

    final status = SettingsGroup(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x4,
        vertical: AppSpacing.x1,
      ),
      children: [
        SettingsRow(
          leading: AppIcon(AppIcons.control, size: 28, color: c.secondaryLabel),
          label: pad?.name ?? '未连接手柄',
          subtitle: pad == null
              ? '用蓝牙或 USB 连接 · 支持 Xbox / PS / Switch Pro / 通用 HID 手柄'
              : '${pad.connection}${pad.battery == null ? '' : ' · 电量 ${pad.battery}%'} · 支持 PS / Switch Pro / 通用 HID 手柄',
          trailing: SecondaryButton(
            label: '测试输入',
            onPressed: pad == null ? null : () => _testInput(context, ref),
          ),
        ),
      ],
    );

    final bindings = SettingsGroup(
      children: [
        for (final (i, b) in prefs.bindings.indexed)
          SettingsRow(
            dense: true,
            leading: KeyCap(
              b.control,
              minWidth: mobile ? 84 : 110,
              mono: false,
            ),
            label: b.action,
            trailing: AppMenu<String>(
              options: [for (final g in gamepadControls) MenuOption(g, g)],
              selected: b.control,
              onSelected: (g) => rebind(i, g),
              anchor: (context, toggle) => Pressable(
                onTap: toggle,
                semanticLabel: '重新绑定「${b.action}」',
                focusRadius: AppRadius.xs,
                builder: (context, st) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x2,
                    vertical: AppSpacing.x1,
                  ),
                  child: Text('重新绑定', style: t.subhead.copyWith(color: c.link)),
                ),
              ),
            ),
          ),
      ],
    );

    final sticks = SettingsGroup(
      children: [
        SettingsRow(
          label: '摇杆死区',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSlider(
                semanticLabel: '摇杆死区',
                value: prefs.deadzone * 100,
                max: 30,
                width: mobile ? 120 : 180,
                valueLabel: (v) => '${v.round()}%',
                onChanged: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(deadzone: v / 100)),
              ),
              const SizedBox(width: AppSpacing.x3),
              SizedBox(
                width: 36,
                child: Text(
                  '${(prefs.deadzone * 100).round()}%',
                  textAlign: TextAlign.end,
                  style: t.body.copyWith(color: c.secondaryLabel),
                ),
              ),
            ],
          ),
        ),
        SettingsRow(
          label: '响应曲线',
          trailing: ChoiceValue<ResponseCurve>(
            label: '响应曲线',
            value: prefs.curve,
            options: [
              for (final r in ResponseCurve.values) MenuOption(r, r.label),
            ],
            onSelected: (v) => updatePrefs(ref, (p) => p.copyWith(curve: v)),
          ),
        ),
      ],
    );

    return SettingsSection(title: '手柄', children: [status, bindings, sticks]);
  }

  static Future<void> _testInput(BuildContext context, WidgetRef ref) =>
      showAppDialog<void>(
        context: context,
        builder: (context) {
          final prefs = ref.read(preferencesProvider);
          final c = context.colors;
          final t = context.type;
          return AppAlert<void>(
            title: '测试输入',
            message: '按下手柄上的按键，对应的动作会高亮。',
            maxWidth: 400,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final b in prefs.bindings)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x1,
                    ),
                    child: Row(
                      children: [
                        KeyCap(b.control, minWidth: 96, mono: false),
                        const SizedBox(width: AppSpacing.x3),
                        Expanded(
                          child: Text(
                            b.action,
                            style: t.body.copyWith(color: c.label),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpacing.x2),
                Text(
                  '等待输入…（手柄插件接入后显示实时按键）',
                  textAlign: TextAlign.center,
                  style: t.footnote.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
            actions: const [AlertAction<void>(label: '完成', value: null)],
          );
        },
      );
}

// ---- 键盘快捷键 ----

class KeyboardSettings extends StatelessWidget {
  const KeyboardSettings({super.key});

  @override
  Widget build(BuildContext context) => SettingsSection(
    title: '键盘快捷键',
    children: [
      SettingsGroup(
        children: [
          for (final (label, keys) in keyboardShortcuts())
            SettingsRow(dense: true, label: label, trailing: KeyCap(keys)),
        ],
      ),
    ],
  );
}

// ---- 视频与网络 ----

class NetworkSettings extends ConsumerWidget {
  const NetworkSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(preferencesProvider);
    return SettingsSection(
      title: '视频与网络',
      children: [
        SettingsGroup(
          children: [
            const SettingsRow(label: '视频编码', value: 'H.264 硬件编码 · 自适应码率'),
            SettingsRow(
              label: '默认画质',
              trailing: ChoiceValue<VideoQuality>(
                label: '默认画质',
                value: p.videoQuality,
                options: [
                  for (final v in VideoQuality.values) MenuOption(v, v.label),
                ],
                onSelected: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(videoQuality: v)),
              ),
            ),
            SettingsRow(
              label: '弱网策略',
              trailing: ChoiceValue<WeakNetworkPolicy>(
                label: '弱网策略',
                value: p.weakNetwork,
                options: [
                  for (final v in WeakNetworkPolicy.values)
                    MenuOption(v, v.label),
                ],
                onSelected: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(weakNetwork: v)),
              ),
            ),
            SettingsRow(
              label: '中继服务器',
              trailing: ChoiceValue<RelayServer>(
                label: '中继服务器',
                value: p.relay,
                options: [
                  for (final v in RelayServer.values) MenuOption(v, v.label),
                ],
                onSelected: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(relay: v)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---- 通知 ----

class NotifySettings extends ConsumerWidget {
  const NotifySettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(preferencesProvider);
    Widget style(
      String label,
      NotifyStyle value,
      Preferences Function(Preferences, NotifyStyle) set,
    ) => SettingsRow(
      label: label,
      trailing: ChoiceValue<NotifyStyle>(
        label: label,
        value: value,
        options: [for (final s in NotifyStyle.values) MenuOption(s, s.label)],
        onSelected: (v) => updatePrefs(ref, (p) => set(p, v)),
      ),
    );
    return SettingsSection(
      title: '通知',
      children: [
        SettingsGroup(
          children: [
            style(
              '严重告警',
              p.notifyCritical,
              (p, v) => p.copyWith(notifyCritical: v),
            ),
            style(
              '警告',
              p.notifyWarning,
              (p, v) => p.copyWith(notifyWarning: v),
            ),
            style('控制权申请', p.notifyLease, (p, v) => p.copyWith(notifyLease: v)),
            SettingsRow(
              label: '每日巡检报告',
              trailing: ChoiceValue<int?>(
                label: '每日巡检报告',
                value: p.dailyReportHour,
                options: [
                  const MenuOption(null, '关闭'),
                  for (final h in const [17, 18, 19, 20])
                    MenuOption(h, '每天 $h:00'),
                ],
                onSelected: (v) => updatePrefs(
                  ref,
                  (p) => v == null
                      ? p.copyWith(clearDailyReport: true)
                      : p.copyWith(dailyReportHour: v),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---- 账户与安全 ----

class AccountSettings extends ConsumerWidget {
  const AccountSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final p = ref.watch(preferencesProvider);
    final clients = ref.watch(signedInClientsProvider).value ?? const [];
    final tokens = ref.watch(apiTokensProvider).value ?? const [];

    Widget link(String text, VoidCallback onTap, String semantic) => Pressable(
      onTap: onTap,
      semanticLabel: semantic,
      focusRadius: AppRadius.xs,
      builder: (context, st) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.end,
              style: t.body.copyWith(color: c.secondaryLabel),
            ),
          ),
          const SizedBox(width: AppSpacing.x1),
          AppIcon(AppIcons.chevronRight, size: 13, color: c.secondaryLabel),
        ],
      ),
    );

    return SettingsSection(
      title: '账户与安全',
      children: [
        SettingsGroup(
          children: [
            const SettingsRow(label: '登录方式', value: '账号与密码'),
            SettingsRow(
              label: '二次验证',
              subtitle: '远程终端和强制收回需要',
              trailing: AppSwitch(
                value: p.twoFactor,
                semanticLabel: '二次验证',
                onChanged: (v) =>
                    updatePrefs(ref, (p) => p.copyWith(twoFactor: v)),
              ),
            ),
            SettingsRow(
              label: '已登录设备',
              trailing: Flexible(
                child: link(
                  clients.map((x) => x.name).join('、'),
                  () => _clientsDialog(context),
                  '已登录设备：${clients.length} 台',
                ),
              ),
            ),
            SettingsRow(
              label: 'API 令牌',
              trailing: link(
                '${tokens.length} 个 · 用于智能体与自动化',
                () => _tokensDialog(context),
                'API 令牌：${tokens.length} 个',
              ),
            ),
          ],
        ),
        SettingsGroup(
          children: [
            SettingsRow(
              label: '退出登录',
              subtitle: '在这台设备上退出当前账户',
              trailing: DestructiveButton(
                label: '退出登录',
                onPressed: () => confirmSignOut(context, ref),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static Future<void> _clientsDialog(
    BuildContext context,
  ) => showAppDialog<void>(
    context: context,
    builder: (context) => _ListDialog(
      title: '已登录设备',
      rows: (ref) => [
        for (final x in ref.watch(signedInClientsProvider).value ?? const [])
          (
            x.name,
            x.detail,
            x.current
                ? null
                : (
                    '退出登录',
                    () => ref.read(preferencesRepositoryProvider).signOut(x.id),
                  ),
          ),
      ],
    ),
  );

  static Future<void> _tokensDialog(BuildContext context) =>
      showAppDialog<void>(
        context: context,
        builder: (context) => _ListDialog(
          title: 'API 令牌',
          rows: (ref) => [
            for (final x in ref.watch(apiTokensProvider).value ?? const [])
              (
                x.name,
                x.detail,
                (
                  '撤销',
                  () =>
                      ref.read(preferencesRepositoryProvider).revokeToken(x.id),
                ),
              ),
          ],
        ),
      );
}

typedef _Row = (String, String, (String, VoidCallback)?);

class _ListDialog extends ConsumerWidget {
  const _ListDialog({required this.title, required this.rows});

  final String title;
  final List<_Row> Function(WidgetRef ref) rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final items = rows(ref);
    return AppAlert<void>(
      title: title,
      maxWidth: 420,
      content: items.isEmpty
          ? Text(
              '没有了',
              textAlign: TextAlign.center,
              style: t.body.copyWith(color: c.secondaryLabel),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (name, detail, action) in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.x2,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: t.cardTitle.copyWith(color: c.label),
                              ),
                              Text(
                                detail,
                                style: t.footnote.copyWith(
                                  color: c.secondaryLabel,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (action != null)
                          DestructiveButton(
                            label: action.$1,
                            onPressed: action.$2,
                          ),
                      ],
                    ),
                  ),
              ],
            ),
      actions: const [AlertAction<void>(label: '完成', value: null)],
    );
  }
}
