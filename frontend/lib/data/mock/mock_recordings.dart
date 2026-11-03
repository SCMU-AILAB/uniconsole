import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../models/models.dart';
import '../repositories/repositories.dart';
import 'mock_data_ops.dart';
import 'mock_store.dart';

/// 录制与回放（录制由服务器按规则自动生成；这里只读、剪辑、导出）。
class MockRecordingRepository implements RecordingRepository {
  final _recordings = MockStore<List<Recording>>(MockOpsData.recordings());
  final _storage = MockStore(MockOpsData.storage);
  var _seq = 1;

  Recording? recording(String id) =>
      _recordings.value.where((r) => r.id == id).firstOrNull;

  @override
  Stream<List<Recording>> watchRecordings() => _recordings.watch();

  @override
  Stream<RecordingStorage> watchStorage() => _storage.watch();

  /// Replay.dc.html 的曲线：温度二次上升、速度在 2/3 处降速（设计稿 `rng(9)`）。
  @override
  Future<RecordingSamples> samples(String recordingId) async {
    final r = recording(recordingId);
    final source = r?.sourceId ?? recordingId;
    var s = 9 + source.codeUnits.fold(0, (a, b) => a + b) % 7;
    double rnd() {
      s = (s * 9301 + 49297) % 233280;
      return s / 233280;
    }

    final temp = <double>[], vel = <double>[];
    for (var i = 0; i <= 60; i++) {
      temp.add(100 - (80 - math.pow(i / 60, 2) * 62 + (rnd() - 0.5) * 3));
      vel.add(
        100 - (i < 40 ? 40 + math.sin(i / 2) * 6 : 72 + (rnd() - 0.5) * 4),
      );
    }
    // 点云：走廊两侧墙 + 前方墙（设计稿 160 个点，视图 8 m 宽，机器人在 50% / 55%）。
    final cloud = <Offset>[];
    for (var i = 0; i < 160; i++) {
      final r = rnd();
      final x = r < 0.35 ? 24 : (r < 0.7 ? 76 : 24 + rnd() * 52);
      final y = r < 0.7 ? 8 + rnd() * 88 : 10.0;
      final px = x + (rnd() - 0.5) * 1.5, py = y + (rnd() - 0.5) * 2;
      cloud.add(Offset((px - 50) / 100 * 8, (55 - py) / 100 * 8));
    }
    return RecordingSamples(
      chartTitle: source == 'r1' ? 'RL_calf 温度 · 速度' : '最高电机温度 · 速度',
      temperature: temp,
      velocity: vel,
      trajectory: MockOpsData.trajectories[source] ?? const [],
      cloud: cloud,
    );
  }

  @override
  Future<String> clip(String recordingId, Duration from, Duration to) async {
    final r = recording(recordingId);
    if (r == null) throw StateError('录制 $recordingId 不存在');
    if (to <= from) throw ArgumentError('片段结束时间必须晚于开始时间');
    final total = r.duration.inMilliseconds;
    final f = from.inMilliseconds / total, t = to.inMilliseconds / total;
    double map(double x) => ((x - f) / (t - f)).clamp(0.0, 1.0);
    final id = '${r.id}-clip${_seq++}';
    final clip = Recording(
      id: id,
      name: '${r.name} · 片段',
      deviceIds: r.deviceIds,
      start: r.start.add(from),
      end: r.start.add(to),
      sizeBytes: (r.sizeBytes * (t - f)).round(),
      tags: {...r.tags, RecordingTag.manual}.toList(),
      mapId: r.mapId,
      sourceId: r.sourceId ?? r.id,
      events: [
        for (final e in r.events)
          if (e.offset >= from && e.offset <= to)
            RecordingEvent(e.offset - from, e.label, tone: e.tone),
      ],
      tracks: [
        for (final tr in r.tracks)
          RecordingTrack(tr.kind, [
            for (final (a, b) in tr.segments)
              if (b > f && a < t) (map(a), map(b)),
          ]),
      ],
    );
    _recordings.value = [clip, ..._recordings.value];
    _storage.value = RecordingStorage(
      usedBytes: _storage.value.usedBytes + clip.sizeBytes,
      totalBytes: _storage.value.totalBytes,
      retention: _storage.value.retention,
      autoRules: _storage.value.autoRules,
    );
    return id;
  }

  @override
  Future<String> export(String recordingId, ExportFormat format) async {
    final r = recording(recordingId);
    final d = r?.start ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${r?.deviceIds.length == 1 ? r!.deviceIds.first : 'fleet'}_'
        '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}'
        '.${format.extension}';
  }

  @override
  String shareLink(String recordingId, Duration at) =>
      'https://uniconsole.local/recordings/$recordingId?t=${at.inSeconds}';
}
