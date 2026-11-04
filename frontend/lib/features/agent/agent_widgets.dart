import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

// ---- 页面状态 ----

enum AgentMode { agent, talk }

class AgentUiState {
  const AgentUiState({this.mode = AgentMode.agent, this.notice});

  /// 手机上的「智能体 / 对讲」分段。
  final AgentMode mode;
  final (BannerKind, String)? notice;
}

class AgentUi extends Notifier<AgentUiState> {
  @override
  AgentUiState build() => const AgentUiState();

  void mode(AgentMode m) => state = AgentUiState(mode: m, notice: state.notice);

  void notify(BannerKind kind, String text) =>
      state = AgentUiState(mode: state.mode, notice: (kind, text));

  void dismiss() => state = AgentUiState(mode: state.mode);
}

final agentUiProvider = NotifierProvider<AgentUi, AgentUiState>(AgentUi.new);

/// 桌面与手机的建议指令（Agent.dc.html suggest / MobileAgent 底部芯片）。
const desktopSuggestions = [
  '所有设备回桩充电',
  'Alpha 现在看到了什么？',
  '生成今天的巡检报告',
  '找出电量最高的空闲设备',
];
const mobileSuggestions = ['Alpha 在看什么？', '今日巡检报告', '谁在控制 Bravo'];

// ---- 小部件 ----

/// 胶囊按钮（建议指令、对讲对象）。
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.height = 28,
    this.large = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final double height;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      focusRadius: height / 2,
      builder: (context, st) => AnimatedContainer(
        duration: AppMotion.fade(pressed: st.pressed),
        curve: AppMotion.highlightCurve,
        height: height,
        padding: EdgeInsets.symmetric(
          horizontal: large ? AppSpacing.x4 : AppSpacing.x3,
        ),
        decoration: BoxDecoration(
          color: selected
              ? c.accentFill
              : st.pressed
              ? c.fillSecondary
              : c.surface,
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: selected ? c.accentFill : c.controlBorder),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            maxLines: 1,
            style: (large ? t.mobileFootnote : t.subhead).copyWith(
              color: selected ? c.onAccent : c.label,
              fontWeight: selected && large ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 对话气泡：用户在右（强调色），智能体在左（浅灰）。
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message, this.mobile = false});

  final AgentMessage message;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final user = message.role == AgentRole.user;
    final r = mobile ? AppRadius.bubbleMobile : AppRadius.bubble;
    const tail = Radius.circular(AppRadius.bubbleTail);
    final style = (mobile ? t.mobileBody : t.body).copyWith(
      color: user ? c.onAccent : c.label,
      height: 1.5,
    );
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: user ? (mobile ? 0.8 : 0.7) : (mobile ? 0.88 : 0.86),
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Align(
          alignment: user ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4 - AppSpacing.half,
              vertical: AppSpacing.x2 + AppSpacing.half,
            ),
            decoration: BoxDecoration(
              color: user ? c.accentFill : c.fillSecondary,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(r),
                topRight: Radius.circular(r),
                bottomLeft: user ? Radius.circular(r) : tail,
                bottomRight: user ? tail : Radius.circular(r),
              ),
            ),
            child: SelectableText(
              message.text,
              style: style,
              semanticsLabel: '${user ? '我' : '智能体'}：${message.text}',
            ),
          ),
        ),
      ),
    );
  }
}

/// 智能体发回的照片 / 实时画面（视频流接入前为占位）。
class AgentPhotoView extends StatelessWidget {
  const AgentPhotoView({super.key, required this.photo});

