import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'app_icon.dart';
import 'pressable.dart';

// 地图上的所有坐标都是 0–100 的百分比（与设计稿一致），随容器缩放。

class MapRoom {
  const MapRoom(this.rect, {this.label, this.filled = true});

  final Rect rect;
  final String? label;

  /// false 时只画墙体（外墙）。
  final bool filled;
}

enum ZoneKind {
  /// 禁行区（红）
  ban,

  /// 限速区（橙）
  slow,

  /// 白名单区（紫）
  whitelist,
}

class MapZone {
  const MapZone(this.polygon, {required this.kind, this.label});

  MapZone.rect(Rect r, {required this.kind, this.label})
    : polygon = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

  final List<Offset> polygon;
  final ZoneKind kind;
  final String? label;
}

class MapRoute {
  const MapRoute(this.points, {this.done = false, this.color});

  final List<Offset> points;

  /// 已走过：实线 3.5；计划：虚线 2。
  final bool done;
  final Color? color;
}

class MapWaypoint {
  const MapWaypoint(this.index, this.position, {this.name});

  final int index;
  final Offset position;
  final String? name;
}

class MapRobot {
  const MapRobot(this.name, this.position, {this.heading = math.pi / 2});

  final String name;
  final Offset position;

  /// 弧度，0 = 朝上，π/2 = 朝右。
  final double heading;
}

/// 平面地图（Missions.dc.html / Safety.dc.html）：网格 + 墙体 + 区域 + 路线 + 点位 + 设备。
class FloorMapView extends StatelessWidget {
  const FloorMapView({
    super.key,
    this.rooms = const [],
    this.walls = const [],
    this.zones = const [],
    this.routes = const [],
    this.waypoints = const [],
    this.robots = const [],
    this.chargers = const [],
    this.selectedWaypoint,
    this.onWaypointTap,
    this.overlays = const [],
    this.footer,
    this.gridSize = 26,
    this.semanticLabel = '平面地图',
  });

  final List<MapRoom> rooms;

  /// 额外墙线（折线）。
  final List<List<Offset>> walls;
  final List<MapZone> zones;
  final List<MapRoute> routes;
  final List<MapWaypoint> waypoints;
  final List<MapRobot> robots;
  final List<Offset> chargers;
  final int? selectedWaypoint;
  final ValueChanged<int>? onWaypointTap;

  /// 浮在地图上的工具栏、图例等（自行 Positioned）。
  final List<Widget> overlays;

