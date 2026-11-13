import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/providers.dart';

/// 操控输入的合成状态：摇杆与键盘（W A S D 移动、Q E 转向）。
class ControlInputState {
  const ControlInputState({
    this.stick = Offset.zero,
    this.turn = 0,
    this.keys = const {},
    this.speed = SpeedLevel.normal,
  });

  /// 移动摇杆 x、y ∈ [-1, 1]（y 向前为正）。
  final Offset stick;

  /// 转向摇杆 ∈ [-1, 1]（向右为正）。
  final double turn;

  /// 当前按住的方向键。
  final Set<LogicalKeyboardKey> keys;
  final SpeedLevel speed;

  /// 键盘与摇杆合成后的移动量。
  Offset get move {
    var x = stick.dx, y = stick.dy;
    if (keys.contains(LogicalKeyboardKey.keyW)) y += 1;
    if (keys.contains(LogicalKeyboardKey.keyS)) y -= 1;
    if (keys.contains(LogicalKeyboardKey.keyD)) x += 1;
    if (keys.contains(LogicalKeyboardKey.keyA)) x -= 1;
    return Offset(x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0));
  }

  double get yaw {
    var w = turn;
    if (keys.contains(LogicalKeyboardKey.keyE)) w += 1;
    if (keys.contains(LogicalKeyboardKey.keyQ)) w -= 1;
    return w.clamp(-1.0, 1.0);
  }

  bool get active => move != Offset.zero || yaw != 0;

  /// 速度指令：前进 vx、横移 vy（向左为正）、转向 ωz（逆时针为正）。
  (double, double, double) get velocity =>
      (move.dy * speed.mps, -move.dx * speed.mps * 0.6, -yaw * 1.0);

  ControlInputState copyWith({
    Offset? stick,
    double? turn,
    Set<LogicalKeyboardKey>? keys,
    SpeedLevel? speed,
  }) => ControlInputState(
    stick: stick ?? this.stick,
    turn: turn ?? this.turn,
    keys: keys ?? this.keys,
    speed: speed ?? this.speed,
  );

  static final movementKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyD,
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyE,
  };
}

/// 死区内归零，死区外重新映射到 0–1；指数曲线让低速更细腻（m²）。
double _shape(double m, double deadzone, ResponseCurve curve) {
  if (m <= deadzone) return 0;
  final x = ((m - deadzone) / (1 - deadzone)).clamp(0.0, 1.0);
  return curve == ResponseCurve.exponential ? x * x : x;
}

Offset shapeStick(Offset v, double deadzone, ResponseCurve curve) {
  final m = v.distance;
  if (m == 0) return Offset.zero;
  final shaped = _shape(m.clamp(0.0, 1.0), deadzone, curve);
  return v / m * shaped;
}

double shapeAxis(double v, double deadzone, ResponseCurve curve) =>
    v.sign * _shape(v.abs().clamp(0.0, 1.0), deadzone, curve);

/// 把输入变成指令（HANDOFF §8.4 / API §2）：
/// - 有输入时以 15 Hz 发送 `move`；
/// - 所有输入松开后等待 300 ms，再显式发送一次 `stop`；
/// - 离开页面时立即停止。
class ControlInput extends Notifier<ControlInputState> {
  ControlInput(this.deviceId);

  final String deviceId;

  static const sendInterval = Duration(milliseconds: 66);
  static const releaseDelay = Duration(milliseconds: 300);

  Timer? _sender;
  Timer? _release;
  bool _moving = false;

  @override
  ControlInputState build() {
    ref.onDispose(() {
      _sender?.cancel();
      _release?.cancel();
      if (_moving) ref.read(controlRepositoryProvider).stop(deviceId);
    });
    final lifecycle = AppLifecycleListener(
      onInactive: halt,
      onPause: halt,
      onDetach: halt,
    );
    ref.onDispose(lifecycle.dispose);
    ref.listen(holdsLeaseProvider(deviceId), (_, holds) {
      if (!holds) halt();
    });
    ref.listen(estopProvider(deviceId), (_, next) {
      if (next.value != false) halt();
    });
    ref.listen(deviceProvider(deviceId), (_, device) {
      if (device?.status.isOnline != true) halt();
    });
    ref.listen(controlConnectionProvider, (_, next) {
      if (next.value != true) halt();
    });
    return const ControlInputState();
  }

  /// 摇杆输入按偏好（设置 › 控制与手柄）处理死区与响应曲线。
  void setStick(Offset v) {
    final p = ref.read(preferencesProvider);
    _set(state.copyWith(stick: shapeStick(v, p.deadzone, p.curve)));
  }

  void setTurn(double v) {
    final p = ref.read(preferencesProvider);
    _set(state.copyWith(turn: shapeAxis(v, p.deadzone, p.curve)));
  }

  void setSpeed(SpeedLevel level) => state = state.copyWith(speed: level);

  /// 返回 true 表示按键已处理。
  bool key(KeyEvent e) {
    if (!ControlInputState.movementKeys.contains(e.logicalKey)) return false;
    final keys = {...state.keys};
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      keys.add(e.logicalKey);
    } else if (e is KeyUpEvent) {
      keys.remove(e.logicalKey);
    }
    _set(state.copyWith(keys: keys));
    return true;
  }

  /// 急停 / 失去控制权时清空输入，不再发送。
  void halt() {
    _sender?.cancel();
    _sender = null;
    _release?.cancel();
    _release = null;
    if (_moving) ref.read(controlRepositoryProvider).stop(deviceId);
    _moving = false;
    state = ControlInputState(speed: state.speed);
  }

  void _set(ControlInputState next) {
    state = next;
    if (next.active) {
      _release?.cancel();
      _release = null;
      _moving = true;
      _send();
      _sender ??= Timer.periodic(sendInterval, (_) => _send());
    } else {
      _sender?.cancel();
      _sender = null;
      if (_moving && _release == null) {
        _release = Timer(releaseDelay, () {
          _release = null;
          if (!state.active) {
            _moving = false;
            ref.read(controlRepositoryProvider).stop(deviceId);
          }
        });
      }
    }
  }

  void _send() {
    final (vx, vy, wz) = state.velocity;
    ref.read(controlRepositoryProvider).move(deviceId, vx, vy, wz);
  }
}

final controlInputProvider = NotifierProvider.autoDispose
    .family<ControlInput, ControlInputState, String>(ControlInput.new);

/// 租约自动续约：剩余不足 1/3（100 s）时续约（API 建议）。
final leaseAutoRenewProvider = Provider.autoDispose.family<void, String>((
  ref,
  id,
) {
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final lease = ref.read(leaseProvider(id));
    if (lease?.expiresAt == null || !ref.read(holdsLeaseProvider(id))) return;
    if (lease!.expiresAt!.difference(DateTime.now()) <
        const Duration(seconds: 100)) {
      unawaited(
        ref.read(leaseRepositoryProvider).renew(id).catchError((Object _) {
          // 权限或网络失败时，下一次租约快照决定是否继续持有；不要产生未处理异常。
        }),
      );
    }
  });
  ref.onDispose(timer.cancel);
});
