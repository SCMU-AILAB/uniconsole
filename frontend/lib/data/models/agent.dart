import 'package:flutter/foundation.dart';

/// HANDOFF.md §6 AgentPlan.state。
enum PlanState {
  pending('等待确认'),
  running('执行中'),
  done('已完成'),
  aborted('已中止'),
  cancelled('已取消');

  const PlanState(this.label);

  final String label;

  bool get finished => this == done || this == aborted || this == cancelled;
}

enum StepState { waiting, running, done, skipped }

/// 计划的一步：哪台设备、做什么、对应的技能调用、预计耗时。
@immutable
class AgentStep {
  const AgentStep({
    required this.who,
    required this.text,
    required this.call,
    this.deviceId,
    this.eta,
    this.summary,
    this.state = StepState.waiting,
  });

  /// 设备名或「系统」。
  final String who;
  final String? deviceId;
  final String text;

  /// 技能调用，如 `navigate_to(target="C-gate", side="left")`。
  final String call;

  /// 预计耗时，如「约 90 秒」；没有时显示「—」。
  final String? eta;

  /// 手机上一行显示的短说明（MobileAgent rows[].note），执行中会更新。
  final String? summary;
  final StepState state;

  AgentStep copyWith({StepState? state, String? summary}) => AgentStep(
    who: who,
    deviceId: deviceId,
    text: text,
    call: call,
    eta: eta,
    summary: summary ?? this.summary,
    state: state ?? this.state,
  );
}

/// 执行前的安全检查；[ok] 为 false 时是需要注意的提示（不阻止执行）。
@immutable
class PlanCheck {
  const PlanCheck(this.text, {this.ok = true});

  final String text;
  final bool ok;
}

/// HANDOFF.md §6 AgentPlan。涉及运动的计划必须由用户确认后才执行（§8.3）。
@immutable
class AgentPlan {
  const AgentPlan({
    required this.id,
    required this.title,
    required this.steps,
    this.checks = const [],
    this.state = PlanState.pending,
    this.progress,
  });

  final String id;
  final String title;
  final List<AgentStep> steps;
  final List<PlanCheck> checks;
  final PlanState state;

  /// 执行中的进度说明，如「Alpha 已到达，Bravo 距离 6.2 m」。
  final String? progress;

  /// 当前步骤（0 起）；没有在执行的步骤时为 null。
  int? get current {
    final i = steps.indexWhere((s) => s.state == StepState.running);
    return i < 0 ? null : i;
  }

  List<String> get deviceIds => {
    for (final s in steps)
      if (s.deviceId != null) s.deviceId!,
  }.toList();

  AgentPlan copyWith({
    List<AgentStep>? steps,
    PlanState? state,
    String? progress,
    bool clearProgress = false,
  }) => AgentPlan(
    id: id,
    title: title,
    steps: steps ?? this.steps,
    checks: checks,
    state: state ?? this.state,
    progress: clearProgress ? null : progress ?? this.progress,
  );
}

enum AgentRole { user, agent }

/// 智能体回复里附带的画面（拍照结果、实时截图）。
@immutable
class AgentPhoto {
  const AgentPhoto({required this.deviceId, required this.caption});

  final String deviceId;
  final String caption;
}

@immutable
class AgentMessage {
  const AgentMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.at,
    this.plan,
    this.photo,
  });

  final String id;
  final AgentRole role;
  final String text;
  final DateTime at;
  final AgentPlan? plan;
  final AgentPhoto? photo;

  AgentMessage withPlan(AgentPlan plan) => AgentMessage(
    id: id,
    role: role,
    text: text,
    at: at,
    plan: plan,
    photo: photo,
  );
}

@immutable
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.messages = const [],
    this.deviceIds = const [],
    this.mapId,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final List<AgentMessage> messages;

  /// 输入框上方的上下文标签：@设备、地图。
  final List<String> deviceIds;
  final String? mapId;

  /// 正在等待确认或执行中的计划。
  AgentPlan? get activePlan => messages.reversed
      .map((m) => m.plan)
      .whereType<AgentPlan>()
      .where((p) => !p.state.finished)
      .firstOrNull;

  Conversation copyWith({
    String? title,
    DateTime? updatedAt,
    List<AgentMessage>? messages,
    List<String>? deviceIds,
    String? mapId,
    bool clearMap = false,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    messages: messages ?? this.messages,
    deviceIds: deviceIds ?? this.deviceIds,
    mapId: clearMap ? null : mapId ?? this.mapId,
  );
}

/// 技能权限（Agent.dc.html skills）：自动执行 / 需要确认 / 禁止调用。
enum SkillMode {
  auto('自动'),
  ask('需确认'),
  deny('禁止');

  const SkillMode(this.label);

  final String label;
}

@immutable
class AgentSkill {
  const AgentSkill({
    required this.name,
    required this.description,
    required this.mode,
    this.motion = false,
  });

  final String name;
  final String description;
  final SkillMode mode;

  /// 涉及运动的技能不能设为「自动」（HANDOFF §8.3）。
  final bool motion;

  AgentSkill copyWith({SkillMode? mode}) => AgentSkill(
    name: name,
    description: description,
    mode: mode ?? this.mode,
    motion: motion,
  );
}

/// 对讲对象：单台设备或一组设备。
@immutable
class IntercomTarget {
  const IntercomTarget({
    required this.id,
    required this.label,
    required this.deviceIds,
  });

  final String id;
  final String label;
  final List<String> deviceIds;
}

@immutable
class IntercomState {
  const IntercomState({
    required this.targetId,
    this.talkingSince,
    this.listening = true,
    this.noiseReduction = true,
    this.latencyMs = 120,
    this.presets = const [],
  });

  final String targetId;

  /// 正在讲话时为开始时间。
  final DateTime? talkingSince;
  final bool listening;
  final bool noiseReduction;
  final int latencyMs;

  /// 播报预设（Agent.dc.html / MobileAgent 播报预设）。
  final List<String> presets;

  bool get talking => talkingSince != null;

  IntercomState copyWith({
    String? targetId,
    DateTime? talkingSince,
    bool stopTalking = false,
    bool? listening,
  }) => IntercomState(
    targetId: targetId ?? this.targetId,
    talkingSince: stopTalking ? null : talkingSince ?? this.talkingSince,
    listening: listening ?? this.listening,
    noiseReduction: noiseReduction,
    latencyMs: latencyMs,
    presets: presets,
  );
}
