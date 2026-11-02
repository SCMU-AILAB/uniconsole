import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 俯视点云（Sensors.dc.html / Control.dc.html 雷达俯视小窗）。
///
/// 点坐标为 0–1 的归一化位置；颜色按到机器人的距离分三段：
/// 近 cloudNear、中 cloudMid、远 cloudFar。
class PointCloudView extends StatelessWidget {
  const PointCloudView({
    super.key,
    required this.points,
    this.robot = const Offset(0.5, 0.55),
    this.heading = 0,
    this.nearRadius = 0.18,
    this.midRadius = 0.32,
    this.label,
    this.showRings = false,
    this.pointSize = 2,
    this.semanticLabel = '雷达点云俯视图',
  });

  final List<Offset> points;
  final Offset robot;

  /// 机器人朝向（弧度，0 = 朝上）。
  final double heading;
  final double nearRadius;
  final double midRadius;

  /// 左上角标签（「雷达俯视」）。
  final String? label;

  /// 显示距离环。
  final bool showRings;
  final double pointSize;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        decoration: BoxDecoration(
          color: c.pointCloudBackground,
          borderRadius: BorderRadius.circular(AppRadius.group),
          border: Border.all(color: c.hudBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _CloudPainter(
                  points: points,
                  robot: robot,
                  heading: heading,
                  near: nearRadius,
                  mid: midRadius,
                  colors: c,
                  rings: showRings,
                  pointSize: pointSize,
                ),
              ),
            ),
            if (label != null)
              Positioned(
                left: 8,
                top: 6,
                child: Text(
                  label!,
                  style: context.type.caption.copyWith(
                    fontSize: 10,
                    color: c.hudSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CloudPainter extends CustomPainter {
  _CloudPainter({
    required this.points,
    required this.robot,
    required this.heading,
    required this.near,
    required this.mid,
    required this.colors,
    required this.rings,
    required this.pointSize,
  });

  final List<Offset> points;
  final Offset robot;
  final double heading;
  final double near;
  final double mid;
  final AppColors colors;
  final bool rings;
  final double pointSize;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset(robot.dx * size.width, robot.dy * size.height);

    if (rings) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.hudBorder;
      // 距离按归一化坐标计算，所以距离环在非正方形画布上是椭圆，与着色分段一致。
      for (final k in [near, mid]) {
        canvas.drawOval(
          Rect.fromCenter(
            center: r,
            width: 2 * k * size.width,
            height: 2 * k * size.height,
          ),
          ring,
        );
      }
    }

    final byColor = <Color, List<Offset>>{
      colors.cloudNear: [],
      colors.cloudMid: [],
      colors.cloudFar: [],
    };
    for (final p in points) {
      final d = (p - robot).distance;
      final col = d < near
          ? colors.cloudNear
          : d < mid
          ? colors.cloudMid
          : colors.cloudFar;
      byColor[col]!.add(Offset(p.dx * size.width, p.dy * size.height));
    }
    byColor.forEach((color, pts) {
      canvas.drawPoints(
        PointMode.points,
        pts,
        Paint()
          ..color = color
          ..strokeWidth = pointSize
          ..strokeCap = StrokeCap.square,
      );
    });

    // 机器人：白色三角，朝向 heading。
    canvas.save();
    canvas.translate(r.dx, r.dy);
    canvas.rotate(heading);
    final tri = Path()
      ..moveTo(0, -5.5)
      ..lineTo(5, 3.5)
      ..lineTo(-5, 3.5)
      ..close();
    canvas.drawPath(tri, Paint()..color = colors.hudText);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.points != points ||
      old.robot != robot ||
      old.heading != heading ||
      old.colors != colors;
}
