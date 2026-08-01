import 'dart:math' as math;

import 'package:monokit/monokit.dart';

/// The editing vocabulary, drawn rather than borrowed.
///
/// Monokit's [MonoIcons] carries the app furniture — close, check, chevrons,
/// play, image — and this app uses it directly for all of that. What a general
/// icon set has no reason to carry is *crop*, *flip*, *blur*, *a pen nib*.
/// Reaching for the nearest available glyph is precisely what makes a toolbar
/// look improvised: a thumbs-up standing in for "draw" is legible only to the
/// person who chose it.
///
/// So the domain glyphs are drawn here, on the same 24-unit grid and the same
/// hairline weight as the rest of the system, and sit in the same family.
enum LensGlyph {
  crop,
  rotate,
  flip,
  text,
  emoji,
  sticker,
  blur,
  pen,
  move,
  trim,
  undo,
  redo,
  soundOn,
  soundOff,
  flashOn,
  flashOff,
  flashAuto,
  cameraFlip,
  resize,
  trash;

  String get semanticLabel => switch (this) {
    LensGlyph.crop => 'Crop',
    LensGlyph.rotate => 'Rotate',
    LensGlyph.flip => 'Flip',
    LensGlyph.text => 'Text',
    LensGlyph.emoji => 'Emoji',
    LensGlyph.sticker => 'Sticker',
    LensGlyph.blur => 'Blur',
    LensGlyph.pen => 'Draw',
    LensGlyph.move => 'Move',
    LensGlyph.trim => 'Trim',
    LensGlyph.undo => 'Undo',
    LensGlyph.redo => 'Redo',
    LensGlyph.soundOn => 'Sound on',
    LensGlyph.soundOff => 'Muted',
    LensGlyph.flashOn => 'Flash on',
    LensGlyph.flashOff => 'Flash off',
    LensGlyph.flashAuto => 'Flash auto',
    LensGlyph.cameraFlip => 'Switch camera',
    LensGlyph.resize => 'Resize',
    LensGlyph.trash => 'Delete',
  };
}

/// Renders a [LensGlyph] at [size], matching [MonoIcon]'s conventions.
class LensIcon extends StatelessWidget {
  const LensIcon(
    this.glyph, {
    super.key,
    this.size = 20,
    this.color,
    this.strokeWidth = 1.6,
    this.semanticLabel,
  });

  final LensGlyph glyph;
  final double size;
  final Color? color;

  /// In grid units, so it scales with [size] the way a stem scales with type.
  final double strokeWidth;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel ?? glyph.semanticLabel,
      excludeSemantics: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(
          glyph: glyph,
          color: color ?? MonokitTheme.of(context).colors.foreground,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

/// A rectangle of a given aspect ratio, for the crop presets.
///
/// The point of drawing the shape instead of labelling it is that "4:5" needs
/// reading and a tall rectangle does not.
class LensRatioGlyph extends StatelessWidget {
  const LensRatioGlyph({
    required this.aspectRatio,
    required this.color,
    super.key,
    this.size = 20,
  });

  /// Null draws the free-form mark instead of a fixed rectangle.
  final double? aspectRatio;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _RatioPainter(aspectRatio: aspectRatio, color: color),
    );
  }
}

class _RatioPainter extends CustomPainter {
  const _RatioPainter({required this.aspectRatio, required this.color});

  final double? aspectRatio;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final ratio = aspectRatio;
    if (ratio == null) {
      // Free-form: four corner ticks with nothing joining them.
      final box = Rect.fromCenter(
        center: size.center(Offset.zero),
        width: size.width * 0.78,
        height: size.height * 0.78,
      );
      final arm = size.width * 0.2;
      for (final (corner, sx, sy) in [
        (box.topLeft, 1.0, 1.0),
        (box.topRight, -1.0, 1.0),
        (box.bottomLeft, 1.0, -1.0),
        (box.bottomRight, -1.0, -1.0),
      ]) {
        canvas.drawPath(
          Path()
            ..moveTo(corner.dx, corner.dy + sy * arm)
            ..lineTo(corner.dx, corner.dy)
            ..lineTo(corner.dx + sx * arm, corner.dy),
          stroke,
        );
      }
      return;
    }

