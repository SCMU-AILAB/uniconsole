import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/destinations.dart';
import '../../core/layout/app_page.dart';
import '../../core/layout/app_route_page.dart';
import '../../core/layout/flex_columns.dart';
import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'replay_widgets.dart';

/// 录制与回放（Replay.dc.html）：录制库 + 四路同步视图 + 多轨时间轴。
///
/// 手机上 /recordings 是录制库列表，/recordings/:id 是回放页（单列）。
/// 空格播放 / 暂停，← → 前后 10 秒。
class ReplayPage extends ConsumerStatefulWidget {
  const ReplayPage({super.key, this.recordingId, this.startAt});

  final String? recordingId;

  /// 起始位置（链接里的 `?t=` 秒）；为空时停在第一个告警事件。
  final Duration? startAt;

  @override
  ConsumerState<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends ConsumerState<ReplayPage>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  /// 0–1；为空时按 [ReplayPage.startAt] / 第一个告警事件初始化。
  double? _pos;
  var _playing = false;
  var _speed = 1.0;
  (BannerKind, String)? _notice;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Recording? get _recording {
    final all = ref.read(recordingsProvider).value ?? const <Recording>[];
    return all.where((r) => r.id == widget.recordingId).firstOrNull ??
        (widget.recordingId == null ? all.firstOrNull : null);
  }

  double _initial(Recording r) {
    final ms = r.duration.inMilliseconds;
    if (ms == 0) return 0;
    final at =
        widget.startAt ??
        r.events
            .where(
              (e) =>
                  e.tone == EventTone.warning || e.tone == EventTone.critical,
            )
            .firstOrNull
            ?.offset ??
        Duration.zero;
    return (at.inMilliseconds / ms).clamp(0.0, 1.0);
  }

  /// 当前位置：用户还没拖动 / 播放过时是初始位置。
  double _at(Recording r) => _pos ?? _initial(r);

  void _tick(Duration elapsed) {
    final r = _recording;
    if (r == null || r.duration == Duration.zero) return;
    final dt = elapsed - _last;
    _last = elapsed;
    final next =
        _at(r) + dt.inMicroseconds * _speed / r.duration.inMicroseconds;
    setState(() {
      _pos = next.clamp(0.0, 1.0);
      if (next >= 1) _stop();
    });
  }

  void _stop() {
    _playing = false;
    _ticker.stop();
  }

  void _toggle() => setState(() {
    if (_playing) {
      _stop();
      return;
    }
    final r = _recording;
    if (r == null) return;
    _pos = _at(r) >= 1 ? 0 : _at(r);
    _playing = true;
    _last = Duration.zero;
    _ticker.start();
  });

  void _seek(double v) => setState(() => _pos = v);

  void _jump(int seconds) {
    final r = _recording;
    if (r == null || r.duration == Duration.zero) return;
    final ms = r.duration.inMilliseconds;
    _seek((_at(r) * ms + seconds * 1000).clamp(0, ms) / ms);
  }

  void _notify(BannerKind kind, String text) =>
      setState(() => _notice = (kind, text));

  void _open(String id) {
    final mobile = LayoutSize.ofContext(context).isMobile;
    if (mobile) {
      context.push(Routes.recording(id), extra: NavIntent.push);
    } else {
      context.go(Routes.recording(id));
    }
  }

  Future<void> _clip(Recording r) async {
    final at = r.duration * _at(r);
    var from = at - const Duration(seconds: 30);
    var to = at + const Duration(seconds: 30);
    if (from.isNegative) from = Duration.zero;
    if (to > r.duration) to = r.duration;
    final ok = await confirmAction(
      context,
      title: '剪辑片段',
      message: '截取 ${hms(from)}–${hms(to)}（当前位置前后 30 秒），另存为新录制。',
      confirmLabel: '另存为片段',
    );
    if (!ok) return;
    final id = await ref.read(recordingRepositoryProvider).clip(r.id, from, to);
    if (!mounted) return;
    _open(id);
  }

