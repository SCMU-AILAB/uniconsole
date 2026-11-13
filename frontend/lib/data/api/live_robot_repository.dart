import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'api_client.dart';

Map<String, dynamic> jsonMap(Object? value) =>
    (value as Map).cast<String, dynamic>();
List<Map<String, dynamic>> jsonRows(Object? value) =>
    (value as List).map(jsonMap).toList();
DateTime? jsonTime(Object? value) => DateTime.tryParse('$value')?.toLocal();
double number(Object? value, [double fallback = 0]) =>
    (value as num?)?.toDouble() ?? fallback;

Device deviceFromJson(Map<String, dynamic> j) => Device(
  id: j['id'],
  name: j['name'],
  code: j['code'],
  model: j['model'],
  kind: DeviceKind.values.byName(j['kind']),
  status: j['online'] == false
      ? DeviceStatus.offline
      : DeviceStatus.values.byName(j['status']),
  battery: (j['battery'] as num?)?.round(),
  latencyMs: (j['latency_ms'] as num?)?.round(),
  location: j['location'] ?? '',
  currentTask: j['current_task'] ?? '',
  groupId: j['group_id'] ?? '',
  ownerId: j['owner_id'] ?? '',
  userId: j['user_id'],
  sn: j['sn'] ?? '—',
  firmware: j['firmware'] ?? '—',
  ip: j['ip'] ?? '—',
  maxMotorTemp: (j['max_motor_temp'] as num?)?.round(),
  uptime: j['uptime_secs'] == null ? null : Duration(seconds: j['uptime_secs']),
);

Telemetry telemetryFromJson(Map<String, dynamic> j) {
  final pose = j['pose'] as Map? ?? {};
  final extra = j['extra'] as Map? ?? {};
  final unavailable = extra['unavailable'] as List? ?? [];
  double? optional(String key) =>
      unavailable.contains(key) ? null : (j[key] as num?)?.toDouble();
  List<double> values(Object? v) =>
      (v as List? ?? []).map((n) => number(n)).toList();
  return Telemetry(
    deviceId: j['device_id'],
    ts: DateTime.parse(j['ts']).toLocal(),
    latencyMs: (j['latency_ms'] as num?)?.round(),
    battery: (j['battery'] as num?)?.toDouble(),
    vx: number(j['vx']),
    vy: number(j['vy']),
    wz: number(j['wz']),
    roll: number(j['roll']) * 180 / math.pi,
    pitch: number(j['pitch']) * 180 / math.pi,
    yaw: number(j['yaw']) * 180 / math.pi,
    jointTemps: (j['joint_temps'] as List? ?? []).map(values).toList(),
    footForces: values(j['foot_forces']),
    voltage: optional('voltage'),
    current: optional('current'),
    batteryTemp: (extra['battery_temp'] as num?)?.toDouble(),
    pose: Pose(number(pose['x']), number(pose['y']), number(pose['yaw'])),
    mode: j['mode'],
    accel: values(extra['acc']),
    locConfidence: (extra['loc_confidence'] as num?)?.toDouble(),
    unavailable: unavailable.map((e) => '$e').toSet(),
  );
}

Lease leaseFromJson(Map<String, dynamic> j) => Lease(
  deviceId: j['device_id'],
  holderKind: LeaseHolderKind.values.byName(j['holder_kind']),
  holderId: j['holder_id'],
  source: j['source'] ?? '',
  acquiredAt: jsonTime(j['acquired_at']),
  expiresAt: jsonTime(j['expires_at']),
  queue: [
    for (final q in jsonRows(j['queue'] ?? []))
      LeaseRequest(
        id: q['id'],
        userId: q['user_id'],
        reason: q['reason'] ?? '',
        expectedDuration: Duration(seconds: q['expected_secs'] ?? 300),
        createdAt: DateTime.parse(q['created_at']).toLocal(),
      ),
  ],
);

