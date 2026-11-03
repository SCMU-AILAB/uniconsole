import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 告警级别 → 状态色（提示用「任务中 / 信息」蓝）。
StatusTone severityTone(AlertSeverity s) => switch (s) {
  AlertSeverity.critical => StatusTone.critical,
  AlertSeverity.warning => StatusTone.warning,
  AlertSeverity.info => StatusTone.busy,
};

String _two(int v) => v.toString().padLeft(2, '0');

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _day(DateTime t, DateTime now) {
  if (_sameDay(t, now)) return '';
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return '昨天 ';
  return '${t.month} 月 ${t.day} 日 ';
}

/// 列表时间：今天「14:31」，昨天「昨天 18:20」，更早「10 月 31 日 18:20」。
String alertTime(DateTime t, DateTime now) =>
    '${_day(t, now)}${_two(t.hour)}:${_two(t.minute)}';

/// 时间线时间：今天精确到秒，更早只到分钟，刚做的操作（10 秒内）为「刚刚」。
String eventTime(DateTime t, DateTime now) {
  if (now.difference(t) < const Duration(seconds: 10) && !now.isBefore(t)) {
    return '刚刚';
  }
  return _sameDay(t, now)
      ? '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
      : alertTime(t, now);
}

/// 「Charlie · GO2-03」。
String alertDevice(WidgetRef ref, Alert a) {
  final d = ref.watch(deviceProvider(a.deviceId));
  return d == null ? a.deviceId : '${d.name} · ${d.code}';
}

/// 状态标签文字：处理中时带上处理人（「处理中 · 你」「处理中 · 周明」）。
String alertStateLabel(WidgetRef ref, Alert a) {
  if (a.state != AlertState.doing || a.assigneeId == null) {
    return a.state.label;
  }
  final me = ref.watch(currentUserProvider).value;
  final who = a.assigneeId == me?.id
      ? '你'
      : ref.watch(memberNameProvider(a.assigneeId)) ?? a.assigneeId!;
  return '${a.state.label} · $who';
}

/// 「!」图标块（Alerts.dc.html 列表行左侧）。
class SeverityIcon extends StatelessWidget {
  const SeverityIcon(this.severity, {super.key, this.size = 28});

  final AlertSeverity severity;
  final double size;

