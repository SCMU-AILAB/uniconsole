import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'fleet_widgets.dart';

/// 同步指令（Fleet.dc.html「同步指令」）。
enum SyncCommand {
  stand('全体站立'),
  down('全体趴下'),
  follow('开始跟随'),
  forward('保持队形前进'),
  hello('同步动作 · 打招呼'),
  voice('广播语音');

  const SyncCommand(this.label);

  final String label;

  DeviceCommand build(FleetSession s, {String? text}) => switch (this) {
    stand => const SetModeCommand(MotionMode.stand),
    down => const SetModeCommand(MotionMode.down),
    follow => ActionCommand('follow_leader', {
      'leader': s.leaderId,
      'spacing': s.spacing,
    }),
    forward => ActionCommand('formation_forward', {
      'distance': 3,
      'formation': s.formation.name,
    }),
    hello => const ActionCommand('hello'),
    voice => ActionCommand('speak', {'text': text ?? ''}, false),
  };

  /// 急停中仍可下发的指令（§8.1：只保留趴下；语音不运动）。
  bool get allowedInEstop => this == voice;
}

/// 页面级 UI 状态：提示条、地图缩放、拖动后的编队位置。
class FleetUiState {
  const FleetUiState({this.notice, this.zoom = 1, this.offsets = const {}});

  final (BannerKind, String)? notice;
  final double zoom;

  /// 拖动产生的位置偏移（百分比），切换队形时清空。
  final Map<String, Offset> offsets;

  FleetUiState copyWith({
    (BannerKind, String)? notice,
    bool clearNotice = false,
    double? zoom,
    Map<String, Offset>? offsets,
  }) => FleetUiState(
    notice: clearNotice ? null : notice ?? this.notice,
    zoom: zoom ?? this.zoom,
    offsets: offsets ?? this.offsets,
  );
}

class FleetUi extends Notifier<FleetUiState> {
  FleetUi(this.sessionId);

  final String sessionId;

  static const zoomLevels = [0.8, 1.0, 1.2, 1.4, 1.6];

  @override
  FleetUiState build() => const FleetUiState();

  void notify(BannerKind kind, String text) =>
      state = state.copyWith(notice: (kind, text));

  void dismiss() => state = state.copyWith(clearNotice: true);

  void zoom(int step) {
    final i = zoomLevels.indexOf(state.zoom) + step;
    if (i < 0 || i >= zoomLevels.length) return;
    state = state.copyWith(zoom: zoomLevels[i]);
  }

  void drag(String deviceId, Offset deltaPercent) => state = state.copyWith(
    offsets: {
      ...state.offsets,
      deviceId: (state.offsets[deviceId] ?? Offset.zero) + deltaPercent,
    },
  );

  void resetOffsets() => state = state.copyWith(offsets: const {});
}

final fleetUiProvider = NotifierProvider.autoDispose
    .family<FleetUi, FleetUiState, String>(FleetUi.new);

/// 编队位置（地图百分比坐标），与设计稿 pos(i) 一致；领队为第 0 个。
Offset formationPosition(Formation f, int i, int n) {
  switch (f) {
    case Formation.line:
      return Offset(50 + (i - (n - 1) / 2) * 12, 50);
    case Formation.column:
      return Offset(50, 24 + i * 15.0);
    case Formation.grid:
      return Offset(43 + (i % 2) * 14.0, 34 + (i ~/ 2) * 20.0);
    case Formation.v:
      final k = (i / 2).ceil();
      final side = i.isOdd ? -1 : 1;
      return Offset(50 + side * k * 11.0, 26 + k * 17.0);
  }
}

/// 页面动作，桌面与移动布局共用。
class FleetActions {
  FleetActions(this.ref, this.sessionId);

  final WidgetRef ref;
  final String sessionId;

