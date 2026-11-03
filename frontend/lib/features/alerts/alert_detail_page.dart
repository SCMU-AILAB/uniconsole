import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'alert_widgets.dart';

/// 移动端告警详情（MobileAlerts.dc.html）。桌面宽度下 /alerts/:id 显示告警中心并选中该告警。
class AlertDetailPage extends ConsumerWidget {
  const AlertDetailPage({super.key, required this.alertId});

  final String alertId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final a = ref.watch(alertProvider(alertId));
    if (a == null) {
      return const AppPage(
        title: '告警详情',
        largeTitle: false,
        backLabel: '告警',
        children: [EmptyState(title: '找不到该告警', icon: AppIcons.alerts)],
      );
    }
    final now = watchNowOf(ref);
    final act = AlertActions(context, ref, a);
    final me = ref.watch(currentUserProvider).value;
    final online =
        ref.watch(deviceProvider(a.deviceId))?.status.isOnline ?? false;
    final ui = ref.watch(alertsUiProvider);
    final silenced = a.silencedAt(now);

    // 主按钮：未处理「确认处理」；自己处理中「已确认」（绿色）；别人处理中「接手处理」；
    // 已关闭「重新打开」。关闭、静默、回放在右上角「更多」里。
    final (label, kind, onTap) = switch (a.state) {
      AlertState.open => ('确认处理', _Kind.primary, act.acknowledge),
      AlertState.doing when a.assigneeId == me?.id => ('已确认', _Kind.done, null),
      AlertState.doing => ('接手处理', _Kind.primary, () => act.assign(me!.id)),
      AlertState.closed => ('重新打开', _Kind.plain, act.reopen),
    };

    return AppPage(
      title: '告警详情',
      largeTitle: false,
      backLabel: '告警',
      gap: AppSpacing.x4,
      mobileActions: [
        AppMenu<int>(
          options: [
            if (a.state != AlertState.closed) const MenuOption(0, '关闭告警…'),
            if (a.state != AlertState.closed)
              MenuOption(1, silenced ? '取消静默' : '静默 30 分钟'),
            if (a.recordingId != null) const MenuOption(2, '回放触发前后 60 秒'),
          ],
          onSelected: (v) => switch (v) {
            0 => act.promptClose(),
            1 => act.toggleSilence(),
            _ => act.openReplay(),
          },
          anchor: (context, toggle) => AppIconButton(
            icon: AppIcons.more,
            label: '更多操作',
            size: AppSizes.minTouchTarget,
            onPressed: toggle,
          ),
        ),
      ],
      children: [
        if (ui.notice != null)
          AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
        Container(
          padding: const EdgeInsets.all(AppSpacing.x4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
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
                  style: t.detailTitle.copyWith(color: c.label),
                ),
              ),
              const SizedBox(height: AppSpacing.x1),
              Text(
                '${alertDevice(ref, a)} · ${a.location} · ${alertTime(a.createdAt, now)}',
                style: t.mobileFootnote.copyWith(
                  fontSize: 14,
                  color: c.secondaryLabel,
                ),
              ),
              const SizedBox(height: AppSpacing.x3),
              AlertChart(alert: a, height: 110),
              const SizedBox(height: AppSpacing.x2),
              Text(
                '${a.metric} · 近 30 分钟 · 红线为阈值',
                style: t.subhead.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
        ),
        _ButtonGrid(
          children: [
            _BigButton(label: label, kind: kind, onTap: onTap),
            _BigButton(
              label: '远程趴下',
              kind: _Kind.destructive,
              onTap: online ? act.remoteDown : null,
            ),
            _BigButton(
              label: '查看实时画面',
              kind: _Kind.plain,
              onTap: online ? act.openControl : null,
            ),
            AssignMenu(
              alert: a,
              anchor: (context, toggle) =>
                  _BigButton(label: '指派给…', kind: _Kind.plain, onTap: toggle),
            ),
          ],
        ),
        InsetGroupedSection(
          header: '处理时间线',
          dividerIndent: 37,
          children: [
            for (final e in a.events)
              MergeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x4,
                    vertical: AppSpacing.x3,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.x2),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.message,
                              style: t.mobileBody.copyWith(color: c.label),
                            ),
                            const SizedBox(height: AppSpacing.half),
                            Text(
                              eventTime(e.at, now),
                              style: t.mobileFootnote.copyWith(
                                color: c.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 两列等宽、间距 12 的按钮网格。
class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < children.length; i += 2) ...[
        if (i > 0) const SizedBox(height: AppSpacing.x3),
        Row(
          children: [
            Expanded(child: children[i]),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: i + 1 < children.length
                  ? children[i + 1]
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    ],
  );
}

enum _Kind { primary, done, destructive, plain }

/// MobileAlerts.dc.html 的 50 高大按钮。
class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.kind, this.onTap});

  final String label;
  final _Kind kind;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final (bg, fg) = switch (kind) {
      _Kind.primary => (c.accentFill, c.onAccent),
      _Kind.done => (s.online.fg, c.onAccent),
      _Kind.destructive => (s.critical.bg, s.critical.fg),
      _Kind.plain => (c.surface, c.label),
    };
    final strong = kind != _Kind.plain;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      focusRadius: AppRadius.tile,
      builder: (context, st) => AnimatedOpacity(
        duration: AppMotion.fade(pressed: st.pressed),
        opacity: !st.enabled && kind != _Kind.done
            ? 0.45
            : st.pressed
            ? 0.7
            : 1,
        child: Container(
          height: 50,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.tile),
          ),
          child: Text(
            label,
            style: (strong ? t.mobileHeadline : t.mobileBody).copyWith(
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