  @override
  Widget build(BuildContext context) {
    final sw = context.status.of(severityTone(severity));
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sw.bg,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Text(
          '!',
          style: context.type.headline.copyWith(
            color: sw.fg,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// 级别 + 状态两个标签。
class AlertTags extends ConsumerWidget {
  const AlertTags({super.key, required this.alert, this.large = false});

  final Alert alert;
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = watchNowOf(ref);
    final doing = alert.state == AlertState.doing;
    return Wrap(
      spacing: AppSpacing.x1,
      runSpacing: AppSpacing.x1,
      children: [
        Tag(
          label: alert.severity.label,
          tone: severityTone(alert.severity),
          strong: large,
          large: large,
        ),
        Tag(
          label: large ? alertStateLabel(ref, alert) : alert.state.label,
          tone: large && doing ? StatusTone.busy : null,
          large: large,
        ),
        if (alert.silencedAt(now)) Tag(label: '已静默', large: large),
      ],
    );
  }
}

DateTime watchNowOf(WidgetRef ref) =>
    ref.watch(clockProvider).value ?? DateTime.now();

/// 处理时间线圆点颜色：触发为级别色，自动动作 / 通知为灰，人工处理为强调色。
Color eventDot(BuildContext context, EventTone tone) {
  final s = context.status;
  final c = context.colors;
  return switch (tone) {
    EventTone.critical => s.critical.dot,
    EventTone.warning => s.warning.dot,
    EventTone.info => c.accent,
    EventTone.success => s.online.dot,
    EventTone.neutral => c.decorativeGray,
  };
}

/// 告警曲线（触发前 30 分钟，红色虚线为阈值）。
class AlertChart extends ConsumerWidget {
  const AlertChart({super.key, required this.alert, this.height = 140});

  final Alert alert;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = ref.watch(alertHistoryProvider(alert.id)).value;
    return LineChart(
      semanticLabel: '${alert.metric}近 30 分钟变化曲线，红线为阈值',
      height: height,
      threshold: h?.threshold,
      minY: h?.minY ?? 0,
      maxY: h?.maxY ?? 100,
      series: [ChartSeries(values: h?.values ?? const [], fill: true)],
    );
  }
}

/// 告警的处理操作（桌面详情、移动详情共用）。
class AlertActions {
  AlertActions(this.context, this.ref, this.alert);

  final BuildContext context;
  final WidgetRef ref;
  final Alert alert;

  static const silenceFor = Duration(minutes: 30);

  void _notify(BannerKind kind, String text) =>
      ref.read(alertsUiProvider.notifier).notify(kind, text);

  Future<void> acknowledge() =>
      ref.read(alertRepositoryProvider).acknowledge(alert.id);

  Future<void> assign(String memberId) async {
    await ref.read(alertRepositoryProvider).assign(alert.id, memberId);
    _notify(
      BannerKind.success,
      '已指派给 ${ref.read(memberNameProvider(memberId)) ?? memberId}',
    );
  }

  Future<bool> close(String note) async {
    if (note.trim().isEmpty) return false;
    await ref.read(alertRepositoryProvider).close(alert.id, note: note);
    _notify(BannerKind.success, '已关闭「${alert.title}」');
    return true;
  }

  /// 移动端：弹出输入框填写备注后关闭。
  Future<void> promptClose() async {
    final note = await promptText(
      context,
      title: '关闭告警',
      message: '记录原因和处理方式，会写入处理时间线。',
      hint: '处理备注',
      confirmLabel: '关闭告警',
      multiline: true,
    );
    if (note != null) await close(note);
  }

  Future<void> reopen() => ref.read(alertRepositoryProvider).reopen(alert.id);

  Future<void> toggleSilence() {
    final now = DateTime.now();
    return ref
        .read(alertRepositoryProvider)
        .silence(alert.id, alert.silencedAt(now) ? null : silenceFor);
  }

  Future<void> remoteDown() async {
    final d = ref.read(deviceProvider(alert.deviceId));
    final name = d?.name ?? alert.deviceId;
    final ok = await confirmAction(
      context,
      title: '远程趴下 $name？',
      message: '通过急停通道下发，设备立即阻尼趴下；解除需要在操控页确认。',
      confirmLabel: '远程趴下',
      destructive: true,
    );
    if (!ok) return;
    await ref.read(alertRepositoryProvider).remoteDown(alert.id);
    _notify(BannerKind.emergency, '$name 已远程趴下');
  }

  void openControl() =>
      context.push(Routes.control(alert.deviceId), extra: NavIntent.push);

  /// 回放触发前后 60 秒：跳到录制里第一个告警事件前 60 秒。
  Future<void> openReplay() async {
    final id = alert.recordingId;
    if (id == null) return;
    // 告警页没有订阅录制列表（未订阅的 provider 不会产出数据），直接从仓库取一次。
    final all = await ref
        .read(recordingRepositoryProvider)
        .watchRecordings()
        .first;
    if (!context.mounted) return;
    final r = all.where((r) => r.id == id).firstOrNull;
    // 触发点：录制里的告警事件（严重优先，其次警告）。
    final events = r?.events ?? const <RecordingEvent>[];
    final trigger =
        (events.where((e) => e.tone == EventTone.critical).firstOrNull ??
                events.where((e) => e.tone == EventTone.warning).firstOrNull)
            ?.offset;
    final from = trigger == null
        ? Duration.zero
        : trigger - const Duration(seconds: 60);
    context.push(
      '${Routes.recording(id)}?t=${from.isNegative ? 0 : from.inSeconds}',
      extra: NavIntent.push,
    );
  }
}

/// 「指派给…」菜单。
class AssignMenu extends ConsumerWidget {
  const AssignMenu({super.key, required this.alert, required this.anchor});

  final Alert alert;
  final Widget Function(BuildContext context, VoidCallback toggle) anchor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider).value ?? const <Member>[];
    return AppMenu<String>(
      options: [for (final m in members) MenuOption(m.id, m.name)],
      selected: alert.assigneeId,
      onSelected: (id) => AlertActions(context, ref, alert).assign(id),
      anchor: anchor,
    );
  }
}

// ---- 页面状态 ----

class AlertsUiState {
  const AlertsUiState({this.filter, this.selected, this.notice});

  /// null 为全部。
  final AlertState? filter;

  /// 用户点选的告警；为空时用路由参数或第一条。
  final String? selected;
  final (BannerKind, String)? notice;
}

class AlertsUi extends Notifier<AlertsUiState> {
  @override
  AlertsUiState build() => const AlertsUiState();

  void filter(AlertState? f) => state = AlertsUiState(
    filter: f,
    selected: state.selected,
    notice: state.notice,
  );

  void select(String id) => state = AlertsUiState(
    filter: state.filter,
    selected: id,
    notice: state.notice,
  );

  void notify(BannerKind kind, String text) => state = AlertsUiState(
    filter: state.filter,
    selected: state.selected,
    notice: (kind, text),
  );
}

final alertsUiProvider = NotifierProvider.autoDispose<AlertsUi, AlertsUiState>(
  AlertsUi.new,
);
