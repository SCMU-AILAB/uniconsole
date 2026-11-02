import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 最近一次鼠标按下事件，供 Flutter 侧发起窗口拖动时使用。
  private var lastMouseDown: NSEvent?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 默认 1440×900；可拉到 390 宽以检查移动布局（HANDOFF.md §10）。
    // 截图对照时可用环境变量 UNICONSOLE_WINDOW_SIZE=1000x900 指定内容区尺寸。
    var size = NSSize(width: 1440, height: 900)
    if let spec = ProcessInfo.processInfo.environment["UNICONSOLE_WINDOW_SIZE"] {
      let parts = spec.split(separator: "x").compactMap { Double($0) }
      if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
    }
    // 不恢复上次的窗口位置尺寸，保证每次按上面的尺寸打开。
    self.isRestorable = false
    self.contentMinSize = NSSize(width: 390, height: 600)
    self.setContentSize(size)
    self.center()

    // 红黄绿按钮与侧边栏融为一体（HANDOFF.md §4）：全尺寸内容视图 + 透明标题栏。
    // 顶部 28pt 由 Flutter 侧留空并作为拖动区（lib/core/platform/window_chrome.dart）。
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden

    NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      if event.window === self { self?.lastMouseDown = event }
      return event
    }

    let channel = FlutterMethodChannel(
      name: "uniconsole/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "startDrag":
        if let event = self.lastMouseDown { self.performDrag(with: event) }
        result(nil)
      case "zoom":
        self.zoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