  final AgentPhoto photo;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VideoPanel(
              placeholder: '[照片 · ${photo.caption}]',
              showCrosshair: false,
              semanticLabel: photo.caption,
            ),
            const SizedBox(height: AppSpacing.x1),
            Text(
              photo.caption,
              style: t.footnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// 计划状态标签：等待确认（橙）、执行中（蓝）、已完成（绿）、已中止（红）、已取消（灰）。
Widget planStateTag(AgentPlan p, {bool large = true}) {
  final tone = switch (p.state) {
    PlanState.pending => StatusTone.warning,
    PlanState.running => StatusTone.busy,
    PlanState.done => StatusTone.online,
    PlanState.aborted => StatusTone.critical,
    PlanState.cancelled => StatusTone.offline,
  };
  final label = p.state == PlanState.running && p.current != null
      ? '执行中 · 第 ${p.current! + 1}/${p.steps.length} 步'
      : p.state.label;
  return Tag(label: label, tone: tone, large: large);
}

/// 计划操作回调。
class PlanCallbacks {
  const PlanCallbacks({
    required this.run,
    required this.edit,
    required this.cancel,
    required this.abort,
  });

  final VoidCallback run;
  final VoidCallback edit;
  final VoidCallback cancel;
  final VoidCallback abort;
}

/// 执行计划卡片（Agent.dc.html）：步骤、技能调用、安全检查、确认 / 中止。
class PlanCard extends StatelessWidget {
  const PlanCard({super.key, required this.plan, required this.actions});

  final AgentPlan plan;
  final PlanCallbacks actions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;

    Widget mark(AgentStep step, int i) {
      final (bg, fg, text) = switch (step.state) {
        AgentStepState.done => (s.online.dot, c.onAccent, '✓'),
        AgentStepState.running => (c.accentFill, c.onAccent, '${i + 1}'),
        AgentStepState.skipped => (c.separatorSubtle, c.secondaryLabel, '–'),
        AgentStepState.waiting => (
          c.separatorSubtle,
          c.tertiaryLabel,
          '${i + 1}',
        ),
      };
      return Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Text(
          text,
          style: t.captionStrong.copyWith(
            color: fg,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    final steps = [
      for (final (i, step) in plan.steps.indexed)
        Semantics(
          container: true,
          label:
              '第 ${i + 1} 步，${step.who}：${step.text}，${_stepState(step.state)}',
          excludeSemantics: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mark(step, i),
              const SizedBox(width: AppSpacing.x3 - AppSpacing.half),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                right: AppSpacing.x2,
                              ),
                              child: Tag(
                                label: step.who,
                                strong: true,
                                large: true,
                              ),
                            ),
                          ),
                          TextSpan(text: step.text),
                        ],
                      ),
                      style: t.body.copyWith(
                        color: step.state == AgentStepState.skipped
                            ? c.secondaryLabel
                            : c.label,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.half),
                    Text(
                      step.call,
                      style: t.mono.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Text(
                step.eta ?? '—',
                style: t.footnote.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
        ),
    ];

    final checks = plan.checks.isEmpty
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2 + AppSpacing.half,
            ),
            decoration: BoxDecoration(
              color: c.windowBackground,
              borderRadius: BorderRadius.circular(AppRadius.group),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, ch) in plan.checks.indexed) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.x1),
                  Text(
                    '${ch.ok ? '✓' : '!'} ${ch.text}',
                    style: t.subhead.copyWith(
                      color: ch.ok ? s.online.fg : s.warning.fg,
                    ),
                  ),
                ],
              ],
            ),
          );

    final footer = switch (plan.state) {
      PlanState.pending => Wrap(
        spacing: AppSpacing.x2,
        runSpacing: AppSpacing.x2,
        children: [
          PrimaryButton(
            label: '执行计划',
            size: ButtonSize.regular,
            onPressed: actions.run,
          ),
          SecondaryButton(
            label: '修改',
            size: ButtonSize.regular,
            onPressed: actions.edit,
          ),
          SecondaryButton(
            label: '取消',
            size: ButtonSize.regular,
            onPressed: actions.cancel,
          ),
        ],
      ),
      PlanState.running => Wrap(
        spacing: AppSpacing.x2,
        runSpacing: AppSpacing.x2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          DestructiveButton(
            label: '中止并停止所有设备',
            size: ButtonSize.regular,
            filled: true,
            onPressed: actions.abort,
          ),
          if (plan.progress != null)
            Text(
              plan.progress!,
              style: t.subhead.copyWith(color: c.secondaryLabel),
            ),
        ],
      ),
      _ when plan.progress != null => Text(
        plan.progress!,
        style: t.subhead.copyWith(color: c.secondaryLabel),
      ),
      _ => null,
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.x4 - AppSpacing.half),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    plan.title,
                    style: t.cardTitle.copyWith(color: c.label),
                  ),
                ),
              ),
              planStateTag(plan),
            ],
          ),
          for (final w in [...steps, ?checks, ?footer]) ...[
            const SizedBox(height: AppSpacing.x2 + AppSpacing.half),
            w,
          ],
        ],
      ),
    );
  }

  static String _stepState(AgentStepState s) => switch (s) {
    AgentStepState.waiting => '等待',
    AgentStepState.running => '执行中',
    AgentStepState.done => '已完成',
    AgentStepState.skipped => '已跳过',
  };
}

