import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../alerts/alert_widgets.dart' show watchNowOf;
import 'agent_widgets.dart';

String _mmss(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

IntercomTarget? currentTarget(WidgetRef ref) {
  final st = ref.watch(intercomStateProvider).value;
  final targets = ref.watch(intercomTargetsProvider).value ?? const [];
  return targets.where((t) => t.id == st?.targetId).firstOrNull;
}

/// 对讲对象是否有在线设备。
bool targetReachable(WidgetRef ref, IntercomTarget? t) =>
    t != null &&
    t.deviceIds.any(
      (id) => ref.watch(deviceProvider(id))?.status.isOnline ?? false,
    );

/// 「00:04 · 正在通过 Alpha 的扬声器播放」/「对象：Alpha · 延迟约 120 ms」。
String talkHint(WidgetRef ref, {bool mobile = false}) {
  final st = ref.watch(intercomStateProvider).value;
  final t = currentTarget(ref);
  if (st == null || t == null) return '';
  if (!targetReachable(ref, t)) return '${t.label} 离线，无法对讲';
  if (st.talking) {
    final d = watchNowOf(ref).difference(st.talkingSince!);
    final time = _mmss(d.isNegative ? Duration.zero : d);
    return mobile
        ? '$time · ${t.label} 的扬声器正在播放'
        : '$time · 正在通过 ${t.label} 的扬声器播放';
  }
  return mobile
      ? '${t.label} · 延迟约 ${st.latencyMs} ms'
      : '对象：${t.label} · 延迟约 ${st.latencyMs} ms';
}

/// 对讲对象选择（胶囊组）。
class IntercomTargets extends ConsumerWidget {
  const IntercomTargets({super.key, this.mobile = false});

  final bool mobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = ref.watch(intercomTargetsProvider).value ?? const [];
    final st = ref.watch(intercomStateProvider).value;
    return Semantics(
      container: true,
      label: '对讲对象',
      child: Wrap(
        spacing: AppSpacing.x2 - (mobile ? 0 : AppSpacing.half),
        runSpacing: AppSpacing.x2 - (mobile ? 0 : AppSpacing.half),
        children: [
          for (final t in targets)
            PillButton(
              label: t.label,
              selected: t.id == st?.targetId,
              height: mobile ? 36 : 28,
              large: mobile,
              onTap: () => ref.read(intercomRepositoryProvider).setTarget(t.id),
            ),
        ],
      ),
    );
  }
}

/// 按住说话（Agent.dc.html 120 / MobileAgent 180）：按下开始、松开结束；
/// 键盘与读屏用空格 / 回车切换。讲话时红色并带两圈光晕。
class TalkButton extends ConsumerStatefulWidget {
  const TalkButton({super.key, this.size = 120});

  final double size;

  @override
  ConsumerState<TalkButton> createState() => _TalkButtonState();
}

class _TalkButtonState extends ConsumerState<TalkButton> {
  var _focused = false;

  void _start() => ref.read(intercomRepositoryProvider).startTalking();
  void _stop() => ref.read(intercomRepositoryProvider).stopTalking();

