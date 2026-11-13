import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Narrow boundary around the native peer, so signaling/lifetime tests need no
/// camera hardware or platform channels.
abstract class CameraPeer {
  void Function(Map<String, dynamic>)? onCandidate;
  void Function()? onFrame;
  void Function(String)? onFailure;
  RTCVideoRenderer? get renderer;
  Future<void> initialize(List<Map<String, dynamic>> iceServers);
  Future<String> offer();
  Future<void> answer(String sdp);
  Future<void> addCandidate(Map<String, dynamic> candidate);
  Future<void> dispose();
}

class FlutterCameraPeer extends CameraPeer {
  FlutterCameraPeer({this.relayOnly = false});
  final bool relayOnly;
  final _renderer = RTCVideoRenderer();
  RTCPeerConnection? _peer;
  final _streams = <MediaStream>{};
  bool _initialized = false;
  bool _disposed = false;
  Future<void> _trackWork = Future.value();
  Timer? _frameWatch;
  int? _decoded;
  DateTime? _lastFrame;
  bool _readingStats = false;

  @override
  RTCVideoRenderer? get renderer =>
      _initialized && !_disposed ? _renderer : null;

  @override
  Future<void> initialize(List<Map<String, dynamic>> iceServers) async {
    await _renderer.initialize();
    _initialized = true;
    _renderer.onFirstFrameRendered = () => onFrame?.call();
    final peer = _peer = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': relayOnly ? 'relay' : 'all',
    });
    peer.onIceCandidate = (c) {
      if (!_disposed && c.candidate?.isNotEmpty == true) {
        onCandidate?.call(Map<String, dynamic>.from(c.toMap()));
      }
    };
    peer.onConnectionState = (state) {
      if (_disposed) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onFailure?.call('视频连接已断开，请重试');
      }
    };
    peer.onTrack = (event) {
      if (_disposed || event.track.kind != 'video') return;
      _trackWork = _trackWork
          .then((_) async {
            if (_disposed) return;
            // Unified Plan permits streamless tracks (aiortc can emit these).
            final stream = event.streams.isNotEmpty
                ? event.streams.first
                : await createLocalMediaStream('remote-front');
            _streams.add(stream);
            if (event.streams.isEmpty) await stream.addTrack(event.track);
            if (_disposed) return;
            await _renderer.setSrcObject(
              stream: stream,
              trackId: event.track.id,
            );
          })
          .catchError((Object e) {
            if (!_disposed) onFailure?.call('无法显示视频：$e');
          });
    };
    // No getUserMedia, audio transceiver, local tracks or capture permissions.
    await peer.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    _frameWatch = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkFrames(),
    );
  }

  Future<void> _checkFrames() async {
    if (_disposed || _readingStats) return;
    _readingStats = true;
    try {
      final reports = await _peer!.getStats();
      if (_disposed) return;
      for (final report in reports) {
        final count = report.values['framesDecoded'];
        if (report.type != 'inbound-rtp' || count is! num) continue;
        if (_decoded != count.toInt()) {
          _decoded = count.toInt();
          _lastFrame = DateTime.now();
        } else if (_lastFrame != null &&
            DateTime.now().difference(_lastFrame!) >
                const Duration(seconds: 12)) {
          onFailure?.call('视频画面已中断，请重试');
        }
      }
    } catch (_) {
      // Some native backends omit frame counters. Never synthesize stats.
    } finally {
      _readingStats = false;
    }
  }

  @override
  Future<String> offer() async {
    final description = await _peer!.createOffer({
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': true},
      'optional': <Map<String, dynamic>>[],
    });
    await _peer!.setLocalDescription(description);
    final sdp = description.sdp;
    if (sdp == null || sdp.isEmpty) throw StateError('无法创建视频连接');
    return sdp;
  }

  /// Used by native integration tests to verify an actual TURN path.
  Future<bool> usesRelay() async {
    final reports = await _peer!.getStats();
    final byId = {for (final report in reports) report.id: report};
    for (final report in reports) {
      if (report.type != 'candidate-pair' ||
          report.values['state'] != 'succeeded') {
        continue;
      }
      if (report.values['nominated'] != true &&
          report.values['selected'] != true) {
        continue;
      }
      final local = byId[report.values['localCandidateId']];
      if (local?.values['candidateType'] == 'relay') return true;
    }
    return false;
  }

  @override
  Future<void> answer(String sdp) =>
      _peer!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) =>
      _peer!.addCandidate(
        RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          (candidate['sdpMLineIndex'] as num?)?.toInt(),
        ),
      );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _frameWatch?.cancel();
    onCandidate = null;
    onFrame = null;
    onFailure = null;
    await _trackWork;
    // Attempt all releases even when the native connection has already failed.
    Future<void> release(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        /* Already detached by the platform. */
      }
    }

    if (_initialized) {
      await release(() => _renderer.setSrcObject(stream: null));
    }
    final peer = _peer;
    if (peer != null) {
      await release(peer.close);
      await release(peer.dispose);
    }
    for (final stream in _streams) {
      for (final track in stream.getTracks()) {
        await release(track.stop);
      }
      await release(stream.dispose);
    }
    _streams.clear();
    if (_initialized) await release(_renderer.dispose);
  }
}
