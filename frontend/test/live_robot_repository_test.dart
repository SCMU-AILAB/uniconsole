import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uniconsole/data/api/api_client.dart';
import 'package:uniconsole/data/api/live_robot_repository.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/repositories/repositories.dart';

void main() {
  test('real telemetry converts angles and preserves unavailable sensors', () {
    final tm = telemetryFromJson({
      'device_id': 'dog',
      'ts': '2026-11-13T00:00:00Z',
      'roll': pi / 2,
      'pitch': -pi / 4,
      'yaw': pi,
      'pose': {'x': 1, 'y': 2, 'yaw': pi},
      'joint_temps': [],
      'foot_forces': [],
      'battery': null,
    });
    expect(tm.roll, closeTo(90, 0.001));
    expect(tm.pitch, closeTo(-45, 0.001));
    expect(tm.pose.yaw, pi);
    expect(tm.battery, isNull);
    expect(tm.maxJointTemp, isNull);
    expect(tm.jointTemp(3, 2), isNull);
    expect(tm.footForce(3), isNull);
    expect(tm.accel, isEmpty);
  });

  test(
    'authenticated websocket subscribes, streams telemetry and sends frames',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<WebSocket>();
      final messages = <Map<String, dynamic>>[];
      server.listen((req) async {
        expect(req.uri.path, '/api/v1/ws');
        expect(req.headers.value('authorization'), 'Bearer test-token');
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((raw) {
          final j = jsonDecode(raw as String) as Map<String, dynamic>;
          messages.add(j);
          if (j['type'] == 'subscribe') {
            ws.add(
              jsonEncode({
                'type': 'telemetry',
                'device_id': 'dog',
                'ts': '2026-11-13T00:00:00Z',
                'vx': 0.12,
              }),
            );
          }
        });
        accepted.complete(ws);
      });
      final api = ApiClient(
        base: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
        token: 'test-token',
      );
      final repo = LiveRobotRepository(api);
      final states = <bool>[];
      final sub = repo.watchConnection().listen(states.add);
      try {
        final tm = await repo
            .watch('dog')
            .first
            .timeout(const Duration(seconds: 3));
        expect(tm.vx, 0.12);
        repo.move('dog', 0.1, 0, 0);
        repo.stop('dog');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(messages.map((j) => j['type']), ['subscribe', 'move', 'stop']);
        final ws = await accepted.future;
        await ws.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(states.last, false);
        repo.move('dog', 0.3, 0, 0);
        expect(messages.length, 3); // 断线后的移动不得排队。
      } finally {
        repo.dispose();
        await sub.cancel();
        api.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'REST command failures and lease outcomes use server responses',
    () async {
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/commands')) {
          expect(jsonDecode(r.body)['command'], {'kind': 'stop'});
          return http.Response(
            jsonEncode({
              'ok': false,
              'error': 'robot_error',
              'message': 'SDK rejected',
            }),
            200,
          );
        }
        if (r.url.path.endsWith('/transfer')) {
          expect(jsonDecode(r.body), {
            'kind': 'user',
            'id': 'member',
            'note': 'test',
          });
          return http.Response('{}', 200);
        }
        return http.Response('{"result":"granted","lease":{}}', 200);
      });
      final api = ApiClient(
        base: Uri.parse('http://127.0.0.1:1/api/v1'),
        token: 't',
        client: client,
      );
      final repo = LiveRobotRepository(api);
      try {
        expect(
          (await repo.send('dog', const StopCommand())).error,
          CommandError.rejected,
        );
        expect(await repo.acquire('dog'), LeaseRequestResult.granted);
        await repo.transfer(
          'dog',
          const LeaseTarget.user('member'),
          note: 'test',
        );
      } finally {
        repo.dispose();
        client.close();
      }
    },
  );
}
