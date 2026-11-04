import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/layout/app_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../alerts/alert_widgets.dart' show alertTime;
import 'agent_widgets.dart';
import 'intercom_widgets.dart';

/// 智能体与对讲（Agent.dc.html / MobileAgent.dc.html）。
///
/// 涉及运动的计划必须展示步骤和安全检查，点「执行计划」后才执行；执行中可
/// 「中止并停止所有设备」（HANDOFF §8.3）。
class AgentPage extends ConsumerStatefulWidget {
  const AgentPage({super.key, this.talk = false});

  /// `/agent?mode=talk`：手机上直接打开「对讲」。
  final bool talk;

  @override
  ConsumerState<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends ConsumerState<AgentPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.talk) {
      Future.microtask(
        () => ref.read(agentUiProvider.notifier).mode(AgentMode.talk),
      );
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send([String? text]) async {
    final t = (text ?? _input.text).trim();
    if (t.isEmpty) return;
    if (text == null) _input.clear();
    setState(() {});
    await ref.read(agentRepositoryProvider).send(t);
  }

  void _edit(String prompt) {
    _input.text = prompt;
    _input.selection = TextSelection.collapsed(offset: prompt.length);
    _focus.requestFocus();
    setState(() {});
  }

  void _voice() => ref
      .read(agentUiProvider.notifier)
      .notify(BannerKind.info, '语音输入需要接入语音识别服务，目前请用文字输入；实时喊话请用「对讲」');

  Future<void> _history() async {
    final picked = await showAppDialog<String?>(
      context: context,
      builder: (context) => const _HistoryDialog(),
    );
    if (picked == null) return;
    final repo = ref.read(agentRepositoryProvider);
    picked == ''
        ? await repo.newConversation()
        : await repo.openConversation(picked);
  }

  @override
  Widget build(BuildContext context) {
    final mobile = LayoutSize.ofContext(context).isMobile;
    return mobile ? _mobile(context) : _desktop(context);
  }

  Widget _notice({
    EdgeInsets padding = const EdgeInsets.only(bottom: AppSpacing.x4),
  }) {
    final n = ref.watch(agentUiProvider).notice;
    return Presence(
      child: n == null
          ? null
          : Padding(
              key: ValueKey(n),
              padding: padding,
              child: AppBanner(kind: n.$1, message: n.$2),
            ),
    );
  }

  Widget _messages({required bool mobile}) {
    final c = context.colors;
    final t = context.type;
    final conv = ref.watch(conversationProvider).value;
    final messages = conv?.messages ?? const <AgentMessage>[];
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Text(
            '描述你想让设备做什么，可以用 @ 指定设备。\n涉及运动的计划会先列出步骤，确认后才执行。',
            textAlign: TextAlign.center,
            style: (mobile ? t.mobileFootnote : t.body).copyWith(
              color: c.secondaryLabel,
              height: 1.6,
            ),
          ),
        ),
      );
    }
    final pad = mobile
        ? EdgeInsets.fromLTRB(
            AppSpacing.x3 + AppSpacing.half,
            AppSpacing.x4,
            AppSpacing.x3 + AppSpacing.half,
            AppSpacing.x4,
          )
        : const EdgeInsets.all(AppSpacing.x4 + AppSpacing.half);
    return Semantics(
      container: true,
      label: '对话',
      child: ListView.separated(
        reverse: true,
        padding: pad,
        itemCount: messages.length,
        separatorBuilder: (_, _) =>
            const SizedBox(height: AppSpacing.x3 + AppSpacing.half),
        itemBuilder: (context, i) => MessageView(
          key: ValueKey(messages[messages.length - 1 - i].id),
          message: messages[messages.length - 1 - i],
          onEdit: _edit,
          mobile: mobile,
        ),
      ),
    );
  }

  // ---- 桌面 ----

  Widget _desktop(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final height = (MediaQuery.sizeOf(context).height - 150).clamp(
      520.0,
      900.0,
    );

    final composer = Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.x3,
        0,
        AppSpacing.x3,
        AppSpacing.x3,
      ),
      padding: const EdgeInsets.all(AppSpacing.x2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.controlBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ContextChips(),
          const SizedBox(height: AppSpacing.x2),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _send(),
                  style: t.headline.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w400,
                  ),
                  cursorColor: c.accent,
                  decoration:
                      InputDecoration.collapsed(
                        hintText: '描述你想让设备做什么，可以用 @ 指定设备',
                        hintStyle: t.headline.copyWith(
                          color: c.secondaryLabel,
                          fontWeight: FontWeight.w400,
                        ),
                      ).copyWith(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.x1,
                          vertical: AppSpacing.x2 - AppSpacing.half,
                        ),
                      ),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              AppIconButton(
                icon: AppIcons.mic,
                label: '语音输入',
                style: IconButtonStyle.circle,
                size: 34,
                onPressed: _voice,
              ),
              const SizedBox(width: AppSpacing.x2),
              AppIconButton(
                icon: AppIcons.arrowUp,
                label: '发送',
                style: IconButtonStyle.primary,
                size: 34,
                onPressed: _input.text.trim().isEmpty ? null : _send,
              ),
            ],
          ),
        ],
      ),
    );

    final chat = Semantics(
      container: true,
      label: '智能体对话',
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _messages(mobile: false)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.x4 + AppSpacing.half,
                0,
                AppSpacing.x4 + AppSpacing.half,
                AppSpacing.x2,
              ),
              child: Wrap(
                spacing: AppSpacing.x2 - AppSpacing.half,
                runSpacing: AppSpacing.x2 - AppSpacing.half,
                children: [
                  for (final s in desktopSuggestions)
                    PillButton(label: s, onTap: () => _send(s)),
                ],
              ),
            ),
            composer,
          ],
        ),
      ),
    );

    return AppPage(
      title: '智能体与对讲',
      subtitle: '用自然语言调度设备 · 涉及运动的计划需要你确认后才执行',
      actions: [
        SecondaryButton(label: '历史对话', onPressed: _history),
        SecondaryButton(
          label: '技能与权限',
          onPressed: () => showSkillsDialog(context),
        ),
      ],
      gap: AppSpacing.x4,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _notice(),
            FlexColumns(
              mainMin: 540,
              trailingWidth: 320,
              main: chat,
              trailing: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  IntercomCard(),
                  SizedBox(height: AppSpacing.x3),
                  TtsCard(),
                  SizedBox(height: AppSpacing.x3),
                  SkillsCard(),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---- 手机 ----

  Widget _mobile(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final ui = ref.watch(agentUiProvider);
    final insets = MediaQuery.paddingOf(context);
    final hasText = _input.text.trim().isNotEmpty;

    final header = Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.x4,
        insets.top + AppSpacing.x2 + AppSpacing.half,
        AppSpacing.x4,
        AppSpacing.x2 + AppSpacing.half,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.separator)),
      ),
      child: SegmentedControl<AgentMode>(
        semanticLabel: '模式',
        expand: true,
        size: SegmentedSize.mobile,
        options: const [
          SegmentOption(AgentMode.agent, '智能体'),
          SegmentOption(AgentMode.talk, '对讲'),
        ],
        value: ui.mode,
        onChanged: ref.read(agentUiProvider.notifier).mode,
      ),
    );

    final composer = Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.x3,
        AppSpacing.x2,
        AppSpacing.x3,
        insets.bottom + AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.separator)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, s) in mobileSuggestions.indexed) ...[
                  if (i > 0)
                    const SizedBox(width: AppSpacing.x2 - AppSpacing.half),
                  PillButton(
                    label: s,
                    height: 30,
                    large: true,
                    onTap: () => _send(s),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3 + AppSpacing.half,
                  ),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(color: c.controlBorder),
                  ),
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _send(),
                    textInputAction: TextInputAction.send,
                    style: t.mobileBody.copyWith(color: c.label),
                    cursorColor: c.accent,
                    decoration: InputDecoration.collapsed(
                      hintText: '告诉设备要做什么',
                      hintStyle: t.mobileBody.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              AppIconButton(
                icon: hasText ? AppIcons.arrowUp : AppIcons.mic,
                label: hasText ? '发送' : '语音输入',
                style: IconButtonStyle.primary,
                size: 38,
                onPressed: hasText ? _send : _voice,
              ),
            ],
          ),
        ],
      ),
    );

    return ColoredBox(
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          _notice(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x4,
              AppSpacing.x3,
              AppSpacing.x4,
              0,
            ),
          ),
          if (ui.mode == AgentMode.agent) ...[
            Expanded(child: _messages(mobile: true)),
            composer,
          ] else
            Expanded(child: _MobileTalk(bottom: insets.bottom)),
        ],
      ),
    );
  }
}