/// 一条已登录会话共用实时连接；REST 负责快照与普通指令，摇杆帧不缓存、不重放。
class LiveRobotRepository
    implements
        DeviceRepository,
        TelemetryRepository,
        ControlRepository,
        LeaseRepository,
        SensorRepository {
  LiveRobotRepository(this.api) {
    unawaited(_connect());
  }
  final ApiClient api;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  final _latest = <String, Telemetry>{};
  final _localLogs = <String, List<CommandLogEntry>>{};
  final _driving = <String>{};
  WebSocket? _socket;
  HttpClient? _connectingClient;
  Timer? _retry;
  bool _disposed = false;
  String? connectionError;
  bool get connected => _socket?.readyState == WebSocket.open;

  Stream<bool> watchConnection() async* {
    yield connected;
    yield* _connection.stream;
  }

  Future<void> _connect() async {
    // 与 REST 的 IOClient 使用相同的连接方式；WebSocket.connect 默认会额外
    // 读取 shell 的 HTTP_PROXY，导致 REST 可达而实时升级被代理拒绝。
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.findProxy = (_) => 'DIRECT';
    _connectingClient = client;
    try {
      final uri = api.base.replace(
        scheme: api.base.scheme == 'https' ? 'wss' : 'ws',
        path: '${api.base.path}/ws',
      );
      final ws = await WebSocket.connect(
        uri.toString(),
        headers: {'Authorization': 'Bearer ${api.token}'},
        customClient: client,
      ).timeout(const Duration(seconds: 5));
      if (_disposed) {
        unawaited(ws.close());
        return;
      }
      _socket = ws;
      connectionError = null;
      ws.pingInterval = const Duration(seconds: 2);
      ws.add(jsonEncode({'type': 'subscribe', 'device_ids': <String>[]}));
      _connection.add(true);
      _events.add({'type': 'connected'});
      await for (final raw in ws) {
        if (_disposed) break;
        if (raw is! String) continue;
        final j = jsonMap(jsonDecode(raw));
        if (j['type'] == 'telemetry') {
          _latest[j['device_id']] = telemetryFromJson(j);
        }
        if (j['type'] == 'error') {
          for (final id in _driving.toList()) {
            _log(id, '${j['message']}');
          }
          // 权限/急停拒绝后关闭连接，让输入端清空当前按键。
          unawaited(ws.close());
        }
        _events.add(j);
      }
    } catch (e) {
      connectionError = e.toString();
      // 网络断开由连接流显示；重连后重新订阅，不重放控制帧。
    } finally {
      client.close(force: true);
      _socket = null;
      _latest.clear();
      _driving.clear();
      if (!_disposed) {
        _connection.add(false);
        _retry = Timer(const Duration(seconds: 2), _connect);
      }
    }
  }

  /// 快照 + 事件失效通知 + 定时校准，取消监听时释放定时器。
  Stream<T> poll<T>(
    Future<T> Function() read, {
    Set<String> events = const {},
  }) => Stream<T>.multi((out) {
    var cancelled = false, busy = false, again = false;
    Future<void> refresh() async {
      if (cancelled || _disposed) return;
      if (busy) {
        again = true;
        return;
      }
      busy = true;
      try {
        final value = await read();
        if (!cancelled) out.add(value);
      } catch (e, st) {
        if (!cancelled) out.addError(e, st);
      } finally {
        busy = false;
        if (again) {
          again = false;
          unawaited(refresh());
        }
      }
    }

    final sub = _events.stream.listen((e) {
      if (e['type'] == 'connected' || events.contains(e['type'])) {
        unawaited(refresh());
      }
    });
    final timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
    out.onCancel = () {
      cancelled = true;
      timer.cancel();
      unawaited(sub.cancel());
    };
    unawaited(refresh());
  });

  @override
  Stream<List<Device>> watchDevices() => poll(
    () async =>
        jsonRows(await api.get('/devices')).map(deviceFromJson).toList(),
    events: {'device_status', 'changed', 'lease_changed'},
  );
  @override
  Stream<List<DeviceGroup>> watchGroups() => poll(
    () async => [
      for (final j in jsonRows(await api.get('/device-groups')))
        DeviceGroup(id: j['id'], name: j['name'], tone: j['tone'] ?? 'neutral'),
    ],
    events: {'changed'},
  );
  String _device(String id) => '/devices/${Uri.encodeComponent(id)}';
  @override
  Stream<List<DeviceEvent>> watchEvents(String deviceId) => poll(
    () async => [
      for (final j in jsonRows(await api.get('${_device(deviceId)}/events')))
        DeviceEvent(
          deviceId: deviceId,
          at: DateTime.parse(j['at']).toLocal(),
          text: j['text'],
          tone:
              EventTone.values.where((v) => v.name == j['tone']).firstOrNull ??
              EventTone.info,
        ),
    ],
    events: {'device_event'},
  );
  @override
  Stream<Telemetry> watch(String deviceId) async* {
    final cached = _latest[deviceId];
    if (cached != null) yield cached;
    yield* _events.stream
        .where((j) => j['type'] == 'telemetry' && j['device_id'] == deviceId)
        .map(telemetryFromJson);
  }

  @override
  void move(String deviceId, double vx, double vy, double wz) {
    if (!connected || ![vx, vy, wz].every((v) => v.isFinite)) return;
    _driving.add(deviceId);
    _socket!.add(
      jsonEncode({
        'type': 'move',
        'device_id': deviceId,
        'vx': vx,
        'vy': vy,
        'wz': wz,
      }),
    );
  }

  @override
  void stop(String deviceId) {
    _driving.remove(deviceId);
    if (connected) {
      _socket!.add(jsonEncode({'type': 'stop', 'device_id': deviceId}));
    } else {
      unawaited(send(deviceId, const StopCommand()));
    }
  }

  void _log(String id, String error) {
    final logs = _localLogs.putIfAbsent(id, () => []);
    logs.insert(
      0,
      CommandLogEntry(at: DateTime.now(), text: error, ok: false, error: error),
    );
    if (logs.length > 20) logs.removeLast();
    if (!_disposed) _events.add({'type': 'local_log'});
  }

  @override
  Future<CommandResult> send(String deviceId, DeviceCommand command) async {
    try {
      final j = jsonMap(
        await api.post('${_device(deviceId)}/commands', {
          'command': command.toJson(),
        }),
      );
      if (j['ok'] == true) return const CommandResult.ok();
      final message = '${j['message'] ?? j['error'] ?? '设备没有确认指令'}';
      _log(deviceId, message);
      return CommandResult.failed(_error(j['error']));
    } on ApiException catch (e) {
      _log(deviceId, e.message);
      return CommandResult.failed(_error(e.code));
    }
  }

  CommandError _error(Object? code) => switch (code) {
    'forbidden' || 'lease_required' => CommandError.forbidden,
    'estop_active' => CommandError.estopActive,
    'robot_offline' || 'network' => CommandError.robotOffline,
    'timeout' => CommandError.timeout,
    _ => CommandError.rejected,
  };
  @override
  Stream<List<CommandLogEntry>> watchLog(String deviceId) => poll(() async {
    final entries = [
      ...?_localLogs[deviceId],
      for (final j in jsonRows(await api.get('${_device(deviceId)}/commands')))
        CommandLogEntry(
          at: DateTime.parse(j['at']).toLocal(),
          text: jsonEncode(j['command']),
          ok: j['ok'] == true,
          error: j['message'] ?? j['error'],
        ),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return entries;
  }, events: {'command_ack', 'local_log'});
  @override
  Stream<bool> watchEstop(String deviceId) => poll(
    () async => jsonMap(await api.get(_device(deviceId)))['estop'] == true,
    events: {'estop'},
  );
  @override
  Future<void> setEstop(String deviceId, {required bool active}) async {
    await api.post('${_device(deviceId)}/estop', {'active': active});
    if (!_disposed) _events.add({'type': 'estop'});
  }

  @override
  Stream<List<Lease>> watchLeases() => poll(
    () async => [
      for (final row in jsonRows(await api.get('/leases')))
        if (row['lease'] != null) leaseFromJson(jsonMap(row['lease'])),
    ],
    events: {'lease_changed', 'lease_requested'},
  );
  Future<T> _lease<T>(Future<T> Function() f) async {
    try {
      final value = await f();
      if (!_disposed) _events.add({'type': 'lease_changed'});
      return value;
    } on ApiException catch (e) {
      throw LeaseException(e.code, e.message);
    }
  }

  @override
  Future<LeaseRequestResult> acquire(String deviceId, {String? reason}) =>
      _lease(() async {
        final j = jsonMap(
          await api.post('${_device(deviceId)}/lease', {
            'reason': reason ?? '',
          }),
        );
        return j['result'] == 'granted'
            ? LeaseRequestResult.granted
            : LeaseRequestResult.queued;
      });
  @override
  Future<void> release(String deviceId) => _lease(() async {
    await api.delete('${_device(deviceId)}/lease');
  });
  @override
  Future<void> forceRelease(String deviceId, {required String reason}) =>
      _lease(() async {
        await api.delete(
          '${_device(deviceId)}/lease',
          query: {'force': 'true', 'reason': reason},
        );
      });
  @override
  Future<void> renew(String deviceId) => _lease(() async {
    await api.post('${_device(deviceId)}/lease/renew');
  });
  @override
  Future<void> transfer(String deviceId, LeaseTarget target, {String? note}) =>
      _lease(() async {
        await api.post('${_device(deviceId)}/lease/transfer', {
          'kind': target.kind.name,
          'id': target.id,
          'note': note,
        });
      });
  @override
  Future<void> approve(String deviceId, String requestId) => _lease(() async {
    await api.post('/lease-requests/${Uri.encodeComponent(requestId)}/approve');
  });
  @override
  Future<void> deny(String deviceId, String requestId) => _lease(() async {
    await api.post('/lease-requests/${Uri.encodeComponent(requestId)}/deny');
  });
  @override
  Stream<PointCloudFrame> watchPointCloud(String deviceId) =>
      const Stream.empty();
  @override
  Stream<SensorStatus> watchStatus(String deviceId) => poll(() async {
    final j = jsonMap(await api.get(_device(deviceId)));
    final sensors = (j['meta'] as Map?)?['sensors'] as Map? ?? {};
    List<SensorSource> sources(Object? list) => [
      for (final s in jsonRows(list ?? []))
        SensorSource(
          name: s['name'] ?? s['id'] ?? '',
          detail: s['detail'] ?? '',
          health: SourceHealth.idle,
          hz: (s['hz'] as num?)?.toDouble(),
        ),
    ];
    return SensorStatus(
      cameras: sources(sensors['cameras']),
      topics: sources(sensors['topics']),
      lidar: sensors['lidar'] is String ? sensors['lidar'] : '尚未接入',
    );
  });
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _connectingClient?.close(force: true);
    if (connected) {
      for (final id in _driving) {
        _socket!.add(jsonEncode({'type': 'stop', 'device_id': id}));
      }
    }
    unawaited(_socket?.close());
    unawaited(_events.close());
    unawaited(_connection.close());
  }
}
