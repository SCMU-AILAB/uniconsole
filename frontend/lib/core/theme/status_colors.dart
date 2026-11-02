import 'package:flutter/material.dart';

/// 状态语义（HANDOFF.md §3.3）。设备状态、告警级别、标签都映射到这六种色调。
enum StatusTone { online, busy, warning, critical, offline, action }

/// 一种状态的三件套：圆点 / 文字 / 标签底。
@immutable
class StatusSwatch {
  const StatusSwatch({required this.dot, required this.fg, required this.bg});

  final Color dot;
  final Color fg;
  final Color bg;
}

@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors(this._swatches);

  final Map<StatusTone, StatusSwatch> _swatches;

  StatusSwatch of(StatusTone tone) => _swatches[tone]!;

  StatusSwatch get online => of(StatusTone.online);
  StatusSwatch get busy => of(StatusTone.busy);
  StatusSwatch get warning => of(StatusTone.warning);
  StatusSwatch get critical => of(StatusTone.critical);
  StatusSwatch get offline => of(StatusTone.offline);
  StatusSwatch get action => of(StatusTone.action);

  static const light = StatusColors({
    StatusTone.online: StatusSwatch(
      dot: Color(0xFF34C759),
      fg: Color(0xFF1E7A35),
      bg: Color(0xFFE8F7EC),
    ),
    StatusTone.busy: StatusSwatch(
      dot: Color(0xFF0071E3),
      fg: Color(0xFF0058B8),
      bg: Color(0xFFE6F0FD),
    ),
    StatusTone.warning: StatusSwatch(
      dot: Color(0xFFFF9500),
      fg: Color(0xFFA04500),
      bg: Color(0xFFFFF1E0),
    ),
    StatusTone.critical: StatusSwatch(
      dot: Color(0xFFFF3B30),
      fg: Color(0xFFB0000F),
      bg: Color(0xFFFFE5E3),
    ),
    StatusTone.offline: StatusSwatch(
      dot: Color(0xFFAEAEB2),
      fg: Color(0xFF636366),
      bg: Color(0xFFEFEFF2),
    ),
    StatusTone.action: StatusSwatch(
      dot: Color(0xFFAF52DE),
      fg: Color(0xFF6A2BA8),
      bg: Color(0xFFF1E9FB),
    ),
  });

  /// 深色值来自 HANDOFF.md §11。
  /// busy / critical 的 fg 为「调整值」：§11 原值 #409CFF / #FF6961 叠在各自
  /// 标签底（再叠 surface）上只有 3.9:1，不满足 4.5:1，改为最接近的合格色。
  static const dark = StatusColors({
    StatusTone.online: StatusSwatch(
      dot: Color(0xFF30D158),
      fg: Color(0xFF30D158),
      bg: Color(0x2E30D158),
    ),
    StatusTone.busy: StatusSwatch(
      dot: Color(0xFF0A84FF),
      fg: Color(0xFF64B0FF), // 调整值（§11 原值 #409CFF）
      bg: Color(0x330A84FF),
    ),
    StatusTone.warning: StatusSwatch(
      dot: Color(0xFFFF9F0A),
      fg: Color(0xFFFFB340),
      bg: Color(0x2EFF9F0A),
    ),
    StatusTone.critical: StatusSwatch(
      dot: Color(0xFFFF453A),
      fg: Color(0xFFFF847D), // 调整值（§11 原值 #FF6961）
      bg: Color(0x33FF453A),
    ),
    StatusTone.offline: StatusSwatch(
      dot: Color(0xFF8E8E93),
      fg: Color(0xFFAEAEB2),
      bg: Color(0x338E8E93),
    ),
    StatusTone.action: StatusSwatch(
      dot: Color(0xFFBF5AF2),
      fg: Color(0xFFDA8FFF),
      bg: Color(0x33BF5AF2),
    ),
  });

  @override
  StatusColors copyWith() => this;

  @override
  StatusColors lerp(StatusColors? other, double t) =>
      other == null || t < 0.5 ? this : other;
}
