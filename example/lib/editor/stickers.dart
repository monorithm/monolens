import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

/// The sticker sheet, drawn at runtime.
///
/// A sticker is just a PNG on disk as far as monolens is concerned, so the
/// example paints its own and writes them to the cache rather than committing
/// binaries. That keeps the repo free of art nobody reviews, and it doubles as
/// a demonstration that a host can generate stickers — from a user's drawing,
/// a downloaded pack, a rendered widget — without the plugin caring.
class StickerSheet {
  StickerSheet._(this.stickers);

  final List<Sticker> stickers;

  static StickerSheet? _cached;

  /// Bumped whenever a design changes.
  ///
  /// The art is written once and reused from disk, so without this a redrawn
  /// sticker would keep exporting the previous version for anyone who had
  /// already opened the sheet.
  static const int _version = 2;

  static Future<StickerSheet> load() async {
    if (_cached != null) return _cached!;

    final directory = await MonolensPlatform.instance.cacheDirectory();
    final sheet = <Sticker>[];
    for (final design in _designs) {
      final file = File('$directory/sticker_${design.name}_v$_version.png');
      if (!file.existsSync()) {
        await file.writeAsBytes(await _render(design), flush: true);
      }
      sheet.add(Sticker(name: design.name, path: file.path, design: design));
    }
    return _cached = StickerSheet._(sheet);
  }

  /// Draws a design with its die-cut border.
  ///
  /// The white outline is the whole reason a sticker reads as a sticker rather
  /// than as a shape someone pasted on: it is the cut line, and it also
  /// guarantees separation from whatever the sticker lands on.
  static void draw(Canvas canvas, Size size, StickerDesign design) {
    canvas.drawPath(
      design.silhouette(size),
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.075
        ..strokeJoin = StrokeJoin.round,
    );
    design.paint(canvas, size);
  }

  static Future<List<int>> _render(StickerDesign design) async {
    const size = 256.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    draw(canvas, const Size(size, size), design);
    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }
}

class Sticker {
  const Sticker({required this.name, required this.path, required this.design});

  final String name;
  final String path;
  final StickerDesign design;

  /// Draws the same art into a picker cell, so the thumbnail and the exported
  /// sticker cannot drift apart.
  Widget preview({double size = 44}) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _StickerPainter(design)),
  );
}

class _StickerPainter extends CustomPainter {
  const _StickerPainter(this.design);

  final StickerDesign design;

  @override
  void paint(Canvas canvas, Size size) =>
      StickerSheet.draw(canvas, size, design);

  @override
  bool shouldRepaint(_StickerPainter old) => old.design != design;
}

class StickerDesign {
  const StickerDesign(
    this.name, {
    required this.silhouette,
    required this.paint,
  });

  final String name;

  /// The outline the die-cut border is stroked along. Kept separate from
  /// [paint] so the border is one rule rather than six hand-drawn copies.
  final Path Function(Size size) silhouette;

  final void Function(Canvas canvas, Size size) paint;
}

final List<StickerDesign> _designs = [
  StickerDesign(
    'star',
    silhouette: (size) => _polygonPath(size, points: 5),
    paint: (canvas, size) => canvas.drawPath(
      _polygonPath(size, points: 5),
      Paint()..color = const Color(0xFFFFC53D),
    ),
  ),
  StickerDesign(
    'burst',
    silhouette: (size) => _polygonPath(size, points: 12, inner: 0.7),
    paint: (canvas, size) => canvas.drawPath(
      _polygonPath(size, points: 12, inner: 0.7),
      Paint()..color = const Color(0xFFE5484D),
    ),
  ),
  StickerDesign(
    'heart',
    silhouette: _heartPath,
    paint: (canvas, size) => canvas.drawPath(
      _heartPath(size),
      Paint()..color = const Color(0xFFE5484D),
    ),
  ),
  StickerDesign(
    'bubble',
    silhouette: _bubblePath,
    paint: (canvas, size) {
      canvas.drawPath(
        _bubblePath(size),
        Paint()..color = const Color(0xFF3E63DD),
      );
      // Three dots: a speech bubble with nothing in it reads as a blank shape.
      final w = size.width;
      final h = size.height;
      for (final x in const [0.32, 0.5, 0.68]) {
        canvas.drawCircle(
          Offset(w * x, h * 0.40),
          w * 0.055,
          Paint()..color = const Color(0xFFFFFFFF),
        );
      }
    },
  ),
  StickerDesign(
    'check',
    silhouette: (size) => Path()
      ..addOval(
        Rect.fromCircle(
          center: size.center(Offset.zero),
          radius: size.width * 0.42,
        ),
      ),
    paint: (canvas, size) {
      final w = size.width;
      final h = size.height;
      canvas.drawCircle(
        size.center(Offset.zero),
        w * 0.42,
        Paint()..color = const Color(0xFF10B981),
      );
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.30, h * 0.52)
          ..lineTo(w * 0.44, h * 0.66)
          ..lineTo(w * 0.71, h * 0.37),
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.09
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    },
  ),
  StickerDesign(
    'arrow',
    silhouette: _arrowPath,
    paint: (canvas, size) => canvas.drawPath(
      _arrowPath(size),
      Paint()..color = const Color(0xFF8B5CF6),
    ),
  ),
];

Path _heartPath(Size size) {
  final w = size.width;
  final h = size.height;
  return Path()
    ..moveTo(w * 0.5, h * 0.85)
    ..cubicTo(w * -0.1, h * 0.5, w * 0.2, h * 0.05, w * 0.5, h * 0.32)
    ..cubicTo(w * 0.8, h * 0.05, w * 1.1, h * 0.5, w * 0.5, h * 0.85)
    ..close();
}

Path _bubblePath(Size size) {
  final w = size.width;
  final h = size.height;
  return Path()
    ..addRRect(
      RRect.fromLTRBR(
        w * 0.08,
        h * 0.14,
        w * 0.92,
        h * 0.66,
        Radius.circular(h * 0.18),
      ),
    )
    ..moveTo(w * 0.28, h * 0.62)
    ..lineTo(w * 0.30, h * 0.88)
    ..lineTo(w * 0.50, h * 0.62)
    ..close();
}

Path _arrowPath(Size size) {
  final w = size.width;
  final h = size.height;
  return Path()
    ..moveTo(w * 0.10, h * 0.42)
    ..lineTo(w * 0.62, h * 0.42)
    ..lineTo(w * 0.62, h * 0.24)
    ..lineTo(w * 0.92, h * 0.50)
    ..lineTo(w * 0.62, h * 0.76)
    ..lineTo(w * 0.62, h * 0.58)
    ..lineTo(w * 0.10, h * 0.58)
    ..close();
}

Path _polygonPath(Size size, {required int points, double inner = 0.45}) {
  final centre = size.center(Offset.zero);
  final radius = size.shortestSide * 0.44;
  final path = Path();
  for (var i = 0; i < points * 2; i++) {
    final isOuter = i.isEven;
    final r = radius * (isOuter ? 1 : inner);
    // Start at twelve o'clock so the shape reads upright.
    final angle = -math.pi / 2 + i * math.pi / points;
    final point = centre + Offset(r * math.cos(angle), r * math.sin(angle));
    if (i == 0) {
      path.moveTo(point.dx, point.dy);
    } else {
      path.lineTo(point.dx, point.dy);
    }
  }
  return path..close();
}
