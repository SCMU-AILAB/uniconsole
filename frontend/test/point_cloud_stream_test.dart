import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/data/api/api_client.dart';
import 'package:uniconsole/data/api/live_robot_repository.dart';

Uint8List frame(String id, {double x = 1, double y = -2}) {
  final name = utf8.encode(id);
  final data = Uint8List(1 + name.length + 16);
  data[0] = name.length;
  data.setRange(1, 1 + name.length, name);
  final view = ByteData.sublistView(data);
  view.setInt64(
    1 + name.length,
    DateTime.now().millisecondsSinceEpoch,
    Endian.little,
  );
  view.setFloat32(9 + name.length, x, Endian.little);
  view.setFloat32(13 + name.length, y, Endian.little);
  return data;
}

void main() {
  test('binary envelope rejects malformed payloads and preserves signed coordinates', () {
    final decoded = decodePointCloud(frame('狗'))!;
    expect(decoded.deviceId, '狗');
    expect(decoded.frame.points.single.dx, 1);
    expect(decoded.frame.points.single.dy, -2);
    expect(decodePointCloud([255, 1, 2]), isNull);
    expect(decodePointCloud(frame('dog').sublist(0, 18)), isNull);
    expect(
      decodePointCloud(frame('dog', x: double.nan))!.frame.points,
      isEmpty,
    );
  });

  test('shared subscriptions filter devices, expire stale points, and disable only after last viewer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<WebSocket>();
    final received = <Map<String, dynamic>>[];
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((raw) => received.add(jsonDecode(raw as String)));
      accepted.complete(ws);
    });
    final api = ApiClient(
      base: Uri.parse('http://127.0.0.1:${server.port}/api/v1'),
      token: 'test',
    );
    final repo = LiveRobotRepository(api);
    final values = <bool>[];
    final first = repo
        .watchPointCloud('dog')
        .listen((frame) => values.add(frame.available));
    final second = repo.watchPointCloud('dog').listen((_) {});
    try {
      final ws = await accepted.future;
      await repo.watchConnection().firstWhere((online) => online);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        received
            .where((j) => j['type'] == 'pointcloud' && j['enable'] == true)
            .length,
        1,
      );
      ws.add(frame('other'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(values.contains(true), false);
      ws.add(frame('dog'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(values.last, true);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(values.last, false);
      await first.cancel();
      expect(received.where((j) => j['enable'] == false), isEmpty);
      await second.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(received.where((j) => j['enable'] == false).length, 1);
      final closed = Completer<void>();
      repo.watchPointCloud('dog').listen((_) {}, onDone: closed.complete);
      repo.dispose();
      await closed.future.timeout(const Duration(seconds: 1));
    } finally {
      await first.cancel();
      await second.cancel();
      repo.dispose();
      api.close();
      await server.close(force: true);
    }
  });
}
