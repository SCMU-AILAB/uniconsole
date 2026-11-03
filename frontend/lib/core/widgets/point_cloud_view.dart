import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 俯视点云（Sensors.dc.html 主视图 / Control.dc.html 雷达俯视小窗）。
///
/// [points] 为机器人坐标系下的点，单位米：+y 朝前（屏幕上方）、+x 朝右，机器人在原点。
/// 按到机器人的距离着色：< [nearMeters] 近、< [midMeters] 中、其余远。
class PointCloudView extends StatelessWidget {
  const PointCloudView({
    super.key,
    required this.points,
    this.rangeMeters = 4,
    this.pixelsPerMeter,
    this.anchor = const Offset(0.5, 0.55),
    this.nearMeters = 1,
    this.midMeters = 2,
    this.rings = const [],
    this.showHeading = false,
    this.label,
    this.pointSize = 2,
    this.robotSize = 10,
    this.semanticLabel = '雷达点云俯视图',
    this.border = true,
  });

  final List<Offset> points;

  /// 从机器人到视图短边边缘的距离（米），决定缩放。
  final double rangeMeters;

  /// 固定比例尺（Sensors.dc.html：60 px = 1 m），设置后忽略 [rangeMeters]。
  final double? pixelsPerMeter;

  /// 机器人在视图中的位置（0–1）。
  final Offset anchor;
  final double nearMeters;
  final double midMeters;

  /// 距离环（米），带「1 m」标注。
  final List<double> rings;

  /// 前方虚线朝向。
  final bool showHeading;

  /// 左上角标签（「雷达俯视」）。
  final String? label;
  final double pointSize;
  final double robotSize;
  final String semanticLabel;
  final bool border;

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
          border: border ? Border.all(color: c.hudBorder) : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _CloudPainter(
                  points: points,
                  range: rangeMeters,
                  ppm: pixelsPerMeter,
                  anchor: anchor,
                  near: nearMeters,
                  mid: midMeters,
                  rings: rings,
                  heading: showHeading,
                  colors: c,
                  ringLabel: context.type.caption.copyWith(
                    fontSize: 10,
                    color: c.decorativeGray,
                  ),
                  pointSize: pointSize,
                  robotSize: robotSize,
                ),
              ),
            ),
            if (label != null)
              Positioned(
                left: AppSpacing.x2,
                top: AppSpacing.x2,
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
    required this.range,
    required this.ppm,
    required this.anchor,
    required this.near,
    required this.mid,
    required this.rings,
    required this.heading,
    required this.colors,
    required this.ringLabel,
    required this.pointSize,
    required this.robotSize,
  });

  final List<Offset> points;
  final double range;
  final double? ppm;
  final Offset anchor;
  final double near;
  final double mid;
  final List<double> rings;
  final bool heading;
  final AppColors colors;
  final TextStyle ringLabel;
  final double pointSize;
  final double robotSize;

  @override
  void paint(Canvas canvas, Size size) {
    final o = Offset(anchor.dx * size.width, anchor.dy * size.height);
    final scale = ppm ?? math.min(size.width, size.height) / 2 / range;
    Offset px(Offset m) => Offset(o.dx + m.dx * scale, o.dy - m.dy * scale);

    // 距离环：越远越淡（Sensors.dc.html 14% / 10% / 7%）。
    for (var i = 0; i < rings.length; i++) {
      final r = rings[i] * scale;
      canvas.drawCircle(
        o,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = colors.hudText.withValues(
            alpha: math.max(0.07, 0.14 - i * 0.035),
          ),
      );
      final tp = TextPainter(
        text: TextSpan(text: '${_fmt(rings[i])} m', style: ringLabel),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(o.dx + r + 2, o.dy - tp.height - 2));
    }

    final byColor = <Color, List<Offset>>{
      colors.cloudNear: [],
      colors.cloudMid: [],
      colors.cloudFar: [],
    };
    for (final p in points) {
      final d = p.distance;
      final col = d < near
          ? colors.cloudNear
          : d < mid
          ? colors.cloudMid
          : colors.cloudFar;
      byColor[col]!.add(px(p));
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

    if (heading) {
      final dash = Paint()
        ..color = colors.cloudMid.withValues(alpha: 0.6)
        ..strokeWidth = 2;
      final len = scale; // 1 m
      for (double y = 0; y < len; y += 8) {
        canvas.drawLine(
          Offset(o.dx, o.dy - y),
          Offset(o.dx, o.dy - math.min(y + 4, len)),
          dash,
        );
      }
    }

    // 机器人：白色三角，朝前。
    final w = robotSize, h = robotSize * 0.9;
    final tri = Path()
      ..moveTo(o.dx, o.dy - h / 2)
      ..lineTo(o.dx + w / 2, o.dy + h / 2)
      ..lineTo(o.dx - w / 2, o.dy + h / 2)
      ..close();
    canvas.drawPath(tri, Paint()..color = colors.hudText);
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  bool shouldRepaint(_CloudPainter old) =>
      old.points != points ||
      old.range != range ||
      old.colors != colors ||
      old.rings != rings;
}
