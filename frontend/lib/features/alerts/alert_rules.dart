import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'alert_widgets.dart';

/// 告警规则（Alerts.dc.html 右栏）：名称 + 条件说明 + 开关。
class AlertRulesCard extends ConsumerWidget {
  const AlertRulesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(alertRulesProvider).value ?? const <AlertRule>[];
    final repo = ref.read(alertRepositoryProvider);
    return _ListCard(
      title: '告警规则',
      rows: [
        for (final r in rules)
          _CardRow(
            title: r.name,
            subtitle: r.summary,
            trailing: AppSwitch(
              value: r.enabled,
              semanticLabel: r.name,
              onChanged: (v) => repo.setRuleEnabled(r.id, enabled: v),
            ),
          ),
      ],
    );
  }
}

/// 通知渠道与本周值班。
class NotifyChannelsCard extends ConsumerWidget {
  const NotifyChannelsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels =
        ref.watch(notifyChannelsProvider).value ?? const <NotifyChannel>[];
    final roster = ref.watch(onCallRosterProvider).value;
    String name(String id) => ref.watch(memberNameProvider(id)) ?? id;
    return _ListCard(
      title: '通知渠道',
      rows: [
        for (final ch in channels) _CardRow(title: ch.name, value: ch.level),
        if (roster != null)
          _CardRow(
            title: '本周值班',
            value:
                '${name(roster.currentId)} · ${roster.escalateAfter.inMinutes} 分钟未确认升级给 ${name(roster.escalateToId)}',
          ),
      ],
    );
  }
}