  FleetUi get _ui => ref.read(fleetUiProvider(sessionId).notifier);

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on FleetException catch (e) {
      _ui.notify(BannerKind.warning, e.message);
    }
  }

  Future<void> toggle(String deviceId, bool joined) => _guard(
    () => ref
        .read(fleetRepositoryProvider)
        .setParticipant(sessionId, deviceId, joined: joined),
  );

  Future<void> setFormation(Formation f) async {
    _ui.resetOffsets();
    await _guard(
      () => ref.read(fleetRepositoryProvider).setFormation(sessionId, f),
    );
  }

  Future<void> send(BuildContext context, SyncCommand cmd) async {
    final s = ref.read(fleetSessionProvider(sessionId));
    if (s == null) return;
    String? text;
    if (cmd == SyncCommand.voice) {
      text = await promptText(
        context,
        title: '广播语音',
        message: '${s.deviceIds.length} 台设备将同时播报这段文字。',
        hint: '例如：欢迎来到展厅',
        confirmLabel: '播报',
      );
      if (text == null) return;
    }
    await _guard(() async {
      final r = await ref
          .read(fleetRepositoryProvider)
          .send(sessionId, cmd.build(s, text: text), label: cmd.label);
      final failed = r.acks.where((a) => !a.ok).length;
      if (failed > 0) {
        _ui.notify(BannerKind.warning, '${cmd.label}：$failed 台设备未执行，详见回执');
      } else {
        _ui.dismiss();
      }
    });
  }

  /// 全体急停 / 解除：任何人都可以触发（§8.1），不需要会话权限。
  Future<void> toggleEstop() async {
    final s = ref.read(fleetSessionProvider(sessionId));
    if (s == null || s.deviceIds.isEmpty) return;
    final repo = ref.read(controlRepositoryProvider);
    final engaged = allEstopped(ref, s);
    await Future.wait([
      for (final id in s.deviceIds) repo.setEstop(id, active: !engaged),
    ]);
  }

  Future<void> savePreset(BuildContext context) async {
    final s = ref.read(fleetSessionProvider(sessionId));
    if (s == null) return;
    final name = await promptText(
      context,
      title: '保存为预设',
      message:
          '保存当前 ${s.deviceIds.length} 台设备的组合与${s.formation.label}队形，之后可从侧边栏一键发起。',
      hint: '预设名称',
      initial: s.title,
      confirmLabel: '保存',
    );
    if (name == null) return;
    await _guard(() async {
      await ref.read(fleetRepositoryProvider).savePreset(sessionId, name);
      _ui.notify(BannerKind.success, '已保存为预设「$name」');
    });
  }

  Future<void> end(BuildContext context) async {
    final s = ref.read(fleetSessionProvider(sessionId));
    if (s == null) return;
    final ok = await confirmAction(
      context,
      title: '结束${s.name}？',
      message: '${s.deviceIds.length} 台设备会停止当前动作，并释放会话持有的控制权。',
      confirmLabel: '结束会话',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await _guard(() => ref.read(fleetRepositoryProvider).end(sessionId));
    if (context.mounted) context.go(Routes.fleetHome);
  }
}

bool allEstopped(WidgetRef ref, FleetSession s) =>
    s.deviceIds.isNotEmpty &&
    s.deviceIds.every((id) => ref.read(estopProvider(id)).value ?? false);

/// 多机联调（Fleet.dc.html）。没有会话时显示预设列表，可一键发起。
class FleetPage extends ConsumerWidget {
  const FleetPage({super.key, this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(fleetSessionsProvider);
    final s = sessionId == null
        ? null
        : ref.watch(fleetSessionProvider(sessionId!));
    if (s == null) {
      if (!sessions.hasValue) return const SizedBox.shrink();
      return const NoSessionPage();
    }
    return _SessionPage(session: s);
  }
}

class _SessionPage extends ConsumerStatefulWidget {
  const _SessionPage({required this.session});

  final FleetSession session;

