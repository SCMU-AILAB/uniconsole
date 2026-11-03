import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import 'safety_page.dart';

/// 围栏类型的主色（边框、色块）。
Color zoneColor(BuildContext context, ZoneType type) {
  final s = context.status;
  return switch (type) {
    ZoneType.ban => s.critical.dot,
    ZoneType.slow => s.warning.dot,
    ZoneType.whitelist => s.action.dot,
    ZoneType.wall => context.colors.mapWall,
  };
}

StatusSwatch? _swatch(BuildContext context, ZoneType type) {
  final s = context.status;
  return switch (type) {
    ZoneType.ban => s.critical,
    ZoneType.slow => s.warning,
    ZoneType.whitelist => s.action,
    ZoneType.wall => null,
  };
}

/// 电子围栏编辑器（Safety.dc.html 地图）：点选围栏、拖动角点调整、工具栏新建。
class ZoneEditor extends ConsumerWidget {
  const ZoneEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    final zones = ref.watch(zonesProvider).value ?? const <Zone>[];
    final map = ref.watch(siteMapProvider).value;
    final ui = ref.watch(safetyUiProvider);
    final uiNotifier = ref.read(safetyUiProvider.notifier);
    final repo = ref.read(safetyRepositoryProvider);
    final devices = {
      for (final d in ref.watch(devicesProvider).value ?? const <Device>[])
        d.id: d,
    };
    final leaders = {
      for (final s in ref.watch(fleetSessionsProvider).value ?? const [])
        ?s.leaderId,
    };
    final mobile = LayoutSize.ofContext(context).isMobile;

    Zone current(Zone z) => ui.draft?.id == z.id ? ui.draft! : z;

    Future<void> add(ZoneType type) async {
      final id = await repo.addZone(type);
      uiNotifier.select(id);
    }

    Widget tool(String label, ZoneType type) {
      final sw = _swatch(context, type);
      return Pressable(
        onTap: () => add(type),
        semanticLabel: type == ZoneType.wall ? '添加虚拟墙' : '添加${type.label}',
        focusRadius: AppRadius.xs,
        builder: (context, st) => AnimatedContainer(
          duration: AppMotion.fade(pressed: st.pressed),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
          decoration: BoxDecoration(
            color: Color.lerp(
              sw?.bg ?? c.fillSecondary,
              c.stateOverlay,
              st.pressed ? 0.1 : 0,
            ),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: t.subhead.copyWith(color: sw?.fg ?? c.label),
            ),
          ),
        ),
      );
    }

    final tools = MapOverlayPanel(
      child: Wrap(
        spacing: AppSpacing.x1,
        runSpacing: AppSpacing.x1,
        children: [
          tool('＋ 禁入区', ZoneType.ban),
          tool('＋ 限速区', ZoneType.slow),
          tool('＋ 白名单区', ZoneType.whitelist),
          tool('虚拟墙', ZoneType.wall),
        ],
      ),
    );

    final editor = SizedBox(
      height: mobile ? 360 : 470,
      child: FloorMapView(
        semanticLabel: '电子围栏 · ${map?.name ?? ''}',
        rooms: const [MapRoom(Rect.fromLTRB(6, 8, 94, 92), filled: false)],
        layer: (context, size) {
          final w = size.width, h = size.height;
          Rect px(Rect r) => Rect.fromLTRB(
            r.left / 100 * w,
            r.top / 100 * h,
            r.right / 100 * w,
            r.bottom / 100 * h,
          );
          final selected = zones
              .where((z) => z.id == ui.selected)
              .map(current)
              .firstOrNull;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // 允许作业区：绿色虚线框。
              Positioned.fromRect(
                rect: px(const Rect.fromLTRB(8, 11, 92, 89)),
                child: IgnorePointer(
                  child: CustomPaint(painter: _DashedRectPainter(s.online.dot)),
                ),
              ),
              Positioned.fromRect(
                // 地图百分比坐标 (9%, 13%)。
                rect: px(const Rect.fromLTWH(9, 13, 30, 4)),
                child: Text(
                  '允许作业区',
                  style: t.captionStrong.copyWith(color: s.online.fg),
                ),
              ),
              for (final z in zones.map(current))
                Positioned.fromRect(
                  rect: px(z.rect),
                  child: _ZoneBox(
                    zone: z,
                    selected: z.id == ui.selected,
                    onTap: () => uiNotifier.select(z.id),
                  ),
                ),
              for (final e in (map?.devicePositions ?? const {}).entries)
                if (devices[e.key] case final d?)
                  Positioned(
                    left: e.value.dx / 100 * w - 40,
                    top: e.value.dy / 100 * h - 7,
                    width: 80,
                    child: IgnorePointer(
                      child: _BotDot(
                        name: d.name,
                        color: d.status == DeviceStatus.alert
                            ? s.warning.dot
                            : leaders.contains(d.id)
                            ? c.accent
                            : c.mapMarker,
                      ),
                    ),
                  ),
              if (selected != null)
                for (final corner in _Corner.values)
                  _Handle(
                    key: ValueKey('${selected.id}-${corner.name}'),
                    zone: selected,
                    corner: corner,
                    mapSize: size,
                    onDrag: uiNotifier.drag,
                    onEnd: (z) async {
                      await repo.updateZone(z);
                      uiNotifier.endDrag();
                    },
                  ),
            ],
          );
        },
        overlays: [
          if (!mobile)
            Positioned(
              left: AppSpacing.x4,
              bottom: AppSpacing.x4,
              right: AppSpacing.x4,
              child: Align(alignment: Alignment.bottomLeft, child: tools),
            ),
          Positioned(
            right: AppSpacing.x4,
            top: AppSpacing.x3,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x2,
                vertical: AppSpacing.half,
              ),
              decoration: BoxDecoration(
                color: c.mapOverlay,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${map?.name ?? ''} · 拖动角点调整围栏',
                style: t.caption.copyWith(color: c.secondaryLabel),
              ),
            ),
          ),
        ],
      ),
    );
    // 手机上地图较矮，工具栏放到地图下方，不遮挡围栏。
    if (!mobile) return editor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        editor,
        const SizedBox(height: AppSpacing.x2),
        tools,
      ],
    );
  }
}

