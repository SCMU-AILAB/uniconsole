import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/api/live_auth_repository.dart';
import 'package:uniconsole/data/api/live_robot_repository.dart';
import 'package:uniconsole/data/api/token_store.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/data/repositories/repositories.dart';

/// 显式运行：UNICONSOLE_E2E_SESSION_FILE=会话JSON路径 UNICONSOLE_E2E_DEVICE=设备ID
/// flutter test test/e2e/live_robot_e2e_test.dart
/// 会取得/续约/释放空闲设备控制权，只下发 Stop 和演练急停，不发运动指令。
void main() {
  final path = Platform.environment['UNICONSOLE_E2E_SESSION_FILE'];
  final id = Platform.environment['UNICONSOLE_E2E_DEVICE'];
  setUpAll(() => HttpOverrides.global = null);
  test('真实会话 → 前端仓库 → 服务器 → Go2 遥测与停止回执', () async {
    final store = MemoryTokenStore()
      ..session =
          jsonDecode(await File(path!).readAsString()) as Map<String, dynamic>;
    final auth = await LiveAuthRepository.restore(store);
    final container = ProviderContainer(
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
    );
    final keepAlive = container.listen(deviceRepositoryProvider, (_, _) {});
    final repo =
        container.read(deviceRepositoryProvider) as LiveRobotRepository;
    var acquired = false;
    try {
      final devices = await repo
          .watchDevices()
          .firstWhere((ds) => ds.any((d) => d.id == id && d.status.isOnline))
          .timeout(const Duration(seconds: 15));
      expect(devices.singleWhere((d) => d.id == id).status.isOnline, true);
      final tm = await repo
          .watch(id!)
          .first
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw StateError(
              'telemetry timeout: connected=${repo.connected}, error=${repo.connectionError}, same=${identical(repo, container.read(deviceRepositoryProvider))}',
            ),
          );
      expect(
        DateTime.now().difference(tm.ts).abs(),
        lessThan(const Duration(seconds: 5)),
      );
      expect(tm.deviceId, id);
      expect(
        (await repo.watchLeases().first).where((l) => l.deviceId == id),
        isEmpty,
        reason: '只测试空闲设备，避免打断其他操控者',
      );
      expect(
        await repo.acquire(id, reason: '实机停止链路验证'),
        LeaseRequestResult.granted,
      );
      acquired = true;
      await repo.renew(id);
      final lease = (await repo.watchLeases().first).singleWhere(
        (l) => l.deviceId == id,
      );
      expect(lease.holderId, auth.session!.memberId);
      expect((await repo.send(id, const StopCommand())).ok, true);
      final drill = jsonMap(
        await auth.api!.post('/devices/$id/commands', {
          'command': {'kind': 'estop', 'drill': true},
        }),
      );
      expect(drill['ok'], true);
      expect((await repo.watchLog(id).first).any((l) => l.ok), true);
      await repo.release(id);
      acquired = false;
      expect(
        (await repo.watchLeases().first).where((l) => l.deviceId == id),
        isEmpty,
      );
    } finally {
      if (acquired) await repo.release(id!);
      keepAlive.close();
      container.dispose();
      auth.api?.close();
    }
  }, skip: path == null || id == null ? '未指定实机验证会话和设备' : false);
}
