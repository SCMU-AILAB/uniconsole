import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'alert_rules.dart';
import 'alert_widgets.dart';

/// 告警中心（Alerts.dc.html）：列表 + 详情（曲线、处理、时间线、备注）+ 规则与通知。
///
/// 移动端为分组列表，点开进入告警详情（MobileAlerts.dc.html）。
class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key, this.selectId});

  /// 路由 /alerts/:id 在桌面宽度下选中的告警。
  final String? selectId;

  static const _filters = [
    SegmentOption<AlertState?>(AlertState.open, '未处理'),
    SegmentOption<AlertState?>(AlertState.doing, '处理中'),
    SegmentOption<AlertState?>(AlertState.closed, '已关闭'),
    SegmentOption<AlertState?>(null, '全部'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider).value ?? const <Alert>[];
    final ui = ref.watch(alertsUiProvider);
    final uiNotifier = ref.read(alertsUiProvider.notifier);
    final mobile = LayoutSize.ofContext(context).isMobile;
    final now = watchNowOf(ref);

    final shown = [
      for (final a in alerts)
        if (ui.filter == null || a.state == ui.filter) a,
    ];
    final selectedId = ui.selected ?? selectId ?? alerts.firstOrNull?.id;
    final selected = alerts.where((a) => a.id == selectedId).firstOrNull;

    int count(AlertState s) => alerts.where((a) => a.state == s).length;
    final week = alerts
        .where((a) => now.difference(a.createdAt) < const Duration(days: 7))
        .length;
    final subtitle =
        '${count(AlertState.open)} 条未处理 · ${count(AlertState.doing)} 条处理中 · 近 7 天 $week 条';

    final filter = SegmentedControl<AlertState?>(
      semanticLabel: '告警状态',
      options: _filters,
      value: ui.filter,
      expand: mobile,
      size: mobile ? SegmentedSize.mobile : SegmentedSize.small,
      onChanged: uiNotifier.filter,
    );

    final notice = Presence(
      child: ui.notice == null
          ? null
          : Padding(
              key: ValueKey(ui.notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
            ),
    );

    if (mobile) {
      return AppPage(
        title: '告警中心',
        mobileTitle: '告警',
        subtitle: subtitle,
        mobileActions: [
          AppIconButton(
            icon: AppIcons.plus,
            label: '新建规则',
            style: IconButtonStyle.circle,
            onPressed: () => showNewRuleDialog(context, ref),
          ),
        ],
        children: [
          filter,
          _MobileAlertList(alerts: shown),
          const AlertRulesCard(),
          const NotifyChannelsCard(),
        ],
      );
    }

    return AppPage(
      title: '告警中心',
      subtitle: subtitle,
      actions: [
        filter,
        SecondaryButton(
          label: '值班表',
          onPressed: () => showRosterDialog(context, ref),
        ),
        PrimaryButton(
          label: '新建规则',
          onPressed: () => showNewRuleDialog(context, ref),
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            notice,
            FlexColumns(
              // 1000 宽时列表与详情仍并排，规则换到下方。
              leadingWidth: 260,
              trailingWidth: 280,
              mainMin: 440,
              leading: _AlertList(alerts: shown, selected: selectedId),
              main: selected == null
                  ? const AppCard(
                      child: EmptyState(title: '没有告警', icon: AppIcons.alerts),
                    )
                  : AlertDetailCard(
                      key: ValueKey(selected.id),
                      alert: selected,
                    ),
              trailing: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AlertRulesCard(),
                  SizedBox(height: AppSpacing.x3),
                  NotifyChannelsCard(),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---- 列表 ----

class _AlertList extends ConsumerWidget {
  const _AlertList({required this.alerts, required this.selected});

  final List<Alert> alerts;
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    return Semantics(
      container: true,
      label: '告警列表',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.x1),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        child: alerts.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.x6),
                child: Text(
                  '没有符合条件的告警',
                  textAlign: TextAlign.center,
                  style: t.body.copyWith(color: c.secondaryLabel),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, a) in alerts.indexed) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.half),
                    _AlertRow(alert: a, selected: a.id == selected),
                  ],
                ],
              ),
      ),
    );
  }
}

class _AlertRow extends ConsumerWidget {
  const _AlertRow({required this.alert, required this.selected});

  final Alert alert;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final now = watchNowOf(ref);
    final device = alertDevice(ref, alert);
    final time = alertTime(alert.createdAt, now);
    return Pressable(
      onTap: () => ref.read(alertsUiProvider.notifier).select(alert.id),
      semanticLabel:
          '${alert.severity.label}，${alert.title}，$device，$time，${alert.state.label}',
      selected: selected,
      focusRadius: AppRadius.lg,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        padding: const EdgeInsets.all(AppSpacing.x3),
        decoration: BoxDecoration(
          color: selected
              ? c.rowSelected
              : st.pressed
              ? c.fillSecondary
              : c.surface.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SeverityIcon(alert.severity),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.title,
                    style: t.cardTitle.copyWith(color: c.label),
                  ),
                  const SizedBox(height: AppSpacing.half),
                  Text(
                    '$device · $time',
                    style: t.footnote.copyWith(color: c.secondaryLabel),
                  ),
                  const SizedBox(height: AppSpacing.x1),
                  AlertTags(alert: alert),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileAlertList extends ConsumerWidget {
  const _MobileAlertList({required this.alerts});

  final List<Alert> alerts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final now = watchNowOf(ref);
    if (alerts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Text(
          '没有符合条件的告警',
          textAlign: TextAlign.center,
          style: context.type.mobileBody.copyWith(color: c.secondaryLabel),
        ),
      );
    }
    return InsetGroupedSection(
      dividerIndent: 56,
      children: [
        for (final a in alerts)
          GroupedListRow(
            leading: SeverityIcon(a.severity, size: 30),
            title: a.title,
            subtitle: '${alertDevice(ref, a)} · ${alertTime(a.createdAt, now)}',
            value: a.state.label,
            onTap: () =>
                context.push(Routes.alert(a.id), extra: NavIntent.push),
          ),
      ],
    );
  }
}