  /// 左下角说明文字。
  final String? footer;
  final double gridSize;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = context.status;
    final t = context.type;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: c.mapBackground,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.separator),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth, h = box.maxHeight;
            Offset px(Offset p) => Offset(p.dx / 100 * w, p.dy / 100 * h);

            Color zoneColor(ZoneKind k) => switch (k) {
              ZoneKind.ban => s.critical.dot,
              ZoneKind.slow => s.warning.dot,
              ZoneKind.whitelist => s.action.dot,
            };
            Color zoneText(ZoneKind k) => switch (k) {
              ZoneKind.ban => s.critical.fg,
              ZoneKind.slow => s.warning.fg,
              ZoneKind.whitelist => s.action.fg,
            };

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _MapPainter(
                      grid: gridSize,
                      gridColor: c.mapGrid,
                      wallColor: c.mapWall,
                      roomFill: c.mapRoomFill,
                      rooms: rooms,
                      walls: walls,
                      zones: zones,
                      zoneColor: zoneColor,
                      routes: routes,
                      accent: c.accent,
                    ),
                  ),
                ),
                for (final r in rooms)
                  if (r.label != null)
                    Positioned(
                      left: r.rect.left / 100 * w,
                      top: r.rect.top / 100 * h,
                      width: r.rect.width / 100 * w,
                      height: r.rect.height / 100 * h,
                      child: Center(
                        child: Text(
                          r.label!,
                          textAlign: TextAlign.center,
                          style: t.subhead.copyWith(color: c.secondaryLabel),
                        ),
                      ),
                    ),
                for (final z in zones)
                  if (z.label != null)
                    Positioned(
                      left: px(z.polygon.first).dx + 4,
                      top:
                          px(
                            z.polygon
                                .map((p) => p)
                                .reduce((a, b) => a.dy > b.dy ? a : b),
                          ).dy +
                          4,
                      child: Text(
                        z.label!,
                        style: t.caption.copyWith(color: zoneText(z.kind)),
                      ),
                    ),
                for (final ch in chargers)
                  Positioned(
                    left: px(ch).dx - 9,
                    top: px(ch).dy - 9,
                    child: Tooltip(
                      message: '充电桩',
                      child: Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: s.online.dot,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: AppIcon(
                          AppIcons.bolt,
                          size: 11,
                          color: c.onAccent,
                        ),
                      ),
                    ),
                  ),
                for (final r in robots)
                  Positioned(
                    left: px(r.position).dx,
                    top: px(r.position).dy,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, -0.5),
                      child: Semantics(
                        label: '设备 ${r.name}',
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Transform.rotate(
                              angle: r.heading,
                              child: CustomPaint(
                                size: const Size(14, 14),
                                painter: _TrianglePainter(c.label),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: c.surface,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: c.separator),
                              ),
                              child: Text(
                                r.name,
                                style: t.captionStrong.copyWith(color: c.label),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                for (final wp in waypoints)
                  Positioned(
                    left: px(wp.position).dx,
                    top: px(wp.position).dy,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, -0.5),
                      child: Pressable(
                        onTap: onWaypointTap == null
                            ? null
                            : () => onWaypointTap!(wp.index),
                        selected: wp.index == selectedWaypoint,
                        semanticLabel:
                            '点位 ${wp.index}${wp.name == null ? '' : ' ${wp.name}'}',
                        focusRadius: 13,
                        builder: (context, st) {
                          final on = wp.index == selectedWaypoint;
                          final d = on ? 26.0 : 22.0;
                          return Container(
                            width: d,
                            height: d,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.surface, width: 2),
                              boxShadow: [
                                if (on)
                                  BoxShadow(
                                    color: c.accentRing,
                                    spreadRadius: 4,
                                  ),
                                BoxShadow(
                                  color: c.shadow,
                                  blurRadius: 3,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: Text(
                              '${wp.index}',
                              style: t.caption.copyWith(
                                color: c.onAccent,
                                fontWeight: FontWeight.w700,
                                height: 1,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                if (footer != null)
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 12,
                    child: Text(
                      footer!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.caption.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                ...overlays,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 地图浮层面板（白底 96%、圆角 10、描边），用于工具栏和图例。
class MapOverlayPanel extends StatelessWidget {
  const MapOverlayPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(4),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.mapOverlay,
        borderRadius: BorderRadius.circular(AppRadius.group),
        border: Border.all(color: c.separator),
        boxShadow: [
          BoxShadow(
            color: c.shadow.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.grid,
    required this.gridColor,
    required this.wallColor,
    required this.roomFill,
    required this.rooms,
    required this.walls,
    required this.zones,
    required this.zoneColor,
    required this.routes,
    required this.accent,
  });

  final double grid;
  final Color gridColor;
  final Color wallColor;
  final Color roomFill;
  final List<MapRoom> rooms;
  final List<List<Offset>> walls;
  final List<MapZone> zones;
  final Color Function(ZoneKind) zoneColor;
  final List<MapRoute> routes;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    Offset px(Offset p) =>
        Offset(p.dx / 100 * size.width, p.dy / 100 * size.height);
    Rect pr(Rect r) => Rect.fromPoints(px(r.topLeft), px(r.bottomRight));

    // 网格
    final g = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += grid) {
      canvas.drawLine(Offset(x + .5, 0), Offset(x + .5, size.height), g);
    }
    for (double y = 0; y < size.height; y += grid) {
      canvas.drawLine(Offset(0, y + .5), Offset(size.width, y + .5), g);
    }

    // 房间与墙体
    final wall = Paint()
      ..color = wallColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round;
    for (final r in rooms) {
      final rect = RRect.fromRectAndRadius(
        pr(r.rect),
        const Radius.circular(3),
      );
      if (r.filled) canvas.drawRRect(rect, Paint()..color = roomFill);
      canvas.drawRRect(rect, wall);
    }
    for (final line in walls) {
      if (line.length < 2) continue;
      final path = Path()..moveTo(px(line.first).dx, px(line.first).dy);
      for (final p in line.skip(1)) {
        path.lineTo(px(p).dx, px(p).dy);
      }
      canvas.drawPath(path, wall..strokeCap = StrokeCap.round);
    }

    // 区域：斜线填充 + 虚线边
    for (final z in zones) {
      final color = zoneColor(z.kind);
      final path = Path()..addPolygon(z.polygon.map(px).toList(), true);
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.04));
      canvas.save();
      canvas.clipPath(path);
      final b = path.getBounds();
      final hatch = Paint()
        ..color = color.withValues(alpha: 0.14)
        ..strokeWidth = 6;
      for (double d = -b.height; d < b.width + b.height; d += 12) {
        canvas.drawLine(
          Offset(b.left + d, b.bottom),
          Offset(b.left + d + b.height, b.top),
          hatch,
        );
      }
      canvas.restore();
      _dashPath(
        canvas,
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
        5,
        4,
      );
    }

    // 路线
    for (final r in routes) {
      if (r.points.length < 2) continue;
      final path = Path()..moveTo(px(r.points.first).dx, px(r.points.first).dy);
      for (final p in r.points.skip(1)) {
        path.lineTo(px(p).dx, px(p).dy);
      }
      final paint = Paint()
        ..color = r.color ?? accent
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = r.done ? 3.5 : 2;
      if (r.done) {
        canvas.drawPath(path, paint);
      } else {
        _dashPath(canvas, path, paint, 6, 5);
      }
    }
  }

  static void _dashPath(
    Canvas canvas,
    Path path,
    Paint paint,
    double dash,
    double gap,
  ) {
    for (final m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => true;
}