/// 手机计划卡片（MobileAgent.dc.html）：每台设备一行 + 确认执行。
class MobilePlanCard extends ConsumerWidget {
  const MobilePlanCard({super.key, required this.plan, required this.actions});

  final AgentPlan plan;
  final PlanCallbacks actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;

    Color dot(AgentStep step) {
      final alert =
          step.deviceId != null &&
          ref.watch(deviceProvider(step.deviceId!))?.status ==
              DeviceStatus.alert;
      return switch (step.state) {
        AgentStepState.done => s.online.dot,
        AgentStepState.running => c.accent,
        AgentStepState.skipped => c.decorativeGray,
        AgentStepState.waiting when alert => s.warning.dot,
        AgentStepState.waiting => c.decorativeGrayLight,
      };
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.x4 - AppSpacing.half),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.bubble),
        border: Border.all(color: c.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.title,
                  style: t.mobileBody.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              planStateTag(plan),
            ],
          ),
          for (final step in plan.steps) ...[
            const SizedBox(height: AppSpacing.x2 + AppSpacing.half),
            Semantics(
              container: true,
              label: '${step.who}，${step.summary ?? step.text}',
              excludeSemantics: true,
              child: Row(
                children: [
                  StatusDot(StatusTone.offline, size: 8, color: dot(step)),
                  const SizedBox(width: AppSpacing.x2 + AppSpacing.half),
                  Text(
                    step.who,
                    style: t.headline.copyWith(
                      color: c.label,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x3),
                  Expanded(
                    child: Text(
                      step.summary ?? step.text,
                      textAlign: TextAlign.end,
                      style: t.mobileFootnote.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (plan.state == PlanState.pending) ...[
            const SizedBox(height: AppSpacing.x3),
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    label: '确认执行',
                    size: ButtonSize.large,
                    expand: true,
                    onPressed: actions.run,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                SecondaryButton(
                  label: '修改',
                  size: ButtonSize.large,
                  onPressed: actions.edit,
                ),
              ],
            ),
          ] else if (plan.state == PlanState.running) ...[
            const SizedBox(height: AppSpacing.x3),
            DestructiveButton(
              label: '中止并停止所有设备',
              size: ButtonSize.large,
              filled: true,
              expand: true,
              onPressed: actions.abort,
            ),
          ] else if (plan.progress != null) ...[
            const SizedBox(height: AppSpacing.x2),
            Text(
              plan.progress!,
              style: t.mobileFootnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// 发送指令与计划操作；[edit] 把原指令放回输入框。
PlanCallbacks planCallbacks(
  WidgetRef ref,
  AgentPlan plan, {
  required ValueChanged<String> edit,
}) {
  final repo = ref.read(agentRepositoryProvider);
  return PlanCallbacks(
    run: () => repo.runPlan(plan.id),
    abort: () => repo.abortPlan(plan.id),
    cancel: () => repo.cancelPlan(plan.id),
    edit: () {
      final conv = ref.read(conversationProvider).value;
      final i = conv?.messages.indexWhere((m) => m.plan?.id == plan.id) ?? -1;
      final prompt = i > 0 ? conv!.messages[i - 1].text : '';
      repo.cancelPlan(plan.id);
      edit(prompt);
    },
  );
}

/// 一条消息：气泡 + 计划 / 照片。
class MessageView extends ConsumerWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.onEdit,
    this.mobile = false,
  });

  final AgentMessage message;
  final ValueChanged<String> onEdit;
  final bool mobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = message.plan;
    final photo = message.photo;
    final children = [
      ChatBubble(message: message, mobile: mobile),
      if (plan != null)
        mobile
            ? MobilePlanCard(
                plan: plan,
                actions: planCallbacks(ref, plan, edit: onEdit),
              )
            : FractionallySizedBox(
                widthFactor: 0.86,
                alignment: Alignment.centerLeft,
                child: PlanCard(
                  plan: plan,
                  actions: planCallbacks(ref, plan, edit: onEdit),
                ),
              ),
      if (photo != null) AgentPhotoView(photo: photo),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, w) in children.indexed) ...[
          if (i > 0) const SizedBox(height: AppSpacing.x2 + AppSpacing.half),
          w,
        ],
      ],
    );
  }
}

