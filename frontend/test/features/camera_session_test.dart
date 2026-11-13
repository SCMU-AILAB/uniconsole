import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/data/repositories/camera_signaling.dart';
import 'package:uniconsole/features/control/camera_peer.dart';
import 'package:uniconsole/features/control/camera_player.dart';
import 'package:uniconsole/features/control/camera_session.dart';

class FakeSignaling implements CameraSignaling {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final connection = StreamController<bool>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  @override
  bool connected = true;
  Object? iceFailure;
  final servers = <Map<String, dynamic>>[
    {
      'urls': ['stun:example.test'],
    },
  ];
  @override
  Future<List<Map<String, dynamic>>> cameraIceServers() async {
    if (iceFailure != null) throw iceFailure!;
    return servers;
  }

  @override
  Stream<bool> watchConnection() => connection.stream;
  @override
  Stream<Map<String, dynamic>> cameraSignals(
    String deviceId,
    String sessionId,
  ) => events.stream.where((e) => e['session_id'] == sessionId);
  @override
  void cameraOffer(String deviceId, String sessionId, String sdp) => sent.add({
    'type': 'offer',
    'device_id': deviceId,
    'session_id': sessionId,
    'sdp': sdp,
  });
  @override
  void cameraIce(
    String deviceId,
    String sessionId,
    Map<String, dynamic> candidate,
  ) => sent.add({
    'type': 'ice',
    'session_id': sessionId,
    'candidate': candidate,
  });
  @override
  void cameraClose(String deviceId, String sessionId) => sent.add({
    'type': 'close',
    'device_id': deviceId,
    'session_id': sessionId,
  });
  void emit(CameraSession session, Map<String, dynamic> event) => events.add({
    'device_id': session.deviceId,
    'session_id': session.sessionId,
    ...event,
  });
  Future<void> dispose() async {
    await events.close();
    await connection.close();
  }
}

class FakePeer extends CameraPeer {
  final calls = <String>[];
  List<Map<String, dynamic>>? iceServers;
  Completer<void>? initialization;
  @override
  RTCVideoRenderer? get renderer => null;
  @override
  Future<void> initialize(List<Map<String, dynamic>> servers) async {
    iceServers = servers;
    calls.add('initialize');
    await initialization?.future;
  }