class _CardRow {
  const _CardRow({
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
}

/// 标题 + 分割线分隔的行（设计稿右栏卡片）。
class _ListCard extends StatelessWidget {
  const _ListCard({required this.title, required this.rows});

  final String title;
  final List<_CardRow> rows;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return AppCard(
      title: title,
      gap: AppSpacing.x2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in rows)
            MergeSemantics(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: c.separatorSubtle)),
                ),
                child: Row(
                  crossAxisAlignment: r.value != null
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    _flexIf(
                      r.value == null,
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            style: (r.subtitle == null ? t.body : t.bodyMedium)
                                .copyWith(color: c.label),
                          ),
                          if (r.subtitle != null) ...[
                            const SizedBox(height: AppSpacing.half),
                            Text(
                              r.subtitle!,
                              style: t.footnote.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (r.value != null) ...[
                      const SizedBox(width: AppSpacing.x3),
                      Expanded(
                        child: Text(
                          r.value!,
                          textAlign: TextAlign.right,
                          style: t.body.copyWith(color: c.secondaryLabel),
                        ),
                      ),
                    ],
                    if (r.trailing != null) ...[
                      const SizedBox(width: AppSpacing.x3),
                      r.trailing!,
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 有右侧值时标题按内容宽度，否则占满（让开关贴右）。
Widget _flexIf(bool expand, Widget child) =>
    expand ? Expanded(child: child) : child;

/// 值班表：按周轮值，本周在前。
Future<void> showRosterDialog(BuildContext context, WidgetRef ref) {
  final roster = ref.read(onCallRosterProvider).value;
  if (roster == null) return Future.value();
  String name(String id) => ref.read(memberNameProvider(id)) ?? id;
  final now = DateTime.now();
  final monday = DateTime(
    now.year,
    now.month,
    now.day,
  ).subtract(Duration(days: now.weekday - 1));
  String range(int week) {
    final a = monday.add(Duration(days: 7 * week));
    final b = a.add(const Duration(days: 6));
    return '${a.month}/${a.day}–${b.month}/${b.day}';
  }

  return showAppDialog<void>(
    context: context,
    builder: (context) {
      final c = context.colors;
      final t = context.type;
      return AppAlert<void>(
        title: '值班表',
        message:
            '告警 ${roster.escalateAfter.inMinutes} 分钟内无人确认时，升级给 ${name(roster.escalateToId)}。',
        content: Column(
          children: [
            for (final (i, id) in roster.weeks.indexed)
              Container(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : Border(top: BorderSide(color: c.separatorSubtle)),
                ),
                child: Row(
                  children: [
                    Avatar(name: name(id), size: 24),
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: Text(
                        name(id),
                        style: t.bodyMedium.copyWith(color: c.label),
                      ),
                    ),
                    if (i == 0) ...[
                      const Tag(label: '本周', tone: StatusTone.busy),
                      const SizedBox(width: AppSpacing.x2),
                    ],
                    Text(
                      range(i),
                      style: t.subhead.copyWith(
                        color: c.secondaryLabel,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: const [AlertAction(label: '完成', value: null)],
      );
    },
  );
}

/// 新建告警规则（`POST /alert-rules`）。
Future<void> showNewRuleDialog(BuildContext context, WidgetRef ref) async {
  final draft = await showAppDialog<_RuleDraft?>(
    context: context,
    builder: (context) => const _NewRuleDialog(),
  );
  if (draft == null) return;
  await ref
      .read(alertRepositoryProvider)
      .addRule(
        name: draft.name,
        metric: draft.metric,
        op: draft.op,
        threshold: draft.threshold!,
        duration: draft.duration,
        severity: draft.severity,
        autoAction: draft.autoAction,
      );
  ref
      .read(alertsUiProvider.notifier)
      .notify(BannerKind.success, '已新建规则「${draft.name}」');
}

class _RuleDraft {
  const _RuleDraft({
    required this.name,
    required this.metric,
    required this.op,
    required this.threshold,
    required this.duration,
    required this.severity,
    required this.autoAction,
  });

  final String name;
  final AlertMetric metric;
  final String op;
  final double? threshold;
  final Duration duration;
  final AlertSeverity severity;
  final String? autoAction;
}

class _NewRuleDialog extends StatefulWidget {
  const _NewRuleDialog();

  @override
  State<_NewRuleDialog> createState() => _NewRuleDialogState();
}

class _NewRuleDialogState extends State<_NewRuleDialog> {
  final _name = TextEditingController();
  final _threshold = TextEditingController();
  var _metric = AlertMetric.motorTemp;
  var _op = '>';
  var _duration = const Duration(seconds: 10);
  var _severity = AlertSeverity.warning;
  String? _action;

  static const _actions = ['自动降速', '自动停止', '自动回桩', '通知管理者'];
  static const _durations = [0, 10, 30, 60];

  @override
  void dispose() {
    _name.dispose();
    _threshold.dispose();
    super.dispose();
  }

  double? get _value => double.tryParse(_threshold.text.trim());

  bool get _valid => _name.text.trim().isNotEmpty && _value != null;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final mobile = LayoutSize.ofContext(context).isMobile;

    Widget field(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: t.subheadStrong.copyWith(color: c.secondaryLabel)),
          const SizedBox(height: AppSpacing.x1),
          child,
        ],
      ),
    );

    Widget menu<T>(
      T value,
      List<MenuOption<T>> options,
      ValueChanged<T> onSelected,
    ) => AppMenu<T>(
      options: options,
      selected: value,
      onSelected: (v) => setState(() => onSelected(v)),
      anchor: (context, toggle) => SecondaryButton(
        label: options.firstWhere((o) => o.value == value).label,
        trailingIcon: AppIcons.chevronDown,
        onPressed: toggle,
      ),
    );

    return AppAlert<_RuleDraft?>(
      title: '新建告警规则',
      primaryEnabled: _valid,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field(
            '名称',
            AppTextField(
              hint: '如「电压过低」',
              controller: _name,
              autofocus: true,
              mobile: mobile,
              onChanged: (_) => setState(() {}),
            ),
          ),
          field(
            '条件',
            Wrap(
              spacing: AppSpacing.x2,
              runSpacing: AppSpacing.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                menu(_metric, [
                  for (final m in AlertMetric.values) MenuOption(m, m.label),
                ], (v) => _metric = v),
                menu(_op, const [
                  MenuOption('>', '>'),
                  MenuOption('<', '<'),
                  MenuOption('>=', '≥'),
                  MenuOption('<=', '≤'),
                ], (v) => _op = v),
                SizedBox(
                  width: 96,
                  child: AppTextField(
                    hint:
                        '阈值${_metric.unit.isEmpty ? '' : '（${_metric.unit}）'}',
                    semanticLabel: '阈值',
                    controller: _threshold,
                    mobile: mobile,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                menu(_duration, [
                  for (final s in _durations)
                    MenuOption(Duration(seconds: s), s == 0 ? '立即' : '持续 $s 秒'),
                ], (v) => _duration = v),
              ],
            ),
          ),
          field(
            '级别',
            SegmentedControl<AlertSeverity>(
              semanticLabel: '级别',
              expand: true,
              options: [
                for (final s in AlertSeverity.values) SegmentOption(s, s.label),
              ],
              value: _severity,
              onChanged: (v) => setState(() => _severity = v),
            ),
          ),
          field(
            '自动动作',
            menu<String?>(_action, [
              const MenuOption(null, '无'),
              for (final a in _actions) MenuOption(a, a),
            ], (v) => _action = v),
          ),
        ],
      ),
      actions: [
        const AlertAction<_RuleDraft?>(
          label: '取消',
          value: null,
          kind: AlertActionKind.cancel,
        ),
        AlertAction<_RuleDraft?>(
          label: '新建',
          value: _RuleDraft(
            name: _name.text.trim(),
            metric: _metric,
            op: _op,
            threshold: _value,
            duration: _duration,
            severity: _severity,
            autoAction: _action,
          ),
        ),
      ],
    );
  }
}
