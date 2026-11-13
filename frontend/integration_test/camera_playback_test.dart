import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/data/api/live_auth_repository.dart';
import 'package:uniconsole/data/api/live_robot_repository.dart';
import 'package:uniconsole/data/api/token_store.dart';
import 'package:uniconsole/features/control/camera_peer.dart';
import 'package:uniconsole/features/control/camera_player.dart';

// Native-only verification. Never acquires a lease or sends robot commands.
// Supply E2E_SESSION_FILE and E2E_DEVICE with --dart-define. The session stays
// outside the repository; only its path is embedded in the test build.
const _sessionFile = String.fromEnvironment('E2E_SESSION_FILE');
const _device = String.fromEnvironment('E2E_DEVICE');
const _capture = String.fromEnvironment('E2E_CAMERA_CAPTURE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native peer offers video recvonly without audio or local capture',
    (tester) async {
      final peer = FlutterCameraPeer();
      try {
        await peer.initialize([]);
        final sdp = await peer.offer();
        expect(RegExp(r'^m=video ', multiLine: true).allMatches(sdp).length, 1);
        expect(sdp, contains('a=recvonly'));
        expect(sdp, isNot(contains('m=audio')));
        expect(sdp, isNot(contains('a=sendrecv')));
      } finally {
        await peer.dispose();
      }
    },
  );

  testWidgets('real camera renders native frames and releases on page exit', (
    tester,
  ) async {
    final store = MemoryTokenStore()
      ..session = jsonDecode(
        await File(_sessionFile).readAsString(),
      ) as Map<String, dynamic>;
    final auth = await LiveAuthRepository.restore(store);
    final api = auth.api;
    expect(api, isNotNull, reason: '需要有效的实机验证会话');
    final repo = LiveRobotRepository(api!);
    FlutterCameraPeer? peer;
    try {
      await repo
          .watchConnection()
          .firstWhere((v) => v)
          .timeout(const Duration(seconds: 15));
      final sensors = await repo.watchStatus(_device).first;
      expect(
        sensors.cameras.any((c) => c.id == 'front' || c.name == 'front'),
        true,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: CameraPlayer(
              signaling: repo,
              deviceId: _device,
              online: true,
              connected: true,
              peerFactory: () => peer = FlutterCameraPeer(),
            ),
          ),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline) &&
          (peer?.renderer?.videoWidth ?? 0) == 0) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final renderer = peer?.renderer;
      expect(renderer?.videoWidth, greaterThan(0), reason: '未收到可显示的视频帧');
      expect(renderer?.videoHeight, greaterThan(0));
      expect(renderer!.srcObject!.getAudioTracks(), isEmpty);
      // Native texture may be absent from Flutter screenshots; capture directly
      // from the received track, without local camera/screen capture permissions.
      if (_capture.isNotEmpty) {
        final bytes = await renderer.srcObject!
            .getVideoTracks()
            .single
            .captureFrame()
            .timeout(const Duration(seconds: 10));
        await File(_capture).writeAsBytes(bytes.asUint8List());
      }
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20 && peer?.renderer != null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(peer?.renderer, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
    }
  }, skip: _sessionFile.isEmpty || _device.isEmpty);
}