  Future<void> _share(Recording r) async {
    final at = r.duration * _at(r);
    final link = ref.read(recordingRepositoryProvider).shareLink(r.id, at);
    await Clipboard.setData(ClipboardData(text: link));
    _notify(BannerKind.success, '已复制链接，打开后从 ${hms(at)} 开始播放');
  }

  Future<void> _export(Recording r, ExportFormat f) async {
    final name = await ref.read(recordingRepositoryProvider).export(r.id, f);
    _notify(BannerKind.info, '正在导出 $name（${gb(r.sizeBytes)}），完成后在「下载」中查看');
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(recordingsProvider).value ?? const <Recording>[];
    final mobile = LayoutSize.ofContext(context).isMobile;
    final r = _recording;

    // 手机上的 /recordings：只有录制库。
    if (mobile && widget.recordingId == null) {
      return AppPage(
        title: '录制与回放',
        children: [
          RecordingLibrary(selected: null, onSelect: _open, mobile: true),
        ],
      );
    }

    if (r == null) {
      return AppPage(
        title: '录制与回放',
        largeTitle: !mobile,
        backLabel: '录制',
        children: [
          EmptyState(
            title: all.isEmpty ? '还没有录制' : '找不到该录制',
            icon: AppIcons.replay,
          ),
        ],
      );
    }

    final pos = _at(r);
    final exportMenu = AppMenu<ExportFormat>(
      options: [
        for (final f in ExportFormat.values) MenuOption(f, '导出 ${f.label}'),
      ],
      onSelected: (f) => _export(r, f),
      anchor: (context, toggle) =>
          PrimaryButton(label: '导出 MCAP / rosbag', onPressed: toggle),
    );

    final player = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReplayPanels(recording: r, position: pos),
        const SizedBox(height: AppSpacing.x3),
        ReplayControls(
          recording: r,
          position: pos,
          playing: _playing,
          speed: _speed,
          mobile: mobile,
          onToggle: _toggle,
          onSeek: _seek,
          onSpeed: (v) => setState(() => _speed = v),
        ),
      ],
    );

    final notice = Presence(
      child: _notice == null
          ? null
          : Padding(
              key: ValueKey(_notice),
              padding: const EdgeInsets.only(bottom: AppSpacing.x4),
              child: AppBanner(kind: _notice!.$1, message: _notice!.$2),
            ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _toggle,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _jump(-10),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _jump(10),
      },
      child: Focus(
        autofocus: true,
        child: AppPage(
          title: '回放 · ${r.name}',
          subtitle: recordingMeta(ref, r),
          largeTitle: !mobile,
          backLabel: '录制',
          actions: [
            SecondaryButton(label: '剪辑片段', onPressed: () => _clip(r)),
            SecondaryButton(label: '分享链接', onPressed: () => _share(r)),
            exportMenu,
          ],
          mobileActions: [
            AppMenu<int>(
              options: [
                const MenuOption(0, '剪辑片段'),
                const MenuOption(1, '分享链接'),
                for (final f in ExportFormat.values)
                  MenuOption(2 + f.index, '导出 ${f.label}'),
              ],
              onSelected: (v) => switch (v) {
                0 => _clip(r),
                1 => _share(r),
                _ => _export(r, ExportFormat.values[v - 2]),
              },
              anchor: (context, toggle) => AppIconButton(
                icon: AppIcons.more,
                label: '更多操作',
                size: AppSizes.minTouchTarget,
                onPressed: toggle,
              ),
            ),
          ],
          gap: AppSpacing.x4,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                notice,
                if (mobile) ...[
                  player,
                ] else
                  FlexColumns(
                    // 1000 宽时录制库与播放器仍并排。
                    leadingWidth: 230,
                    mainMin: 480,
                    leading: RecordingLibrary(selected: r.id, onSelect: _open),
                    main: player,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
