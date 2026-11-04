import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data_ops.dart';
import 'mock_repositories.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

/// 告警中心（API `/alerts`、`/alert-rules`）。
///
/// 处理流程：未处理 →（确认 / 指派）处理中 →（填写备注）已关闭；已关闭可重新打开。
/// 每一步都写入处理时间线。
class MockAlertRepository implements AlertRepository {
  MockAlertRepository({required this.world});

  final MockWorld world;

  final _alerts = MockStore<List<Alert>>([
    for (final a in MockOpsData.alerts)
      Alert(
        id: a.id,
        severity: a.severity,
        state: a.state,
        title: a.title,
        deviceId: a.deviceId,
        metric: a.metric,
        createdAt: MockSeed.rebase(a.createdAt),
        location: a.location,
        assigneeId: a.assigneeId,
        recordingId: a.recordingId,
        events: [
          for (final e in a.events)
            AlertEvent(
              at: MockSeed.rebase(e.at),
              message: e.message,
              tone: e.tone,
            ),
        ],
      ),
  ]);
  final _rules = MockStore<List<AlertRule>>(MockOpsData.rules);
  final _channels = MockStore<List<NotifyChannel>>(MockOpsData.channels);
  final _roster = MockStore(MockOpsData.roster);
  var _ruleSeq = 1;

  List<Alert> get alerts => _alerts.value;

  Alert? alert(String id) => _alerts.value.where((a) => a.id == id).firstOrNull;

  Alert _require(String id) {
    final a = alert(id);
    if (a == null) throw StateError('告警 $id 不存在');
    return a;
  }

  void _update(
    String id,
    Alert Function(Alert) f,
    String message,
    EventTone tone,
  ) {
    final a = _require(id);
    final next = f(a);
    _alerts.value = [
      for (final x in _alerts.value)
        x.id == id
            ? next.copyWith(
                events: [
                  ...next.events,
                  AlertEvent(at: DateTime.now(), message: message, tone: tone),
                ],
              )
            : x,
    ];
  }

  String get _me => world.me.name;

  @override
  Stream<List<Alert>> watchAlerts() => _alerts.watch();

  @override
  Future<AlertHistory> history(String alertId) async {
    final peak = MockOpsData.alertPeaks[alertId] ?? 40;
    return AlertHistory(values: MockOpsData.alertSeries(peak), threshold: 70);
  }

  @override
  Future<void> acknowledge(String alertId) async {
    final a = _require(alertId);
    if (a.state != AlertState.open) return;
    _update(
      alertId,
      (a) =>
          a.copyWith(state: AlertState.doing, assigneeId: world.currentUserId),
      '$_me 已确认，状态变为处理中',
      EventTone.info,
    );
    _audit(alertId, '确认告警');
  }

  void _audit(String alertId, String verb, [String suffix = '']) {
    final a = _require(alertId);
    world.log(
      '$verb「${world.deviceName(a.deviceId)} ${a.title}」$suffix',
      kind: AuditKind.alert,
      target: alertId,
    );
  }

  @override
  Future<void> assign(String alertId, String memberId) async {
    _update(
      alertId,
      (a) => a.copyWith(
        state: a.state == AlertState.closed ? null : AlertState.doing,
        assigneeId: memberId,
      ),
      '$_me 指派给 ${world.nameOf(memberId)}',
      EventTone.info,
    );
    _audit(alertId, '将告警', '指派给 ${world.nameOf(memberId)}');
  }

  @override
  Future<void> close(String alertId, {required String note}) async {
    final text = note.trim();
    if (text.isEmpty) throw ArgumentError('关闭告警必须填写处理备注');
    _update(
      alertId,
      (a) => a.copyWith(state: AlertState.closed, clearSilence: true),
      '$_me 关闭：$text',
      EventTone.neutral,
    );
    _audit(alertId, '关闭告警');
  }

  @override
  Future<void> reopen(String alertId) async {
    _update(
      alertId,
      (a) => a.copyWith(state: AlertState.open),
      '$_me 重新打开',
      EventTone.warning,
    );
    _audit(alertId, '重新打开告警');
  }

  @override
  Future<void> addNote(String alertId, String message) async {
    final text = message.trim();
    if (text.isEmpty) return;
    _update(alertId, (a) => a, '$_me 备注：$text', EventTone.neutral);
  }

  @override
  Future<void> silence(String alertId, Duration? duration) async {
    if (duration == null) {
      _update(
        alertId,
        (a) => a.copyWith(clearSilence: true),
        '$_me 取消静默',
        EventTone.neutral,
      );
      return;
    }
    final until = DateTime.now().add(duration);
    final hm =
        '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}';
    _update(
      alertId,
      (a) => a.copyWith(silencedUntil: until),
      '$_me 静默 ${duration.inMinutes} 分钟（至 $hm）',
      EventTone.neutral,
    );
  }

  @override
  Future<void> remoteDown(String alertId) async {
    final a = _require(alertId);
    await world.fleet.setEstop(a.deviceId, active: true, reason: '远程趴下');
    _update(alertId, (a) => a, '$_me 远程趴下（急停通道）', EventTone.critical);
    _audit(alertId, '处理告警', '：远程趴下');
  }

  @override
  Stream<List<AlertRule>> watchRules() => _rules.watch();

  @override
  Future<void> setRuleEnabled(String ruleId, {required bool enabled}) async {
    _rules.value = [
      for (final r in _rules.value)
        r.id == ruleId ? r.copyWith(enabled: enabled) : r,
    ];
    final r = _rules.value.where((r) => r.id == ruleId).firstOrNull;
    if (r != null) world.log('${enabled ? '启用' : '停用'}告警规则「${r.name}」');
  }

  @override
  Future<String> addRule({
    required String name,
    required AlertMetric metric,
    required String op,
    required double threshold,
    required Duration duration,
    required AlertSeverity severity,
    String? autoAction,
  }) async {
    final v = threshold == threshold.roundToDouble()
        ? threshold.toStringAsFixed(0)
        : threshold.toString();
    final unit = switch (metric.unit) {
      '' => '',
      '%' => '%',
      final u => ' $u',
    };
    final hold = duration == Duration.zero ? '' : ' 持续 ${duration.inSeconds} 秒';
    final rule = AlertRule(
      id: 'rule-${_ruleSeq++}',
      name: name.trim(),
      condition: '${metric.label} $op $v$unit$hold',
      severity: severity,
      autoAction: autoAction,
    );
    _rules.value = [..._rules.value, rule];
    return rule.id;
  }

  @override
  Stream<List<NotifyChannel>> watchChannels() => _channels.watch();

  @override
  Stream<OnCallRoster> watchRoster() => _roster.watch();
}
