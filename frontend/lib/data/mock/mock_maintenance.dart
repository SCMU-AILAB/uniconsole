import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data.dart';
import 'mock_data_ops.dart';
import 'mock_repositories.dart';
import 'mock_seed.dart';
import 'mock_store.dart';

/// 设备运维：固件灰度升级、电池健康、日志、远程终端。
///
/// 灰度发布：先升级一台，自检通过后其余并行。任务中 / 被控制的设备等任务结束，
/// 离线设备上线后自动升级。升级在 A/B 分区后台写入，不影响设备工作。
class MockMaintenanceRepository implements MaintenanceRepository {
  MockMaintenanceRepository({required this.world});

  final MockWorld world;

  /// 升级进度推进的间隔与步长（约 12 秒完成一台）。
  static const tick = Duration(milliseconds: 250);
  static const step = 0.02;

  late final _firmware = MockStore<List<FirmwareStatus>>([
    for (final d in MockData.devices) _initial(d),
  ]);
  final _release = MockStore(MockOpsData.release);
  final _battery = MockStore<List<BatteryHealth>>(MockOpsData.battery);
  final _window = MockStore(MockOpsData.window);
  final _logs = MockStore<List<DeviceLogEntry>>([
    for (final (at, level, id, m) in MockOpsData.logs)
      DeviceLogEntry(
        at: MockSeed.rebase(at),
        level: level,
        deviceId: id,
        message: m,
      ),
  ]);
  Timer? _timer;

  FirmwareStatus _initial(Device d) {
    final target = MockOpsData.release.latest[d.model] ?? d.firmware;
    final state = d.firmware == target
        ? FirmwareState.latest
        : MockOpsData.firmwareStates[d.id] ?? FirmwareState.available;
    return FirmwareStatus(
      deviceId: d.id,
      current: d.firmware,
      target: target,
      state: state,
      progress: state == FirmwareState.upgrading ? 0.62 : 0,
      error: state == FirmwareState.failed ? '校验不通过' : null,
    );
  }

  List<FirmwareStatus> get firmware => _firmware.value;

  FirmwareStatus? status(String id) =>
      firmware.where((f) => f.deviceId == id).firstOrNull;

  void _set(String id, FirmwareStatus Function(FirmwareStatus) f) {
    _firmware.value = [for (final x in firmware) x.deviceId == id ? f(x) : x];
  }

  void _log(String deviceId, LogSeverity level, String message) {
    _logs.value = [
      DeviceLogEntry(
        at: DateTime.now(),
        level: level,
        deviceId: deviceId,
        message: message,
      ),
      ..._logs.value.take(199),
    ];
  }

  /// 有设备在升级时推进进度；没有则停表。
  void _ensureTicker() {
    final active = firmware.any((f) => f.state == FirmwareState.upgrading);
    if (!active) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(tick, (_) => advance());
  }

  /// 推进一步升级进度（定时器调用；测试可直接调用）。
  @visibleForTesting
  void advance() {
    for (final f in firmware.where((f) => f.state == FirmwareState.upgrading)) {
      final p = (f.progress + step).clamp(0.0, 1.0);
      if (p < 1) {
        _set(f.deviceId, (x) => x.copyWith(progress: p));
        continue;
      }
      _set(
        f.deviceId,
        (x) => x.copyWith(
          current: x.target,
          state: FirmwareState.latest,
          progress: 1,
        ),
      );
      world.devices.update(f.deviceId, (d) => d.copyWith(firmware: f.target));
      _log(
        f.deviceId,
        LogSeverity.info,
        'ota: ${f.target} installed, self-test ok',
      );
    }
    // 第一台（灰度）自检通过后，排队的设备并行升级。
    final canaryRunning = firmware.any(
      (f) => f.state == FirmwareState.upgrading,
    );
    if (!canaryRunning) {
      for (final f in firmware.where((f) => f.state == FirmwareState.queued)) {
        _set(
          f.deviceId,
          (x) => x.copyWith(state: FirmwareState.upgrading, progress: 0),
        );
        _log(f.deviceId, LogSeverity.info, 'ota: download ${f.target}');
      }
    }
    _ensureTicker();
  }

  /// 设备当前是否在任务中 / 被人控制（升级要等任务结束）。
  bool _busy(String id) {
    final d = world.devices.device(id);
    if (d == null) return false;
    return d.status == DeviceStatus.busy ||
        d.status == DeviceStatus.alert ||
        world.leases.lease(id) != null;
  }

  void dispose() => _timer?.cancel();

  @override
  Stream<List<FirmwareStatus>> watchFirmware() {
    _ensureTicker();
    return _firmware.watch();
  }

  @override
  Stream<FirmwareRelease> watchRelease() => _release.watch();

