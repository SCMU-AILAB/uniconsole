import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 桌面窗口外观（HANDOFF.md §4）。
///
/// macOS 使用全尺寸内容视图 + 透明标题栏（见 macos/Runner/MainFlutterWindow.swift），
/// 顶部 [titlebarHeight] 留给红黄绿按钮与窗口拖动，不放可点击控件。
/// Windows / Linux 保留系统标题栏，高度为 0。
abstract final class WindowChrome {
  static const _channel = MethodChannel('uniconsole/window');

  static bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// 标准 macOS 标题栏高度。测试环境（flutter_test 模拟 macOS 时）同样生效。
  static double get titlebarHeight => _isMacOS ? 28 : 0;

  static Future<void> startDrag() async {
    if (!_isMacOS) return;
    try {
      await _channel.invokeMethod<void>('startDrag');
    } on MissingPluginException {
      // 测试环境没有原生端。
    }
  }

  static Future<void> zoom() async {
    if (!_isMacOS) return;
    try {
      await _channel.invokeMethod<void>('zoom');
    } on MissingPluginException {
      // 测试环境没有原生端。
    }
  }
}

/// 透明的窗口拖动区：拖动移动窗口，双击缩放（与系统标题栏行为一致）。
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    if (height <= 0) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => WindowChrome.startDrag(),
        onDoubleTap: WindowChrome.zoom,
        child: SizedBox(height: height, width: double.infinity),
      ),
    );
  }
}
