import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import '../../data/repositories/camera_signaling.dart';
import 'camera_peer.dart';
import 'camera_session.dart';

final cameraPeerFactoryProvider = Provider<CameraPeer Function()>(
  (ref) => FlutterCameraPeer.new,
);

/// Both control layouts use the same robot-advertised front camera capability.
class CameraFeed extends ConsumerWidget {
  const CameraFeed({super.key, required this.deviceId, required this.online});
  final String deviceId;
  final bool online;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signaling = ref.watch(liveRobotProvider);
    final status = ref.watch(sensorStatusProvider(deviceId));
    final front =
        status.value?.cameras.any(
          (camera) => camera.id == 'front' || camera.name == 'front',
        ) ??
        false;
    if (signaling == null) return const _CameraMessage('演示模式 · 无实时视频');
    if (!front) {
      return _CameraMessage(
        !online
            ? '设备离线'
            : status.hasError
            ? '无法读取相机信息：${status.error}'
            : status.isLoading
            ? '正在读取相机信息…'
            : '设备未提供前置相机',
      );
    }
    return CameraPlayer(
      signaling: signaling,
      deviceId: deviceId,
      online: online,
      connected: ref.watch(controlConnectionProvider).value ?? false,
      peerFactory: ref.watch(cameraPeerFactoryProvider),
    );
  }
}

class CameraPlayer extends StatefulWidget {
  const CameraPlayer({
    super.key,
    required this.signaling,
    required this.deviceId,
    required this.online,
    required this.connected,
    required this.peerFactory,
  });
  final CameraSignaling signaling;
  final String deviceId;
  final bool online, connected;
  final CameraPeer Function() peerFactory;

  @override
  State<CameraPlayer> createState() => _CameraPlayerState();
}

class _CameraPlayerState extends State<CameraPlayer>
    with WidgetsBindingObserver {
  CameraSession? _session;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _active = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _start();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _start() {
    if (!_active || !widget.online || !widget.connected) return;
    _release();
    _session = CameraSession(
      signaling: widget.signaling,
      deviceId: widget.deviceId,
      peer: widget.peerFactory(),
    )..addListener(_changed);
    _session!.start();
  }

  void _release() {
    _session?.removeListener(_changed);
    _session?.dispose();
    _session = null;
  }

  @override
  void didUpdateWidget(CameraPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.signaling != widget.signaling ||
        oldWidget.deviceId != widget.deviceId ||
        oldWidget.online != widget.online) {
      _release();
      _start();
    } else if (_session == null && widget.connected) {
      _start();
    }
    // Failed attempts keep their reason visible across WS reconnection; retry
    // is explicit, avoiding loops on unsupported devices or viewer limits.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (_active) {
      _start();
    } else {
      _release();
    }
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final renderer = session?.ready == true ? session!.peer.renderer : null;
    final playing = session?.phase == CameraPhase.playing;
    return ColoredBox(
      color: context.colors.videoBackground,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (renderer != null)
            RTCVideoView(
              renderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            ),
          if (!playing)
            _CameraMessage(
              !_active
                  ? '视频已暂停'
                  : !widget.online
                  ? '设备离线'
                  : session?.message ?? '等待实时连接…',
              retry:
                  _active &&
                      widget.online &&
                      widget.connected &&
                      session?.phase == CameraPhase.failed
                  ? () {
                      _start();
                      _changed();
                    }
                  : null,
            ),
        ],
      ),
    );
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage(this.message, {this.retry});
  final String message;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.type.subhead.copyWith(color: context.colors.hudText),
          ),
          if (retry != null) ...[
            const SizedBox(height: AppSpacing.x2),
            Pressable(
              onTap: retry,
              semanticLabel: '重试视频',
              builder: (context, state) => Container(
                constraints: const BoxConstraints(minWidth: 88, minHeight: 44),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
                decoration: BoxDecoration(
                  color: state.pressed
                      ? context.colors.hudSelected
                      : context.hudOverlay,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Text(
                  '重试视频',
                  style: context.type.subhead.copyWith(
                    color: context.colors.hudText,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