  @override
  Future<void> upgrade(List<String> deviceIds) async {
    final ready = <String>[];
    for (final id in deviceIds) {
      final f = status(id);
      if (f == null || !f.upgradable) continue;
      final online = world.devices.device(id)?.status.isOnline ?? false;
      if (!online) {
        _set(id, (x) => x.copyWith(state: FirmwareState.waitingOnline));
      } else if (_busy(id)) {
        _set(id, (x) => x.copyWith(state: FirmwareState.waitingTask));
      } else {
        ready.add(id);
      }
    }
    final upgrading = firmware.any((f) => f.state == FirmwareState.upgrading);
    for (final (i, id) in ready.indexed) {
      // 没有设备在升级时，第一台作为灰度先行，其余排队。
      final canary = i == 0 && !upgrading;
      _set(
        id,
        (x) => x.copyWith(
          state: canary ? FirmwareState.upgrading : FirmwareState.queued,
          progress: 0,
        ),
      );
      if (canary) {
        _log(
          id,
          LogSeverity.info,
          'ota: download ${status(id)!.target} (canary)',
        );
      }
    }
    _ensureTicker();
  }

  @override
  Future<void> schedule(List<String> deviceIds) async {
    for (final id in deviceIds) {
      if (status(id)?.upgradable ?? false) {
        _set(id, (x) => x.copyWith(state: FirmwareState.scheduled));
      }
    }
  }

  @override
  Future<void> rollback(String deviceId) async {
    final f = status(deviceId);
    if (f == null) return;
    _log(deviceId, LogSeverity.warn, 'ota: rollback to previous partition');
    _set(
      deviceId,
      (x) => x.copyWith(state: FirmwareState.available, progress: 0),
    );
  }

  @override
  Future<void> reboot(String deviceId) async {
    _log(
      deviceId,
      LogSeverity.info,
      'system: reboot requested by ${world.me.name}',
    );
    world.devices.update(deviceId, (d) => d.copyWith(uptime: Duration.zero));
    world.devices.addEvent(
      deviceId,
      '${world.me.name} 远程重启',
      EventTone.neutral,
    );
  }

  @override
  Stream<List<BatteryHealth>> watchBattery() => _battery.watch();

  @override
  Stream<List<DeviceLogEntry>> watchLogs() => _logs.watch();

  @override
  Stream<MaintenanceWindow> watchWindow() => _window.watch();

  @override
  Future<void> setWindow(MaintenanceWindow window) async {
    _window.value = window;
  }

  @override
  Future<String> exportDiagnostics(List<String> deviceIds) async {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final who = deviceIds.length == 1
        ? deviceIds.first
        : '${deviceIds.length}-devices';
    return 'diag_${who}_${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}.tar.gz';
  }

  @override
  Future<List<TerminalLine>> run(String deviceId, String command) async {
    final d = world.devices.device(deviceId);
    if (d == null || !d.status.isOnline) {
      return const [
        TerminalLine('ssh: connect: Host is down', tone: TerminalTone.error),
      ];
    }
    final f = status(deviceId);
    final cmd = command.trim();
    final up = d.uptime ?? Duration.zero;
    final upText = '${up.inHours}h ${up.inMinutes % 60}min';
    return switch (cmd) {
      '' => const [],
      'help' => const [
        TerminalLine(
          '可用命令：systemctl status uniconsole-agent、df -h /data、uptime、',
        ),
        TerminalLine(
          'free -h、journalctl -u uniconsole-agent -n 5、cat /etc/firmware、clear',
        ),
      ],
      'systemctl status uniconsole-agent' => [
        const TerminalLine('● uniconsole-agent.service — UniConsole Bridge'),
        TerminalLine(
          '   Active: active (running) since boot; $upText ago',
          tone: TerminalTone.success,
        ),
        const TerminalLine('   Memory: 182.4M   CPU: 11.6%'),
      ],
      'df -h /data' => const [
        TerminalLine('Filesystem       Size  Used Avail Use% Mounted on'),
        TerminalLine('/dev/nvme0n1p3   229G   97G  121G  45% /data'),
      ],
      'uptime' => [
        TerminalLine(' up $upText,  1 user,  load average: 0.42, 0.38, 0.35'),
      ],
      'free -h' => const [
        TerminalLine('               total        used        free'),
        TerminalLine('Mem:            15Gi       4.1Gi        9.8Gi'),
      ],
      'cat /etc/firmware' => [TerminalLine(f?.current ?? d.firmware)],
      final c when c.startsWith('journalctl') => [
        for (final e
            in _logs.value.where((e) => e.deviceId == deviceId).take(5))
          TerminalLine(
            '${_hms(e.at)} ${d.code.toLowerCase()} uniconsole-agent: ${e.message}',
            tone: switch (e.level) {
              LogSeverity.info => TerminalTone.normal,
              LogSeverity.warn => TerminalTone.warning,
              LogSeverity.error => TerminalTone.error,
            },
          ),
      ],
      final c when c.startsWith('reboot') || c.startsWith('sudo') => const [
        TerminalLine(
          '出于安全考虑，终端不允许重启或提权；请使用设备行的「重启」。',
          tone: TerminalTone.warning,
        ),
      ],
      final c => [
        TerminalLine(
          'bash: ${c.split(' ').first}: command not found',
          tone: TerminalTone.error,
        ),
      ],
    };
  }

  static String _hms(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}