/// 手机「对讲」模式（MobileAgent.dc.html isTalk）。
class _MobileTalk extends ConsumerStatefulWidget {
  const _MobileTalk({required this.bottom});

  final double bottom;

  @override
  ConsumerState<_MobileTalk> createState() => _MobileTalkState();
}

class _MobileTalkState extends ConsumerState<_MobileTalk> {
  String? _preset;

  Future<void> _broadcast(String text) async {
    setState(() => _preset = text);
    final target = currentTarget(ref);
    final n = await ref.read(intercomRepositoryProvider).broadcast(text);
    ref
        .read(agentUiProvider.notifier)
        .notify(
          n == 0 ? BannerKind.warning : BannerKind.success,
          n == 0
              ? '${target?.label ?? '对象'} 没有在线设备，未播报'
              : '已播报「$text」到 ${target?.label}（$n 台）',
        );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final st = ref.watch(intercomStateProvider).value;
    final presets = st?.presets ?? const <String>[];
    final preset = _preset ?? presets.firstOrNull;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.x4,
        AppSpacing.x5,
        AppSpacing.x4,
        widget.bottom + AppSpacing.x5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
            child: Text(
              '对讲对象',
              style: t.mobileFootnote.copyWith(color: c.secondaryLabel),
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          const IntercomTargets(mobile: true),
          const SizedBox(height: AppSpacing.x9),
          const Center(child: TalkButton(size: 180)),
          const SizedBox(height: AppSpacing.x5),
          Text(
            talkHint(ref, mobile: true),
            textAlign: TextAlign.center,
            style: t.mobileFootnote.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppSpacing.x5),
          InsetGroupedSection(
            background: c.fillSecondary,
            children: [
              AppMenu<String>(
                options: [for (final p in presets) MenuOption(p, p)],
                selected: preset,
                onSelected: _broadcast,
                anchor: (context, toggle) =>
                    GroupedListRow(title: '播报预设', value: preset, onTap: toggle),
              ),
              GroupedListRow(
                title: '监听机器人麦克风',
                trailing: AppSwitch(
                  value: st?.listening ?? false,
                  semanticLabel: '监听机器人麦克风',
                  onChanged: (v) =>
                      ref.read(intercomRepositoryProvider).setListening(v),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 历史对话：返回对话 id；'' 表示新对话。
class _HistoryDialog extends ConsumerWidget {
  const _HistoryDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final current = ref.watch(conversationProvider).value;
    final history = ref.watch(conversationHistoryProvider).value ?? const [];
    final now = DateTime.now();
    final all = [?current, ...history.where((h) => h.id != current?.id)];

    return AppAlert<String?>(
      title: '历史对话',
      maxWidth: 420,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final conv in all)
            Pressable(
              onTap: () => Navigator.of(context).pop(conv.id),
              selected: conv.id == current?.id,
              semanticLabel: conv.title,
              focusRadius: AppRadius.md,
              builder: (context, st) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x3,
                  vertical: AppSpacing.x2,
                ),
                decoration: BoxDecoration(
                  color: conv.id == current?.id || st.pressed
                      ? c.rowSelected
                      : null,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            conv.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.cardTitle.copyWith(color: c.label),
                          ),
                          Text(
                            '${alertTime(conv.updatedAt, now)} · ${conv.messages.length} 条消息'
                            '${conv.id == current?.id ? ' · 当前' : ''}',
                            style: t.footnote.copyWith(color: c.secondaryLabel),
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
      actions: const [
        AlertAction<String?>(
          label: '关闭',
          value: null,
          kind: AlertActionKind.cancel,
        ),
        AlertAction<String?>(label: '新对话', value: ''),
      ],
    );
  }
}