    // Fit the ratio inside the box, so 16:9 and 9:16 read as the same area
    // turned rather than as two unrelated sizes.
    final extent = size.width * 0.82;
    final width = ratio >= 1 ? extent : extent * ratio;
    final height = ratio >= 1 ? extent / ratio : extent;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: size.center(Offset.zero),
          width: width,
          height: height,
        ),
        Radius.circular(size.width * 0.1),
      ),
      stroke,
    );
  }

  @override
  bool shouldRepaint(_RatioPainter old) =>
      old.aspectRatio != aspectRatio || old.color != color;
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyph,
    required this.color,
    required this.strokeWidth,
  });

  final LensGlyph glyph;
  final Color color;
  final double strokeWidth;

  /// Every path below is authored against this square.
  static const double _grid = 24;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _grid);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    switch (glyph) {
      case LensGlyph.crop:
        canvas.drawPath(
          Path()
            ..moveTo(6.5, 2)
            ..lineTo(6.5, 17.5)
            ..lineTo(22, 17.5)
            ..moveTo(2, 6.5)
            ..lineTo(17.5, 6.5)
            ..lineTo(17.5, 22),
          stroke,
        );

      case LensGlyph.rotate:
        const centre = Offset(12, 12.6);
        const radius = 8.0;
        canvas.drawPath(
          Path()..addArc(
            Rect.fromCircle(center: centre, radius: radius),
            _rad(-72),
            _rad(300),
          ),
          stroke,
        );
        // The head sits at the sweep's end, aimed along its travel, so the
        // gap at the top reads as a direction rather than as a broken circle.
        final end = _rad(228);
        _head(
          canvas,
          stroke,
          centre + Offset(math.cos(end), math.sin(end)) * radius,
          end + math.pi / 2,
          4.4,
        );

      case LensGlyph.flip:
        for (var y = 2.5; y < 21; y += 4.2) {
          canvas.drawLine(
            Offset(12, y),
            Offset(12, math.min(y + 2.4, 21.5)),
            stroke,
          );
        }
        // One solid, one hollow: a mirror, not a pair of arrows.
        canvas.drawPath(
          Path()
            ..moveTo(9.2, 5.5)
            ..lineTo(3.5, 12)
            ..lineTo(9.2, 18.5)
            ..close(),
          fill,
        );
        canvas.drawPath(
          Path()
            ..moveTo(14.8, 5.5)
            ..lineTo(20.5, 12)
            ..lineTo(14.8, 18.5)
            ..close(),
          stroke,
        );

      case LensGlyph.text:
        canvas.drawPath(
          Path()
            ..moveTo(4.5, 7)
            ..lineTo(4.5, 4.5)
            ..lineTo(19.5, 4.5)
            ..lineTo(19.5, 7)
            ..moveTo(12, 4.5)
            ..lineTo(12, 19.5)
            ..moveTo(8.75, 19.5)
            ..lineTo(15.25, 19.5),
          stroke,
        );

      case LensGlyph.emoji:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawCircle(const Offset(9, 10), 1.05, fill);
        canvas.drawCircle(const Offset(15, 10), 1.05, fill);
        canvas.drawPath(
          Path()
            ..moveTo(7.8, 14.2)
            ..quadraticBezierTo(12, 18.4, 16.2, 14.2),
          stroke,
        );

      case LensGlyph.sticker:
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 6.5)
            ..arcToPoint(
              const Offset(6.5, 3.5),
              radius: const Radius.circular(3),
            )
            ..lineTo(17.5, 3.5)
            ..arcToPoint(
              const Offset(20.5, 6.5),
              radius: const Radius.circular(3),
            )
            ..lineTo(20.5, 13.5)
            ..lineTo(13.5, 20.5)
            ..lineTo(6.5, 20.5)
            ..arcToPoint(
              const Offset(3.5, 17.5),
              radius: const Radius.circular(3),
            )
            ..close(),
          stroke,
        );
        // The fold's own edge. Without it this is just a clipped card.
        canvas.drawPath(
          Path()
            ..moveTo(20.5, 13.5)
            ..lineTo(16.5, 13.5)
            ..arcToPoint(
              const Offset(13.5, 16.5),
              radius: const Radius.circular(3),
              clockwise: false,
            )
            ..lineTo(13.5, 20.5),
          stroke,
        );

      case LensGlyph.blur:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        // A lattice that loses definition toward the edge.
        for (final (dx, dy, r) in const [
          (-4.4, -4.4, 0.85),
          (0.0, -4.4, 1.2),
          (4.4, -4.4, 0.85),
          (-4.4, 0.0, 1.2),
          (0.0, 0.0, 1.75),
          (4.4, 0.0, 1.2),
          (-4.4, 4.4, 0.85),
          (0.0, 4.4, 1.2),
          (4.4, 4.4, 0.85),
        ]) {
          canvas.drawCircle(Offset(12 + dx, 12 + dy), r, fill);
        }

      case LensGlyph.pen:
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 20.5)
            ..lineTo(5.4, 15.2)
            ..lineTo(16.1, 4.5)
            ..arcToPoint(
              const Offset(19.5, 7.9),
              radius: const Radius.circular(2.6),
            )
            ..lineTo(8.8, 18.6)
            ..close()
            ..moveTo(5.4, 15.2)
            ..lineTo(8.8, 18.6),
          stroke,
        );

      case LensGlyph.move:
        // A pointer, because this tool selects what is already there rather
        // than creating anything.
        canvas.drawPath(
          Path()
            ..moveTo(5.5, 3)
            ..lineTo(18, 12.4)
            ..lineTo(12.2, 13.4)
            ..lineTo(15.4, 19.6)
            ..lineTo(12.7, 21)
            ..lineTo(9.6, 14.8)
            ..lineTo(5.5, 18.8)
            ..close(),
          stroke,
        );

      case LensGlyph.trim:
        // The trim bar's own shape: a strip with a grab handle at each end.
        canvas.drawPath(
          Path()
            ..moveTo(2.5, 7.5)
            ..lineTo(21.5, 7.5)
            ..moveTo(2.5, 16.5)
            ..lineTo(21.5, 16.5),
          stroke,
        );
        for (final x in const [6.0, 18.0]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset(x, 12), width: 4.4, height: 13),
              const Radius.circular(1.6),
            ),
            stroke,
          );
        }

      case LensGlyph.undo:
        canvas.drawPath(
          Path()
            ..moveTo(8.8, 5.2)
            ..lineTo(4, 10)
            ..lineTo(8.8, 14.8)
            ..moveTo(4, 10)
            ..lineTo(13.5, 10)
            ..arcToPoint(
              const Offset(13.5, 20),
              radius: const Radius.circular(5),
            )
            ..lineTo(9.5, 20),
          stroke,
        );

      case LensGlyph.redo:
        canvas.drawPath(
          Path()
            ..moveTo(15.2, 5.2)
            ..lineTo(20, 10)
            ..lineTo(15.2, 14.8)
            ..moveTo(20, 10)
            ..lineTo(10.5, 10)
            ..arcToPoint(
              const Offset(10.5, 20),
              radius: const Radius.circular(5),
              clockwise: false,
            )
            ..lineTo(14.5, 20),
          stroke,
        );

      case LensGlyph.soundOn:
        canvas.drawPath(_speaker(), stroke);
        for (final r in const [3.0, 6.0]) {
          canvas.drawPath(
            Path()..addArc(
              Rect.fromCircle(center: const Offset(11.5, 12), radius: r),
              _rad(-52),
              _rad(104),
            ),
            stroke,
          );
        }

      case LensGlyph.soundOff:
        canvas.drawPath(_speaker(), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(15.5, 9.5)
            ..lineTo(20.5, 14.5)
            ..moveTo(20.5, 9.5)
            ..lineTo(15.5, 14.5),
          stroke,
        );

      case LensGlyph.flashOn:
        canvas.drawPath(_bolt(), stroke);

      case LensGlyph.flashOff:
        canvas.drawPath(_bolt(), stroke);
        canvas.drawLine(
          const Offset(4.5, 4.5),
          const Offset(19.5, 19.5),
          stroke,
        );

      case LensGlyph.flashAuto:
        canvas.drawPath(
          Path()
            ..moveTo(9.4, 2.8)
            ..lineTo(3.6, 12.6)
            ..lineTo(7.4, 12.6)
            ..lineTo(6.6, 21.2)
            ..lineTo(12.4, 11.4)
            ..lineTo(8.6, 11.4)
            ..close(),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(14.4, 20.4)
            ..lineTo(18.4, 9.8)
            ..lineTo(22.4, 20.4)
            ..moveTo(15.7, 17.2)
            ..lineTo(21.1, 17.2),
          stroke,
        );

      case LensGlyph.cameraFlip:
        const centre = Offset(12, 12);
        const radius = 8.0;
        for (final start in const [200.0, 20.0]) {
          canvas.drawPath(
            Path()..addArc(
              Rect.fromCircle(center: centre, radius: radius),
              _rad(start),
              _rad(120),
            ),
            stroke,
          );
          final end = _rad(start + 120);
          _head(
            canvas,
            stroke,
            centre + Offset(math.cos(end), math.sin(end)) * radius,
            end + math.pi / 2,
            4,
          );
        }
        canvas.drawCircle(centre, 2.6, stroke);

      case LensGlyph.resize:
        canvas.drawPath(
          Path()
            ..moveTo(6.5, 17.5)
            ..lineTo(17.5, 6.5)
            ..moveTo(12.5, 6.5)
            ..lineTo(17.5, 6.5)
            ..lineTo(17.5, 11.5)
            ..moveTo(11.5, 17.5)
            ..lineTo(6.5, 17.5)
            ..lineTo(6.5, 12.5),
          stroke,
        );

      case LensGlyph.trash:
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 6.5)
            ..lineTo(20.5, 6.5)
            ..moveTo(9.5, 6.5)
            ..lineTo(9.5, 4.6)
            ..arcToPoint(
              const Offset(11.4, 2.7),
              radius: const Radius.circular(2),
            )
            ..lineTo(12.6, 2.7)
            ..arcToPoint(
              const Offset(14.5, 4.6),
              radius: const Radius.circular(2),
            )
            ..lineTo(14.5, 6.5)
            ..moveTo(5.8, 6.5)
            ..lineTo(6.9, 19.8)
            ..arcToPoint(
              const Offset(8.9, 21.3),
              radius: const Radius.circular(2),
              clockwise: false,
            )
            ..lineTo(15.1, 21.3)
            ..arcToPoint(
              const Offset(17.1, 19.8),
              radius: const Radius.circular(2),
              clockwise: false,
            )
            ..lineTo(18.2, 6.5)
            ..moveTo(10, 10.5)
            ..lineTo(10.3, 17.5)
            ..moveTo(14, 10.5)
            ..lineTo(13.7, 17.5),
          stroke,
        );
    }

    canvas.restore();
  }

  static double _rad(double degrees) => degrees * math.pi / 180;

  static Path _speaker() => Path()
    ..moveTo(3.5, 9.5)
    ..lineTo(7, 9.5)
    ..lineTo(11.5, 5.3)
    ..lineTo(11.5, 18.7)
    ..lineTo(7, 14.5)
    ..lineTo(3.5, 14.5)
    ..close();

  static Path _bolt() => Path()
    ..moveTo(13.6, 2.5)
    ..lineTo(6.2, 13.2)
    ..lineTo(11.4, 13.2)
    ..lineTo(10.4, 21.5)
    ..lineTo(17.8, 10.8)
    ..lineTo(12.6, 10.8)
    ..close();

  /// Two barbs swept back from [tip], pointing along [direction].
  static void _head(
    Canvas canvas,
    Paint paint,
    Offset tip,
    double direction,
    double length,
  ) {
    const spread = 0.62;
    final back = direction + math.pi;
    canvas.drawPath(
      Path()
        ..moveTo(
          tip.dx + math.cos(back - spread) * length,
          tip.dy + math.sin(back - spread) * length,
        )
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(
          tip.dx + math.cos(back + spread) * length,
          tip.dy + math.sin(back + spread) * length,
        ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