  @override
  ConsumerState<_SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends ConsumerState<_SessionPage> {
  final _focus = FocusNode(debugLabel: 'fleet');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final actions = FleetActions(ref, s.id);
    final ui = ref.watch(fleetUiProvider(s.id));
    final canOperate = ref.watch(canOperateSessionProvider(s.id));
    final initiator = ref.watch(memberNameProvider(s.initiatorId)) ?? '';
    final now = ref.watch(clockProvider).value ?? DateTime.now();
    final minutes = now.difference(s.startedAt).inMinutes;
    final estops = [
      for (final id in s.deviceIds)
        if (ref.watch(estopProvider(id)).value ?? false) id,
    ];
    final engaged =
        s.deviceIds.isNotEmpty && estops.length == s.deviceIds.length;
    final mobile = LayoutSize.ofContext(context).isMobile;

    final estopButton = EmergencyStopButton(
      label: '全体急停',
      releaseLabel: '解除急停',
      engaged: engaged,
      compact: mobile,
      onPressed: s.deviceIds.isEmpty ? null : actions.toggleEstop,
    );

    final banners = Presence(
      child: !canOperate
          ? Padding(
              key: const ValueKey('readonly'),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(
                kind: BannerKind.info,
                message: '只有发起人 $initiator 和平台管理员可以操作此会话 · 当前为只读观看',
              ),
            )
          : s.paused
          ? const Padding(
              key: ValueKey('paused'),
              padding: EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(
                kind: BannerKind.emergency,
                message: '全局急停中 · 会话已暂停，解除后才能下发指令',
              ),
            )
          : estops.isNotEmpty
          ? Padding(
              key: const ValueKey('estop'),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(
                kind: BannerKind.emergency,
                message: '${estops.length} 台设备急停中 · 运动指令已禁用',
              ),
            )
          : ui.notice != null
          ? Padding(
              key: ValueKey(ui.notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: ui.notice!.$1, message: ui.notice!.$2),
            )
          : null,
    );

    final map = FormationMap(
      session: s,
      canOperate: canOperate,
      actions: actions,
    );
    final commands = SyncCommandsCard(
      session: s,
      canOperate: canOperate && !s.paused,
      estop: estops.isNotEmpty,
      actions: actions,
    );
    final timeline = ChoreographyCard(session: s);
    final participants = ParticipantsCard(
      session: s,
      canOperate: canOperate,
      actions: actions,
    );
    final status = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReceiptCard(session: s),
        const SizedBox(height: AppSpacing.x3),
        SessionSettingsCard(session: s),
        BlockedNotice(session: s),
      ],
    );

    return Focus(
      focusNode: _focus,
      autofocus: true,
      // 空格 = 全体急停（§8.1）。
      onKeyEvent: (_, e) {
        if (e.logicalKey != LogicalKeyboardKey.space) {
          return KeyEventResult.ignored;
        }
        if (e is KeyDownEvent) actions.toggleEstop();
        return KeyEventResult.handled;
      },
      child: AppPage(
        title: '${s.name} · ${s.title}',
        mobileTitle: '联调 #${s.number}',
        subtitle: '发起人 $initiator · 已运行 ${math.max(minutes, 0)} 分钟',
        titleAccessory: _SyncPill(session: s),
        largeTitle: false,
        actions: [
          SecondaryButton(
            label: '保存为预设',
            onPressed: canOperate && s.deviceIds.isNotEmpty
                ? () => actions.savePreset(context)
                : null,
          ),
          SecondaryButton(
            label: '结束会话',
            onPressed: canOperate ? () => actions.end(context) : null,
          ),
          estopButton,
        ],
        mobileActions: [estopButton],
        gap: AppSpacing.x4,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 移动端没有工具栏，同步状态放在内容顶部。
              if (mobile) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: _SyncPill(session: s),
                ),
                const SizedBox(height: AppSpacing.x3),
              ],
              banners,
              FlexColumns(
                leading: participants,
                leadingWidth: 260,
                trailing: status,
                trailingWidth: 260,
                mainMin: 520,
                main: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    map,
                    const SizedBox(height: AppSpacing.x4),
                    commands,
                    const SizedBox(height: AppSpacing.x4),
                    timeline,
                  ],
                ),
              ),
              if (mobile) ...[
                const SizedBox(height: AppSpacing.x4),
                Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: '保存为预设',
                        size: ButtonSize.large,
                        expand: true,
                        onPressed: canOperate && s.deviceIds.isNotEmpty
                            ? () => actions.savePreset(context)
                            : null,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Expanded(
                      child: DestructiveButton(
                        label: '结束会话',
                        size: ButtonSize.large,
                        expand: true,
                        onPressed: canOperate
                            ? () => actions.end(context)
                            : null,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 标题旁的同步状态胶囊。
class _SyncPill extends StatelessWidget {
  const _SyncPill({required this.session});

  final FleetSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s.paused) {
      return const StatusPill(tone: StatusTone.critical, label: '已暂停 · 全局急停');
    }
    if (s.deviceIds.isEmpty) {
      return const StatusPill(tone: StatusTone.offline, label: '未选择设备');
    }
    return StatusPill(
      tone: StatusTone.online,
      label:
          '${s.deviceIds.length} 台已同步 · 时钟偏差 ≤ ${s.clockSkew.inMilliseconds} ms',
    );
  }
}
