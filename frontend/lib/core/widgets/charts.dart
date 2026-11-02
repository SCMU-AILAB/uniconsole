import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';

class ChartSeries {
  const ChartSeries({
    required this.values,
    this.color,
    this.label,
    this.fill = false,
  });

  final List<double> values;

  /// 为空时用强调色。
  final Color? color;
  final String? label;

  /// 线下面积填充（强调色 10%）。
  final bool fill;
}

/// 折线图（Alerts.dc.html 详情曲线、Replay.dc.html 温度/速度曲线）。
///
/// 支持多条曲线、虚线阈值线、播放游标；CustomPainter 自绘。
class LineChart extends StatelessWidget {
  const LineChart({
    super.key,
    required this.series,
    required this.semanticLabel,
    this.threshold,
    this.cursor,
    this.minY,
    this.maxY,
    this.height = 140,
    this.background = true,
    this.showLegend = false,
  });

  final List<ChartSeries> series;
  final String semanticLabel;

  /// 阈值（红色虚线）。
  final double? threshold;

  /// 0–1 的游标位置（红色竖线）。
  final double? cursor;
  final double? minY;
  final double? maxY;
  final double height;
  final bool background;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chart = Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        height: height,
        decoration: background
            ? BoxDecoration(
                color: c.chartBackground,
                borderRadius: BorderRadius.circular(AppRadius.group),
              )
            : null,
        clipBehavior: background ? Clip.antiAlias : Clip.none,
        child: CustomPaint(
          size: Size.infinite,
          painter: _LinePainter(
            series: series,
            accent: c.accent,
            thresholdColor: context.status.critical.dot,
            threshold: threshold,
            cursor: cursor,
            minY: minY,
            maxY: maxY,
          ),
        ),
      ),
    );
    if (!showLegend) return chart;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        chart,
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xl,
          children: [
            for (final s in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 2, color: s.color ?? c.accent),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    s.label ?? '',
                    style: context.type.caption.copyWith(
                      color: c.tertiaryLabel,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// 迷你折线（无背景、无坐标，可选阈值线）。
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.semanticLabel,
    this.color,
    this.threshold,
    this.width = 80,
    this.height = 24,
    this.fill = true,
  });

  final List<double> values;
  final String semanticLabel;
  final Color? color;
  final double? threshold;
  final double width;
  final double height;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _LinePainter(
            series: [ChartSeries(values: values, color: color, fill: fill)],
            accent: c.accent,
            thresholdColor: context.status.critical.dot,
            threshold: threshold,
            strokeWidth: 1.5,
            padding: 2,
          ),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.series,
    required this.accent,
    required this.thresholdColor,
    this.threshold,
    this.cursor,
    this.minY,
    this.maxY,
    this.strokeWidth = 2,
    this.padding = 8,
  });

  final List<ChartSeries> series;
  final Color accent;
  final Color thresholdColor;
  final double? threshold;
  final double? cursor;
  final double? minY;
  final double? maxY;
  final double strokeWidth;
  final double padding;

  @override
  void paint(Canvas canvas, Size size) {
    final all = [for (final s in series) ...s.values, ?threshold];
    if (all.isEmpty) return;
    var lo = minY ?? all.reduce(math.min);
    var hi = maxY ?? all.reduce(math.max);
    if (hi - lo < 1e-6) {
      hi += 1;
      lo -= 1;
    }
    final top = padding, bottom = size.height - padding;
    double y(double v) => bottom - (v - lo) / (hi - lo) * (bottom - top);

    for (final s in series) {
      if (s.values.length < 2) continue;
      final color = s.color ?? accent;
      final dx = size.width / (s.values.length - 1);
      final path = Path()..moveTo(0, y(s.values.first));
      for (var i = 1; i < s.values.length; i++) {
        path.lineTo(i * dx, y(s.values[i]));
      }
      if (s.fill) {
        final area = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.10));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    if (threshold != null) {
      final ty = y(threshold!);
      final p = Paint()
        ..color = thresholdColor
        ..strokeWidth = 1.2;
      for (double x = 0; x < size.width; x += 9) {
        canvas.drawLine(
          Offset(x, ty),
          Offset(math.min(x + 5, size.width), ty),
          p,
        );
      }
    }

    if (cursor != null) {
      final cx = cursor!.clamp(0.0, 1.0) * size.width;
      canvas.drawLine(
        Offset(cx, 0),
        Offset(cx, size.height),
        Paint()
          ..color = thresholdColor
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.series != series ||
      old.threshold != threshold ||
      old.cursor != cursor ||
      old.accent != accent;
}
