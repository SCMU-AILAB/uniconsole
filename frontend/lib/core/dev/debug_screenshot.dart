import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 仅 debug：设置环境变量 `UNICONSOLE_SCREENSHOT=out.png` 启动时，
/// 渲染稳定后把窗口内容存成 PNG，用于阶段验收截图对照（HANDOFF.md §9）。
/// macOS 应用在沙盒内，文件写到应用的临时目录，完整路径打印在控制台。
/// 可选 `UNICONSOLE_SCREENSHOT_SCROLL=像素` 先滚动主内容区再截图。
Future<void> maybeCaptureDebugScreenshot() async {
  if (!kDebugMode || kIsWeb) return;
  final name = Platform.environment['UNICONSOLE_SCREENSHOT'];
  if (name == null || name.isEmpty) return;
  final path = '${Directory.systemTemp.path}/${name.split('/').last}';
  final scroll = double.tryParse(
    Platform.environment['UNICONSOLE_SCREENSHOT_SCROLL'] ?? '',
  );

  await Future<void>.delayed(const Duration(seconds: 2));
  if (scroll != null) _scrollMain(scroll);
  await Future<void>.delayed(const Duration(milliseconds: 600));

  final view = WidgetsBinding.instance.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size;
  final dpr = view.flutterView.devicePixelRatio;
  // 根层已包含 devicePixelRatio 变换，按物理像素范围、1 倍截取。
  final image = await layer.toImage(Offset.zero & (size * dpr), pixelRatio: 1);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  debugPrint(
    'UNICONSOLE_SCREENSHOT saved ${size.width.toInt()}x${size.height.toInt()} @${dpr}x → $path',
  );
}

void _scrollMain(double offset) {
  ScrollPosition? best;
  void visit(Element e) {
    if (e is StatefulElement && e.state is ScrollableState) {
      final pos = (e.state as ScrollableState).position;
      if (pos.axis == Axis.vertical &&
          (best == null || pos.maxScrollExtent > best!.maxScrollExtent)) {
        best = pos;
      }
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  best?.jumpTo(offset.clamp(0, best!.maxScrollExtent));
}

/// 仅 debug：`UNICONSOLE_THEME=light|dark` 启动时固定外观（默认跟随系统），便于截图对照。
String? get debugThemeOverride {
  if (!kDebugMode || kIsWeb) return null;
  final v = Platform.environment['UNICONSOLE_THEME'];
  return v == 'light' || v == 'dark' ? v : null;
}

/// 仅 debug：`UNICONSOLE_ROUTE=/settings` 启动时直接打开指定页面。
String? get debugInitialRoute {
  if (!kDebugMode || kIsWeb) return null;
  final v = Platform.environment['UNICONSOLE_ROUTE'];
  return v == null || v.isEmpty ? null : v;
}

/// 仅 debug：`UNICONSOLE_DEMO_PUSH=1` 启动 1 秒后模拟一条新告警，用于截图推送横幅。
bool get debugDemoPush {
  if (!kDebugMode || kIsWeb) return false;
  return Platform.environment['UNICONSOLE_DEMO_PUSH'] == '1';
}