/// 输入框上方的上下文标签（@设备、地图），可移除，「＋」添加。
class ContextChips extends ConsumerWidget {
  const ContextChips({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;
    final conv = ref.watch(conversationProvider).value;
    if (conv == null) return const SizedBox.shrink();
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final maps = ref.watch(mapsProvider).value ?? const <SiteMap>[];
    final repo = ref.read(agentRepositoryProvider);
    final map = maps.where((m) => m.id == conv.mapId).firstOrNull;

    Widget chip(
      String label, {
      required bool device,
      required VoidCallback remove,
    }) {
      final fg = device ? s.busy.fg : c.tertiaryLabel;
      return Pressable(
        onTap: remove,
        semanticLabel: '移除 $label',
        tooltip: '移除',
        focusRadius: AppRadius.xs,
        builder: (context, st) => Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
          decoration: BoxDecoration(
            color: device ? s.busy.bg : c.fillSecondary,
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: t.subhead.copyWith(color: fg)),
              if (st.hovered || st.focused) ...[
                const SizedBox(width: AppSpacing.x1),
                AppIcon(AppIcons.close, size: 11, color: fg),
              ],
            ],
          ),
        ),
      );
    }

    final options = [
      for (final d in devices)
        if (!conv.deviceIds.contains(d.id))
          MenuOption('d:${d.id}', '@${d.name}'),
      for (final m in maps)
        if (m.id != conv.mapId) MenuOption('m:${m.id}', '地图：${m.name}'),
    ];

    return Wrap(
      spacing: AppSpacing.x2 - AppSpacing.half,
      runSpacing: AppSpacing.x2 - AppSpacing.half,
      children: [
        for (final id in conv.deviceIds)
          chip(
            '@${devices.where((d) => d.id == id).firstOrNull?.name ?? id}',
            device: true,
            remove: () => repo.setContext(
              deviceIds: [
                for (final x in conv.deviceIds)
                  if (x != id) x,
              ],
            ),
          ),
        if (map != null)
          chip(
            '地图：${map.name}',
            device: false,
            remove: () => repo.setContext(mapId: ''),
          ),
        AppMenu<String>(
          options: options,
          onSelected: (v) => v.startsWith('d:')
              ? repo.setContext(deviceIds: [...conv.deviceIds, v.substring(2)])
              : repo.setContext(mapId: v.substring(2)),
          anchor: (context, toggle) => AppIconButton(
            icon: AppIcons.plus,
            label: '添加设备或地图',
            size: 24,
            iconSize: 13,
            onPressed: options.isEmpty ? null : toggle,
          ),
        ),
      ],
    );
  }
}