class _ZoneBox extends StatelessWidget {
  const _ZoneBox({
    required this.zone,
    required this.selected,
    required this.onTap,
  });

  final Zone zone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final z = zone;
    final color = zoneColor(context, z.type);
    final fg = _swatch(context, z.type)?.fg ?? c.label;
    final wall = z.type == ZoneType.wall;
    return Pressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: '${z.name}，${z.rule}',
      tooltip: wall ? z.name : null,
      focusRadius: AppRadius.xs,
      // 选中外圈画在围栏外侧（半透明填充上用阴影会把整块染色）。
      builder: (context, st) => Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          Positioned(
            left: -3,
            top: -3,
            right: -3,
            bottom: -3,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: AppMotion.highlight,
                curve: AppMotion.highlightCurve,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    (wall ? 2 : AppRadius.xs) + 3,
                  ),
                  border: Border.all(
                    color: selected
                        ? c.accentRing
                        : c.accentRing.withValues(alpha: 0),
                    width: 3,
                  ),
                ),
              ),
            ),
          ),
          _body(context, wall, color, fg),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, bool wall, Color color, Color fg) {
    final t = context.type;
    final z = zone;
    return Container(
      decoration: BoxDecoration(
        color: wall
            ? color
            : z.type == ZoneType.slow
            ? color.withValues(alpha: 0.12)
            : z.type == ZoneType.whitelist
            ? color.withValues(alpha: 0.10)
            : null,
        borderRadius: BorderRadius.circular(wall ? 2 : AppRadius.xs),
        border: wall ? null : Border.all(color: color, width: 1.5),
      ),
      child: wall
          ? null
          : CustomPaint(
              painter: z.type == ZoneType.ban ? _HatchPainter(color) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.x2,
                  vertical: AppSpacing.x1,
                ),
                // 小围栏放不下两行文字时裁掉，不溢出。
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxHeight: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          z.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.footnote.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          z.rule,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.micro.copyWith(color: fg),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// 禁入区的 45° 斜纹（设计稿 repeating-linear-gradient 16% / 5%）。
class _HatchPainter extends CustomPainter {
  _HatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)));
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.05));
    final stripe = Paint()
      ..color = color.withValues(alpha: 0.16)
      ..strokeWidth = 6 / 1.414;
    // 周期 12px（沿法线方向），条纹宽 6px。
    for (
      double d = -size.height;
      d < size.width + size.height;
      d += 12 * 1.414
    ) {
      canvas.drawLine(
        Offset(d, size.height),
        Offset(d + size.height, 0),
        stripe,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      );
    for (final m in path.computeMetrics()) {
      for (double d = 0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, d + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) => old.color != color;
}

class _BotDot extends StatelessWidget {
  const _BotDot({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: '设备 $name',
      child: Column(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: c.knob, width: 2),
              boxShadow: [
                BoxShadow(
                  color: c.shadow.withValues(alpha: 0.3),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.half),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
            decoration: BoxDecoration(
              color: c.mapOverlay,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              name,
              style: context.type.microStrong.copyWith(color: c.label),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

/// 围栏角点：拖动改变矩形（最小 4%，不超出地图），松手提交。
class _Handle extends StatelessWidget {
  const _Handle({
    super.key,
    required this.zone,
    required this.corner,
    required this.mapSize,
    required this.onDrag,
    required this.onEnd,
  });

  final Zone zone;
  final _Corner corner;
  final Size mapSize;
  final ValueChanged<Zone> onDrag;
  final ValueChanged<Zone> onEnd;

  static const _hit = 24.0;
  static const _min = 4.0;

  Offset get _point {
    final r = zone.rect;
    return switch (corner) {
      _Corner.topLeft => r.topLeft,
      _Corner.topRight => r.topRight,
      _Corner.bottomLeft => r.bottomLeft,
      _Corner.bottomRight => r.bottomRight,
    };
  }

  Zone _moved(Offset deltaPercent) {
    var r = zone.rect;
    final dx = deltaPercent.dx, dy = deltaPercent.dy;
    double clamp(double v) => v.clamp(0.0, 100.0);
    switch (corner) {
      case _Corner.topLeft:
        r = Rect.fromLTRB(
          clamp(r.left + dx).clamp(0.0, r.right - _min),
          clamp(r.top + dy).clamp(0.0, r.bottom - _min),
          r.right,
          r.bottom,
        );
      case _Corner.topRight:
        r = Rect.fromLTRB(
          r.left,
          clamp(r.top + dy).clamp(0.0, r.bottom - _min),
          clamp(r.right + dx).clamp(r.left + _min, 100.0),
          r.bottom,
        );
      case _Corner.bottomLeft:
        r = Rect.fromLTRB(
          clamp(r.left + dx).clamp(0.0, r.right - _min),
          r.top,
          r.right,
          clamp(r.bottom + dy).clamp(r.top + _min, 100.0),
        );
      case _Corner.bottomRight:
        r = Rect.fromLTRB(
          r.left,
          r.top,
          clamp(r.right + dx).clamp(r.left + _min, 100.0),
          clamp(r.bottom + dy).clamp(r.top + _min, 100.0),
        );
    }
    return zone.copyWith(rect: r);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = _point;
    final w = mapSize.width, h = mapSize.height;
    return Positioned(
      left: p.dx / 100 * w - _hit / 2,
      top: p.dy / 100 * h - _hit / 2,
      width: _hit,
      height: _hit,
      child: Semantics(
        label: '${zone.name} 角点',
        child: MouseRegion(
          cursor: corner == _Corner.topLeft || corner == _Corner.bottomRight
              ? SystemMouseCursors.resizeUpLeftDownRight
              : SystemMouseCursors.resizeUpRightDownLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => onDrag(
              _moved(Offset(d.delta.dx / w * 100, d.delta.dy / h * 100)),
            ),
            onPanEnd: (_) => onEnd(zone),
            child: Center(
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: c.knob,
                  border: Border.all(color: c.accent, width: 1.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
