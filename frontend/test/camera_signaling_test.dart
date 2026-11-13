import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/api/api_client.dart';
import 'package:uniconsole/data/api/live_robot_repository.dart';
import 'package:uniconsole/data/models/models.dart';

void main() {
  late HttpServer server;
  late ApiClient api;
  late LiveRobotRepository repo;
  late WebSocket socket;
  late StreamSubscription<dynamic> socketEvents;
  late StreamController<Map<String, dynamic>> received;
  setUp(() async {
    received = StreamController.broadcast();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<WebSocket>();
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test-token');
      if (request.uri.path.endsWith('/ws')) {
        final ws = await WebSocketTransformer.upgrade(request);
        socketEvents = ws.listen(
          (raw) => received.add(jsonMap(jsonDecode(raw as String))),
        );
        accepted.complete(ws);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(
            request.uri.path.endsWith('/ice-servers')
                ? [
                    {
                      'urls': ['turn:relay.test'],
                      'username': 'expiring',
                      'credential': 'temporary',
                    },
                  ]
                : {
                    'meta': {
                      'sensors': {
                        'cameras': [
                          {
                            'name': 'front',
                            'detail': 'Go2 前置相机',
                            'health': 'warn',
                            'hz': 10,
                          },
                        ],
                      },
                    },
                  },
          ),
        );
        await request.response.close();
      }
    });
    api = ApiClient(
      base: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
      token: 'test-token',
    );
    repo = LiveRobotRepository(api);
    socket = await accepted.future;
    await repo
        .watchConnection()
        .firstWhere((value) => value)
        .timeout(const Duration(seconds: 3));
  });
  tearDown(() async {
    repo.dispose();
    api.close();
    await socket.close();
    await socketEvents.cancel();
    await received.close();
    await server.close(force: true);
  });

  test(
    'authenticated ICE array and real front sensor metadata are preserved',
    () async {
      expect(await repo.cameraIceServers(), [
        {
          'urls': ['turn:relay.test'],
          'username': 'expiring',
          'credential': 'temporary',
        },
      ]);
      final status = await repo.watchStatus('go2').first;
      expect(status.cameras.single.name, 'front');
      expect(status.cameras.single.detail, 'Go2 前置相机');
      expect(status.cameras.single.health, SourceHealth.degraded);
      expect(status.cameras.single.hz, 10);
    },
  );

  test(
    'shared socket sends front-only offer and routes matching session signals',
    () async {
      final messages = received.stream
          .where((e) => '${e['type']}'.startsWith('webrtc_'))
          .take(3)
          .toList();
      repo.cameraOffer('go2', 'session', 'recvonly-sdp');
      repo.cameraIce('go2', 'session', {'candidate': 'local'});
      repo.cameraClose('go2', 'session');
      expect(await messages.timeout(const Duration(seconds: 3)), [
        {
          'type': 'webrtc_offer',
          'device_id': 'go2',
          'session_id': 'session',
          'sdp': 'recvonly-sdp',
          'streams': ['front'],
        },
        {
          'type': 'webrtc_ice',
          'device_id': 'go2',
          'session_id': 'session',
          'candidate': {'candidate': 'local'},
        },
        {'type': 'webrtc_close', 'device_id': 'go2', 'session_id': 'session'},
      ]);
      final events = repo.cameraSignals('go2', 'session').take(3).toList();
      for (final (device, session) in [
        ('other', 'session'),
        ('go2', 'old'),
        ('go2', 'session'),
      ]) {
        for (final type in ['webrtc_answer', 'webrtc_ice', 'webrtc_close']) {
          socket.add(
            jsonEncode({
              'type': type,
              'device_id': device,
              'session_id': session,
              'sdp': 'answer',
            }),
          );
        }
      }
      final routed = await events.timeout(const Duration(seconds: 3));
      expect(
        routed.every(
          (e) => e['device_id'] == 'go2' && e['session_id'] == 'session',
        ),
        true,
      );
      expect(routed.map((e) => e['type']), [
        'webrtc_answer',
        'webrtc_ice',
        'webrtc_close',
      ]);
    },
  );

  test(
    'unscoped rejection reaches camera and retains command disconnect safety',
    () async {
      final error = repo.cameraSignals('go2', 'session').first;
      final disconnected = repo.watchConnection().firstWhere((value) => !value);
      socket.add(
        jsonEncode({
          'type': 'error',
          'code': 'not_implemented',
          'message': '视频尚未接入',
        }),
      );
      expect(
        (await error.timeout(const Duration(seconds: 3)))['message'],
        '视频尚未接入',
      );
      await disconnected.timeout(const Duration(seconds: 3));
      expect(() => repo.cameraOffer('go2', 'new', 'sdp'), throwsStateError);
      // No signal may be buffered and replayed after reconnect.
      repo.cameraClose('go2', 'session');
      expect(repo.connected, false);
    },
  );

  test('repository disposal notifies viewers of disconnect', () async {
    final disconnected = repo.watchConnection().firstWhere((value) => !value);
    repo.dispose();
    expect(await disconnected.timeout(const Duration(seconds: 3)), false);
  });
}