// ---- 详情 ----

/// 选中告警的详情（Alerts.dc.html 中间栏）。
class AlertDetailCard extends ConsumerStatefulWidget {
  const AlertDetailCard({super.key, required this.alert});

  final Alert alert;

  @override
  ConsumerState<AlertDetailCard> createState() => _AlertDetailCardState();
}

class _AlertDetailCardState extends ConsumerState<AlertDetailCard> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final a = widget.alert;
    final now = watchNowOf(ref);
    final act = AlertActions(context, ref, a);
    final hasNote = _note.text.trim().isNotEmpty;
    final d = ref.watch(deviceProvider(a.deviceId));
    final silenced = a.silencedAt(now);

    final primary = switch (a.state) {
      AlertState.open => PrimaryButton(
        label: '确认处理',
        size: ButtonSize.regular,
        onPressed: act.acknowledge,
      ),
      AlertState.doing => PrimaryButton(
        label: '关闭告警',
        size: ButtonSize.regular,
        onPressed: hasNote
            ? () async {
                if (await act.close(_note.text)) _note.clear();
              }
            : null,
      ),
      AlertState.closed => PrimaryButton(
        label: '重新打开',
        size: ButtonSize.regular,
        onPressed: act.reopen,
      ),
    };

    return AppCard(
      semanticLabel: '告警详情',
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x5,
        vertical: AppSpacing.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AlertTags(alert: a, large: true),
          const SizedBox(height: AppSpacing.x2),
          Semantics(
            header: true,
            child: Text(
              a.title,
              style: t.detailTitleSmall.copyWith(color: c.label),
            ),
          ),
          const SizedBox(height: AppSpacing.x1),
          Text(
            '${alertDevice(ref, a)} · ${a.location} · 首次触发 ${alertTime(a.createdAt, now)}',
            style: t.subhead.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppSpacing.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                  a.metric,
                  style: t.cardTitle.copyWith(color: c.label),
                ),
              ),
              Text(
                '近 30 分钟 · 红线为阈值',
                style: t.footnote.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
          AlertChart(alert: a),
          const SizedBox(height: AppSpacing.x4),
          Wrap(
            spacing: AppSpacing.x2,
            runSpacing: AppSpacing.x2,
            children: [
              primary,
              AssignMenu(
                alert: a,
                anchor: (context, toggle) => SecondaryButton(
                  label: '指派给…',
                  size: ButtonSize.regular,
                  onPressed: toggle,
                ),
              ),
              SecondaryButton(
                label: '打开操控',
                size: ButtonSize.regular,
                onPressed: d?.status.isOnline ?? false ? act.openControl : null,
              ),
              SecondaryButton(
                label: '回放触发前后 60 秒',
                size: ButtonSize.regular,
                onPressed: a.recordingId == null ? null : act.openReplay,
              ),
              SecondaryButton(
                label: silenced ? '取消静默' : '静默 30 分钟',
                size: ButtonSize.regular,
                onPressed: a.state == AlertState.closed
                    ? null
                    : act.toggleSilence,
              ),
              DestructiveButton(
                label: '远程趴下',
                size: ButtonSize.regular,
                onPressed: d?.status.isOnline ?? false ? act.remoteDown : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          Semantics(
            header: true,
            child: Text('处理时间线', style: t.cardTitle.copyWith(color: c.label)),
          ),
          const SizedBox(height: AppSpacing.x3),
          AlertTimeline(alert: a),
          const SizedBox(height: AppSpacing.x4),
          Text('处理备注', style: t.cardTitle.copyWith(color: c.label)),
          const SizedBox(height: AppSpacing.x2),
          AppTextField(
            hint: '记录原因和处理方式，关闭告警时必填',
            semanticLabel: '处理备注',
            controller: _note,
            minLines: 3,
            onChanged: (_) => setState(() {}),
          ),
          if (a.state != AlertState.closed) ...[
            const SizedBox(height: AppSpacing.x2),
            Align(
              alignment: Alignment.centerRight,
              child: SecondaryButton(
                label: '添加到时间线',
                onPressed: hasNote
                    ? () async {
                        await ref
                            .read(alertRepositoryProvider)
                            .addNote(a.id, _note.text);
                        _note.clear();
                        setState(() {});
                      }
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 处理时间线（桌面：时间在左；移动端见 alert_detail_page）。
class AlertTimeline extends ConsumerWidget {
  const AlertTimeline({super.key, required this.alert});

  final Alert alert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final now = watchNowOf(ref);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, e) in alert.events.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.x3),
          MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    eventTime(e.at, now),
                    style: t.footnote.copyWith(
                      color: c.secondaryLabel,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.x1),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: eventDot(context, e.tone),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Text(
                    e.message,
                    style: t.body.copyWith(color: c.label),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
