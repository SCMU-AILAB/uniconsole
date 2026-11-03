import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 手机的屏幕方向（HANDOFF.md §4：操控页在手机上强制横屏，其余移动页面均为竖屏设计）。
/// 平板（短边 ≥ 600）与桌面不限制方向。
abstract final class AppOrientation {
  static bool get isPhone {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final view = PlatformDispatcher.instance.views.firstOrNull;
    if (view == null) return true;
    return (view.physicalSize / view.devicePixelRatio).shortestSide < 600;
  }

  /// 应用默认：手机竖屏。
  static Future<void> portrait() async {
    if (!isPhone) return;
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  /// 横屏操控：横屏并隐藏状态栏。
  static Future<void> landscape() async {
    if (!isPhone) return;
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
}