  @override
  Future<String> offer() async {
    calls.add('offer');
    onCandidate?.call({
      'candidate': 'local',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    return 'recvonly-offer';
  }

  @override
  Future<void> answer(String sdp) async {
    calls.add('answer:$sdp');
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {
    calls.add('ice:${candidate['candidate']}');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeSignaling signaling;
  late FakePeer peer;
  late CameraSession session;
  setUp(() {
    signaling = FakeSignaling();
    peer = FakePeer();
    session = CameraSession(signaling: signaling, deviceId: 'go2', peer: peer);
  });
  tearDown(() async {
    await session.close();
    session.dispose();
    await signaling.dispose();
  });

  test('offer precedes local ICE; remote ICE waits for answer; first frame marks playing', () async {
    session.start();
    await flush();
    expect(peer.iceServers, signaling.servers);
    expect(signaling.sent.map((e) => e['type']), ['offer', 'ice']);
    expect(signaling.sent.first['device_id'], 'go2');
    expect(session.phase, CameraPhase.connecting);
    signaling.emit(session, {
      'type': 'webrtc_ice',
      'candidate': {'candidate': 'remote'},
    });
    await flush();
    expect(peer.calls, ['initialize', 'offer']);
    signaling.emit(session, {'type': 'webrtc_answer', 'sdp': 'answer'});
    await flush();
    expect(peer.calls, ['initialize', 'offer', 'answer:answer', 'ice:remote']);
    peer.onFrame!();
    expect(session.phase, CameraPhase.playing);
    await session.close();
    await session.close();
    expect(session.ready, false);
    expect(peer.calls.where((c) => c == 'dispose').length, 1);
    expect(signaling.sent.where((e) => e['type'] == 'close').length, 1);
    expect(signaling.events.hasListener, false);
    expect(signaling.connection.hasListener, false);
  });

  test(
    'robot rejection is visible and does not echo close or accept late frames',
    () async {
      session.start();
      await flush();
      signaling.emit(session, {
        'type': 'webrtc_close',
        'reason': '已达到 2 个观看者上限',
      });
      await session.close();
      peer.onFrame?.call();
      expect(session.phase, CameraPhase.failed);
      expect(session.message, '已达到 2 个观看者上限');
      expect(signaling.sent.where((e) => e['type'] == 'close'), isEmpty);
      expect(peer.calls.last, 'dispose');
    },
  );

  test(
    'signaling error closes the offered session and surfaces server message',
    () async {
      session.start();
      await flush();
      signaling.emit(session, {'type': 'error', 'message': '该设备的视频尚未接入'});
      await session.close();
      expect(session.message, '该设备的视频尚未接入');
      expect(session.phase, CameraPhase.failed);
      expect(signaling.sent.last['type'], 'close');
    },
  );

  test('disconnect tears down without signaling over a new socket', () async {
    session.start();
    await flush();
    signaling.connected = false;
    signaling.connection.add(false);
    await session.close();
    signaling.connected = true;
    signaling.connection.add(true);
    expect(session.phase, CameraPhase.failed);
    expect(peer.calls.last, 'dispose');
    expect(signaling.sent.map((e) => e['type']), ['offer', 'ice']);
  });

  test('dispose while native initialization is pending releases late allocations without offer', () async {
    final initialized = peer.initialization = Completer<void>();
    session.start();
    await flush();
    expect(peer.calls, ['initialize']);
    session.dispose();
    initialized.complete();
    await session.close();
    expect(peer.calls, ['initialize', 'dispose']);
    expect(signaling.sent, isEmpty);
  });

  test(
    'ICE endpoint failure releases peer and does not send an offer',
    () async {
      signaling.iceFailure = StateError('TURN unavailable');
      session.start();
      await flush();
      await session.close();
      expect(session.phase, CameraPhase.failed);
      expect(session.message, contains('TURN unavailable'));
      expect(peer.calls, ['dispose']);
      expect(signaling.sent, isEmpty);
    },
  );

  test(
    'timeout bounds negotiation and late answers cannot revive closed session',
    () async {
      session.dispose();
      session = CameraSession(
        signaling: signaling,
        deviceId: 'go2',
        peer: peer,
        connectTimeout: const Duration(milliseconds: 10),
      );
      session.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await session.close();
      signaling.emit(session, {'type': 'webrtc_answer', 'sdp': 'late'});
      expect(session.phase, CameraPhase.failed);
      expect(session.message, contains('超时'));
      expect(peer.calls, isNot(contains('answer:late')));
    },
  );

  testWidgets(
    'background and page disposal close; resume creates a fresh session',
    (tester) async {
      final peers = <FakePeer>[];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: CameraPlayer(
            signaling: signaling,
            deviceId: 'go2',
            online: true,
            connected: true,
            peerFactory: () {
              final peer = FakePeer();
              peers.add(peer);
              return peer;
            },
          ),
        ),
      );
      await tester.pump();
      expect(signaling.sent.where((e) => e['type'] == 'offer').length, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.runAsync(flush);
      await tester.pump();
      expect(peers.first.calls.last, 'dispose');
      expect(signaling.sent.last['type'], 'close');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      final offers = signaling.sent.where((e) => e['type'] == 'offer').toList();
      expect(offers.length, 2);
      expect(offers.first['session_id'], isNot(offers.last['session_id']));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(flush);
      await tester.pump();
      expect(peers.last.calls.last, 'dispose');
      expect(signaling.events.hasListener, false);
    },
  );
}
