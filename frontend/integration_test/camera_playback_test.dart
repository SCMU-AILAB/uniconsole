import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/core/widgets/point_cloud_view.dart';
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
const _relayOnly = bool.fromEnvironment('E2E_RELAY_ONLY');
const _lidarCapture = String.fromEnvironment('E2E_LIDAR_CAPTURE');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
      debugPrint('camera e2e: waiting for signaling');
      await repo
          .watchConnection()
          .firstWhere((v) => v)
          .timeout(const Duration(seconds: 15));
      final sensors = await repo.watchStatus(_device).first;
      debugPrint('camera e2e: received device status');
      expect(
        sensors.cameras.any((c) => c.id == 'front' || c.name == 'front'),
        true,
      );
      // A separate normal app window may own focus during automated runs.
      // Set the test lifecycle explicitly; production focus handling is intact.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      debugPrint('camera e2e: mounting video');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: CameraPlayer(
              signaling: repo,
              deviceId: _device,
              online: true,
              connected: true,
              peerFactory: () =>
                  peer = FlutterCameraPeer(relayOnly: _relayOnly),
            ),
          ),
        ),
      );
      debugPrint('camera e2e: mounted video');
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (DateTime.now().isBefore(deadline) &&
          (peer?.renderer?.videoWidth ?? 0) == 0) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final renderer = peer?.renderer;
      debugPrint('camera e2e: received frame ${renderer?.videoWidth}');
      expect(renderer?.videoWidth, greaterThan(0), reason: '未收到可显示的视频帧');
      expect(renderer?.videoHeight, greaterThan(0));
      expect(renderer!.srcObject!.getAudioTracks(), isEmpty);
      if (_relayOnly) {
        expect(await peer!.usesRelay(), true, reason: '必须实际使用 TURN 中继');
      }
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

  testWidgets(
    'real lidar streams through public backend and renders top view',
    (tester) async {
      final store = MemoryTokenStore()
        ..session = jsonDecode(
          await File(_sessionFile).readAsString(),
        ) as Map<String, dynamic>;
      final auth = await LiveAuthRepository.restore(store);
      final repo = LiveRobotRepository(auth.api!);
      try {
        final frames = await repo
            .watchPointCloud(_device)
            .where((f) => f.available)
            .take(3)
            .toList()
            .timeout(const Duration(seconds: 15));
        expect(frames.last.points, isNotEmpty);
        expect(frames.last.points.length, lessThanOrEqualTo(6000));
        expect(frames.last.ts.isAfter(frames.first.ts), true);
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: PointCloudView(
                  points: frames.last.points,
                  rings: const [1, 2, 4],
                  rangeMeters: 8,
                  showHeading: true,
                  label: 'Go2 实时雷达点云',
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        if (_lidarCapture.isNotEmpty) {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(_lidarCapture).writeAsBytes(data!.buffer.asUint8List());
        }
        await tester.pumpWidget(const SizedBox());
      } finally {
        repo.dispose();
        auth.api?.close();
      }
    },
    skip: _sessionFile.isEmpty || _device.isEmpty,
  );
}
