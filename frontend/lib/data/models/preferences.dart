import 'package:flutter/foundation.dart';

/// 侧边栏图标大小（设置 › 外观）。
enum SidebarIconSize {
  small('小', 15),
  medium('中', 17),
  large('大', 20);

  const SidebarIconSize(this.label, this.icon);

  final String label;
  final double icon;
}

/// 摇杆响应曲线（设置 › 控制与手柄）。
enum ResponseCurve {
  linear('线性'),
  exponential('指数（低速更细腻）');

  const ResponseCurve(this.label);

  final String label;
}

enum VideoQuality {
  p480('480p 30 fps'),
  p720('720p 30 fps'),
  p1080('1080p 30 fps');

  const VideoQuality(this.label);

  final String label;
}

enum WeakNetworkPolicy {
  control('优先保证控制指令，降低画质'),
  quality('优先保证画质');

  const WeakNetworkPolicy(this.label);

  final String label;
}

enum RelayServer {
  auto('自动选择 · 东京'),
  tokyo('东京'),
  shanghai('上海'),
  direct('不使用（仅局域网直连）');

  const RelayServer(this.label);

  final String label;
}

/// 通知方式（设置 › 通知）。
enum NotifyStyle {
  urgent('横幅 + 声音 + 突破专注模式'),
  bannerSound('横幅 + 声音'),
  banner('横幅'),
  off('关闭');

  const NotifyStyle(this.label);

  final String label;
}

/// 手柄按键 → 动作（设置 › 控制与手柄）。
@immutable
class GamepadBinding {
  const GamepadBinding(this.control, this.action);

  /// 按键或组合，如「左摇杆」「LB + RB 同时按」。
  final String control;
  final String action;
}

/// 已登录的客户端（设置 › 账户与安全）。
@immutable
class SignedInClient {
  const SignedInClient({
    required this.id,
    required this.name,
    required this.detail,
    this.current = false,
  });

  final String id;
  final String name;
  final String detail;
  final bool current;
}

@immutable
class ApiToken {
  const ApiToken({required this.id, required this.name, required this.detail});

  final String id;
  final String name;
  final String detail;
}

/// 账户级偏好，按账户同步到所有设备（Settings.dc.html 页眉说明）。
/// 外观的浅色 / 深色与强调色由 `core/theme` 的控制器管理。
@immutable
class Preferences {
  const Preferences({
    this.sidebarIconSize = SidebarIconSize.medium,
    this.hudOpacity = 0.72,
    this.darkWhileControlling = true,
    this.deadzone = 0.10,
    this.curve = ResponseCurve.exponential,
    this.bindings = const [],
    this.videoQuality = VideoQuality.p720,
    this.weakNetwork = WeakNetworkPolicy.control,
    this.relay = RelayServer.auto,
    this.notifyCritical = NotifyStyle.urgent,
    this.notifyWarning = NotifyStyle.banner,
    this.notifyLease = NotifyStyle.bannerSound,
    this.dailyReportHour = 18,
    this.twoFactor = true,
  });

  final SidebarIconSize sidebarIconSize;

  /// 视频画面信息层（HUD）不透明度 0–1。
  final double hudOpacity;

  /// 进入操控页面时始终使用深色界面。
  final bool darkWhileControlling;

  /// 摇杆死区 0–0.3。
  final double deadzone;
  final ResponseCurve curve;
  final List<GamepadBinding> bindings;
  final VideoQuality videoQuality;
  final WeakNetworkPolicy weakNetwork;
  final RelayServer relay;
  final NotifyStyle notifyCritical;
  final NotifyStyle notifyWarning;
  final NotifyStyle notifyLease;

  /// 每日巡检报告推送时间（点）；null 为关闭。
  final int? dailyReportHour;
  final bool twoFactor;

  Preferences copyWith({
    SidebarIconSize? sidebarIconSize,
    double? hudOpacity,
    bool? darkWhileControlling,
    double? deadzone,
    ResponseCurve? curve,
    List<GamepadBinding>? bindings,
    VideoQuality? videoQuality,
    WeakNetworkPolicy? weakNetwork,
    RelayServer? relay,
    NotifyStyle? notifyCritical,
    NotifyStyle? notifyWarning,
    NotifyStyle? notifyLease,
    int? dailyReportHour,
    bool clearDailyReport = false,
    bool? twoFactor,
  }) => Preferences(
    sidebarIconSize: sidebarIconSize ?? this.sidebarIconSize,
    hudOpacity: hudOpacity ?? this.hudOpacity,
    darkWhileControlling: darkWhileControlling ?? this.darkWhileControlling,
    deadzone: deadzone ?? this.deadzone,
    curve: curve ?? this.curve,
    bindings: bindings ?? this.bindings,
    videoQuality: videoQuality ?? this.videoQuality,
    weakNetwork: weakNetwork ?? this.weakNetwork,
    relay: relay ?? this.relay,
    notifyCritical: notifyCritical ?? this.notifyCritical,
    notifyWarning: notifyWarning ?? this.notifyWarning,
    notifyLease: notifyLease ?? this.notifyLease,
    dailyReportHour: clearDailyReport
        ? null
        : dailyReportHour ?? this.dailyReportHour,
    twoFactor: twoFactor ?? this.twoFactor,
  );
}

/// 已连接的手柄（`gamepads` 插件接入前由 mock 提供）。
@immutable
class GamepadInfo {
  const GamepadInfo({
    required this.name,
    required this.connection,
    this.battery,
  });

  final String name;
  final String connection;
  final int? battery;
}
