import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_repositories.dart';
import 'mock_store.dart';

/// 账户偏好（Settings.dc.html）。真实后端按账户同步；mock 只保存在内存中。
class MockPreferencesRepository implements PreferencesRepository {
  MockPreferencesRepository({required this.world});

  final MockWorld world;

  // Settings.dc.html PAD[]
  static const defaultBindings = [
    GamepadBinding('左摇杆', '前进 / 后退 / 横移'),
    GamepadBinding('右摇杆', '原地转向'),
    GamepadBinding('A', '站立'),
    GamepadBinding('B', '趴下'),
    GamepadBinding('X', '切换步态'),
    GamepadBinding('Y', '切换摄像头'),
    GamepadBinding('十字键 ↑ ↓', '速度档位'),
    GamepadBinding('LB + RB 同时按', '急停'),
  ];

  final _prefs = MockStore(const Preferences(bindings: defaultBindings));
  final _gamepad = MockStore<GamepadInfo?>(
    const GamepadInfo(name: 'Xbox 无线控制器', connection: '已通过蓝牙连接', battery: 80),
  );
  final _clients = MockStore(const [
    SignedInClient(
      id: 'mac',
      name: 'MacBook Pro',
      detail: 'macOS · 192.168.1.20 · 本机',
      current: true,
    ),
    SignedInClient(id: 'iphone', name: 'iPhone', detail: 'iOS · 今天 09:12'),
    SignedInClient(
      id: 'win',
      name: 'Windows 工作站',
      detail: 'Windows · 昨天 17:50',
    ),
  ]);
  final _tokens = MockStore(const [
    ApiToken(id: 't1', name: '智能体服务', detail: '读写设备 · 创建于 10 月 12 日'),
    ApiToken(id: 't2', name: '巡检报告自动化', detail: '只读 · 创建于 9 月 3 日'),
  ]);

  Preferences get preferences => _prefs.value;

  @override
  Stream<Preferences> watchPreferences() => _prefs.watch();

  @override
  Future<void> update(Preferences Function(Preferences) change) async {
    final before = _prefs.value;
    final after = change(before);
    _prefs.value = after;
    if (before.twoFactor != after.twoFactor) {
      world.log(after.twoFactor ? '开启二次验证' : '关闭二次验证');
    }
  }

  @override
  Stream<GamepadInfo?> watchGamepad() => _gamepad.watch();

  @override
  Stream<List<SignedInClient>> watchClients() => _clients.watch();

  @override
  Future<void> signOut(String clientId) async {
    final c = _clients.value.where((c) => c.id == clientId).firstOrNull;
    if (c == null || c.current) return;
    _clients.value = [
      for (final x in _clients.value)
        if (x.id != clientId) x,
    ];
    world.log('让 ${c.name} 退出登录');
  }

  @override
  Stream<List<ApiToken>> watchTokens() => _tokens.watch();

  @override
  Future<void> revokeToken(String id) async {
    final t = _tokens.value.where((t) => t.id == id).firstOrNull;
    if (t == null) return;
    _tokens.value = [
      for (final x in _tokens.value)
        if (x.id != id) x,
    ];
    world.log('撤销 API 令牌「${t.name}」');
  }
}