  void _toggle() {
    final talking = ref.read(intercomStateProvider).value?.talking ?? false;
    talking ? _stop() : _start();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final s = context.status;
    final talking = ref.watch(intercomStateProvider).value?.talking ?? false;
    final enabled = targetReachable(ref, currentTarget(ref));
    final size = widget.size;
    final big = size > 150;
    final ring = big ? 14.0 : 10.0;
    final color = !enabled
        ? c.decorativeGray
        : talking
        ? s.critical.dot
        : c.accentFill;

    return Semantics(
      button: true,
      enabled: enabled,
      toggled: talking,
      label: talking ? '正在讲话，松开结束' : '按住说话',
      onTap: enabled ? _toggle : null,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTapDown: enabled ? (_) => _start() : null,
          onTapUp: enabled ? (_) => _stop() : null,
          onTapCancel: enabled ? _stop : null,
          child: AnimatedContainer(
            duration: AppMotion.highlight * 2,
            curve: AppMotion.highlightCurve,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: _focused
                  ? Border.all(color: c.accentRing, width: 3)
                  : null,
              boxShadow: talking
                  ? [
                      BoxShadow(
                        color: s.critical.dot.withValues(alpha: 0.18),
                        spreadRadius: ring,
                      ),
                      BoxShadow(
                        color: s.critical.dot.withValues(alpha: 0.08),
                        spreadRadius: ring * 2,
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: c.shadow.withValues(alpha: big ? 0.18 : 0.15),
                        blurRadius: big ? 20 : 14,
                        offset: Offset(0, big ? 6 : 4),
                      ),
                    ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(AppIcons.mic, size: big ? 44 : 32, color: c.onAccent),
                SizedBox(
                  height: big ? AppSpacing.x2 : AppSpacing.x2 - AppSpacing.half,
                ),
                Text(
                  talking ? '正在讲话' : '按住说话',
                  style: (big ? t.mobileBodyLarge : t.headline).copyWith(
                    color: c.onAccent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 实时对讲卡片（桌面）。
class IntercomCard extends ConsumerWidget {
  const IntercomCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final st = ref.watch(intercomStateProvider).value;
    return AppCard(
      title: '实时对讲',
      semanticLabel: '对讲',
      gap: AppSpacing.x4 - AppSpacing.half,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const IntercomTargets(),
          const SizedBox(height: AppSpacing.x4 - AppSpacing.half),
          const Center(child: TalkButton()),
          const SizedBox(height: AppSpacing.x4 - AppSpacing.half),
          Text(
            talkHint(ref),
            textAlign: TextAlign.center,
            style: t.subhead.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppSpacing.x3),
          Container(height: 1, color: c.separatorSubtle),
          const SizedBox(height: AppSpacing.x2),
          Row(
            children: [
              Expanded(
                child: Text('监听机器人麦克风', style: t.body.copyWith(color: c.label)),
              ),
              if (st?.listening ?? false) ...[
                Text(
                  st!.noiseReduction ? '已开启 · 降噪' : '已开启',
                  style: t.subhead.copyWith(color: c.secondaryLabel),
                ),
                const SizedBox(width: AppSpacing.x2),
              ],
              AppSwitch(
                value: st?.listening ?? false,
                semanticLabel: '监听机器人麦克风',
                onChanged: (v) =>
                    ref.read(intercomRepositoryProvider).setListening(v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 文字转语音播报（桌面）。
class TtsCard extends ConsumerStatefulWidget {
  const TtsCard({super.key});

  @override
  ConsumerState<TtsCard> createState() => _TtsCardState();
}

class _TtsCardState extends ConsumerState<TtsCard> {
  final _text = TextEditingController(text: '您好，欢迎参观，请跟随我前往展品区。');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final target = currentTarget(ref);
    final n = await ref.read(intercomRepositoryProvider).broadcast(_text.text);
    final ui = ref.read(agentUiProvider.notifier);
    if (n == 0) {
      ui.notify(BannerKind.warning, '${target?.label ?? '对象'} 没有在线设备，未播报');
    } else {
      ui.notify(BannerKind.success, '已播报到 ${target?.label}（$n 台）');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.type;
    final st = ref.watch(intercomStateProvider).value;
    final target = currentTarget(ref);
    return AppCard(
      title: '文字转语音播报',
      semanticLabel: '语音播报',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            hint: '输入要播报的内容',
            semanticLabel: '播报内容',
            controller: _text,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.x2 + AppSpacing.half),
          Wrap(
            spacing: AppSpacing.x2 - AppSpacing.half,
            runSpacing: AppSpacing.x2 - AppSpacing.half,
            children: [
              for (final p in st?.presets ?? const <String>[])
                Pressable(
                  onTap: () => setState(() => _text.text = p),
                  semanticLabel: '使用预设：$p',
                  focusRadius: AppRadius.xs,
                  builder: (context, s) => Container(
                    height: 24,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.x2,
                    ),
                    decoration: BoxDecoration(
                      color: s.pressed ? c.separator : c.fillSecondary,
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Text(p, style: t.footnote.copyWith(color: c.label)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2 + AppSpacing.half),
          PrimaryButton(
            label: '播报到 ${target?.label ?? '—'}',
            size: ButtonSize.regular,
            expand: true,
            onPressed: _text.text.trim().isEmpty ? null : _send,
          ),
        ],
      ),
    );
  }
}

StatusTone skillTone(SkillMode m) => switch (m) {
  SkillMode.ask => StatusTone.warning,
  SkillMode.auto => StatusTone.online,
  SkillMode.deny => StatusTone.critical,
};

/// 智能体可用技能：自动 / 需确认 / 禁止。管理员可修改，涉及运动的技能不能设为自动。
class SkillsList extends ConsumerWidget {
  const SkillsList({super.key, this.showDescription = false});

  final bool showDescription;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = context.type;
    final skills = ref.watch(agentSkillsProvider).value ?? const [];
    final admin =
        ref.watch(currentUserProvider).value?.role == MemberRole.admin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final k in skills)
          Container(
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.x1 + AppSpacing.half,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.separatorSubtle)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(k.name, style: t.monoLarge.copyWith(color: c.label)),
                      if (showDescription)
                        Text(
                          k.description,
                          style: t.footnote.copyWith(color: c.secondaryLabel),
                        ),
                    ],
                  ),
                ),
                AppMenu<SkillMode>(
                  options: [
                    for (final m in SkillMode.values)
                      if (!(k.motion && m == SkillMode.auto))
                        MenuOption(m, m.label),
                  ],
                  selected: k.mode,
                  onSelected: (m) =>
                      ref.read(agentRepositoryProvider).setSkillMode(k.name, m),
                  anchor: (context, toggle) => Pressable(
                    onTap: admin ? toggle : null,
                    semanticLabel: '${k.name}：${k.mode.label}',
                    tooltip: admin ? '修改权限' : null,
                    focusRadius: AppRadius.tag,
                    builder: (context, _) =>
                        Tag(label: k.mode.label, tone: skillTone(k.mode)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class SkillsCard extends StatelessWidget {
  const SkillsCard({super.key});

  @override
  Widget build(BuildContext context) => const AppCard(
    title: '智能体可用技能',
    semanticLabel: '智能体技能',
    gap: AppSpacing.x1,
    child: SkillsList(),
  );
}

/// 「技能与权限」对话框：带说明的完整列表。
Future<void> showSkillsDialog(BuildContext context) => showAppDialog<void>(
  context: context,
  builder: (context) => const AppAlert<void>(
    title: '技能与权限',
    message: '涉及运动的技能必须由你确认后执行，不能设为「自动」。',
    maxWidth: 420,
    content: SkillsList(showDescription: true),
    actions: [AlertAction<void>(label: '完成', value: null)],
  ),
);
