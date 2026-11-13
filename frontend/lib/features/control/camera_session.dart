import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../data/repositories/camera_signaling.dart';
import 'camera_peer.dart';

enum CameraPhase { connecting, playing, failed, closed }

/// One viewing attempt. A retry always creates a fresh peer and session id;
/// old SDP/ICE is never replayed after a socket reconnect.
class CameraSession extends ChangeNotifier {
  CameraSession({
    required this.signaling,
    required this.deviceId,
    required this.peer,
    this.connectTimeout = const Duration(seconds: 30),
  }) : sessionId = List.generate(
         16,
         (_) => Random.secure().nextInt(256),
       ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final CameraSignaling signaling;
  final String deviceId;
  final String sessionId;
  final CameraPeer peer;
  final Duration connectTimeout;
  CameraPhase phase = CameraPhase.connecting;
  String message = '正在连接前置相机…';
  bool ready = false;
  bool _started = false, _stopped = false, _disposed = false;
  bool _offered = false, _answered = false;
  final _localIce = <Map<String, dynamic>>[];
  final _remoteIce = <Map<String, dynamic>>[];
  StreamSubscription<Map<String, dynamic>>? _signals;
  StreamSubscription<bool>? _connection;
  Timer? _timeout;
  Future<void> _work = Future.value();
  Future<void>? _closing;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _enqueue(Future<void> Function() action) {
    _work = _work
        .then((_) async {
          if (!_stopped) await action();
        })
        .catchError((Object e) {
          fail('视频连接失败：$e');
        });
  }

  void start() {
    if (_started || _stopped) return;
    _started = true;
    _signals = signaling
        .cameraSignals(deviceId, sessionId)
        .listen(
          (event) {
            // Close/error must cancel initialization immediately, even while native
            // calls or ICE-server REST are in flight.
            if (event['type'] == 'webrtc_close' || event['type'] == 'error') {
              fail(
                '${event['reason'] ?? event['message'] ?? '视频会话已结束'}',
                notifyRemote: event['type'] != 'webrtc_close',
              );
            } else {
              _enqueue(() => _signal(event));
            }
          },
          onError: (Object e) => fail('视频信令失败：$e'),
          onDone: () => fail('实时连接已关闭', notifyRemote: false),
        );
    _connection = signaling.watchConnection().listen((connected) {
      if (!connected) fail('实时连接已断开', notifyRemote: false);
    }, onDone: () => fail('实时连接已关闭', notifyRemote: false));
    peer.onCandidate = (candidate) {
      if (_stopped) return;
      // setLocalDescription can emit candidates before the offer is sent.
      if (!_offered) {
        _localIce.add(candidate);
        return;
      }
      try {
        signaling.cameraIce(deviceId, sessionId, candidate);
      } catch (e) {
        fail('视频信令失败：$e');
      }
    };
    peer.onFrame = () {
      if (_stopped) return;
      _timeout?.cancel();
      phase = CameraPhase.playing;
      message = '前置相机';
      _notify();
    };
    peer.onFailure = fail;
    _timeout = Timer(connectTimeout, () => fail('视频连接超时，请重试'));
    _enqueue(() async {
      if (!signaling.connected) throw StateError('实时连接已断开');
      final servers = await signaling.cameraIceServers();
      if (_stopped) return;
      await peer.initialize(servers);
      if (_stopped) return;
      ready = true;
      _notify();
      final sdp = await peer.offer();
      if (_stopped) return;
      signaling.cameraOffer(deviceId, sessionId, sdp);
      _offered = true;
      for (final candidate in _localIce) {
        signaling.cameraIce(deviceId, sessionId, candidate);
      }
      _localIce.clear();
    });
  }

  Future<void> _signal(Map<String, dynamic> event) async {
    switch (event['type']) {
      case 'webrtc_answer':
        if (_answered) return;
        final sdp = event['sdp'];
        if (sdp is! String || sdp.isEmpty) {
          throw const FormatException('视频应答为空');
        }
        await peer.answer(sdp);
        if (_stopped) return;
        _answered = true;
        final candidates = _remoteIce.toList();
        _remoteIce.clear();
        for (final candidate in candidates) {
          if (_stopped) return;
          await peer.addCandidate(candidate);
        }
      case 'webrtc_ice':
        final raw = event['candidate'];
        // End-of-candidates is already carried by aiortc's gathered answer.
        if (raw == null) return;
        final candidate = Map<String, dynamic>.from(raw as Map);
        if (candidate['candidate'] == null || candidate['candidate'] == '') {
          return;
        }
        if (_answered) {
          await peer.addCandidate(candidate);
        } else {
          _remoteIce.add(candidate);
        }
    }
  }

  void fail(String reason, {bool notifyRemote = true}) {
    if (_stopped) return;
    phase = CameraPhase.failed;
    message = reason;
    unawaited(close(notifyRemote: notifyRemote));
  }

  Future<void> close({bool notifyRemote = true}) {
    if (_closing != null) return _closing!;
    _stopped = true;
    ready = false; // Immediately remove the texture; never leave a stale frame.
    _timeout?.cancel();
    if (phase != CameraPhase.failed) phase = CameraPhase.closed;
    if (_offered && notifyRemote) {
      try {
        signaling.cameraClose(deviceId, sessionId);
      } catch (_) {
        /* Offline. */
      }
    }
    _localIce.clear();
    _remoteIce.clear();
    final cancelled = Future.wait([
      if (_signals != null) _signals!.cancel(),
      if (_connection != null) _connection!.cancel(),
    ]);
    // Let in-flight native allocations finish before disposing their resources.
    _closing = _work.then((_) async {
      await cancelled;
      await peer.dispose();
    });
    _notify();
    return _closing!;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
