import 'dart:math' as math;

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

/// Direct-manipulation crop, drawn over the untouched frame.
///
/// The rect stays in normalized coordinates the whole way, which is what lets
/// it survive a rotation and what the exporter consumes verbatim.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    required this.crop,
    required this.onChanged,
    required this.onCommit,
    this.aspectRatio,
    this.sourceAspectRatio = 1,
    super.key,
  });

  final CropRect crop;
  final ValueChanged<CropRect> onChanged;
  final VoidCallback onCommit;

  /// Locked on-screen width/height, or null for free-form.
  final double? aspectRatio;
  final double sourceAspectRatio;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  _Grip? _grip;
  CropRect? _start;
  Offset _from = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _start1(d.localPosition, size),
          onPanUpdate: (d) => _update(d.localPosition, size),
          onPanEnd: (_) {
            widget.onCommit();
            setState(() => _grip = null);
          },
          child: CustomPaint(
            painter: _CropPainter(
              crop: widget.crop,
              dragging: _grip != null,
              chrome: MonokitTheme.of(context).colors.onMedia,
              scrim: MonokitTheme.of(context).colors.scrimStrong,
            ),
          ),
        );
      },
    );
  }

  void _start1(Offset point, Size size) {
    final rect = _pixels(widget.crop, size);
    setState(() {
      _grip = _gripFor(point, rect);
      _start = widget.crop;
      _from = point;
    });
  }

  void _update(Offset point, Size size) {
    final grip = _grip;
    final start = _start;
    if (grip == null || start == null) return;

    final dx = (point.dx - _from.dx) / size.width;
    final dy = (point.dy - _from.dy) / size.height;
    widget.onChanged(
      _resize(
        start: start,
        grip: grip,
        dx: dx,
        dy: dy,
        aspectRatio: widget.aspectRatio,
        sourceAspectRatio: widget.sourceAspectRatio,
      ),
    );
  }

  static Rect _pixels(CropRect crop, Size size) => Rect.fromLTWH(
    crop.left * size.width,
    crop.top * size.height,
    crop.width * size.width,
    crop.height * size.height,
  );

  static _Grip _gripFor(Offset point, Rect rect) {
    const slop = 32.0;
    final left = (point.dx - rect.left).abs() <= slop;
    final right = (point.dx - rect.right).abs() <= slop;
    final top = (point.dy - rect.top).abs() <= slop;
    final bottom = (point.dy - rect.bottom).abs() <= slop;

    // Corners win over edges: they are the smaller target and the one a
    // fingertip landing in the overlap is aiming for.
    if (left && top) return _Grip.topLeft;
    if (right && top) return _Grip.topRight;
    if (left && bottom) return _Grip.bottomLeft;
    if (right && bottom) return _Grip.bottomRight;
    if (left) return _Grip.left;
    if (right) return _Grip.right;
    if (top) return _Grip.top;
    if (bottom) return _Grip.bottom;
    return _Grip.move;
  }
}

enum _Grip {
  move,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
}

CropRect _resize({
  required CropRect start,
  required _Grip grip,
  required double dx,
  required double dy,
  required double? aspectRatio,
  required double sourceAspectRatio,
  double minimum = 0.08,
}) {
  if (grip == _Grip.move) {
    return CropRect(
      left: (start.left + dx).clamp(0.0, 1.0 - start.width),
      top: (start.top + dy).clamp(0.0, 1.0 - start.height),
      width: start.width,
      height: start.height,
    );
  }

  var left = start.left;
  var top = start.top;
  var right = start.right;
  var bottom = start.bottom;

  switch (grip) {
    case _Grip.topLeft:
      left += dx;
      top += dy;
    case _Grip.topRight:
      right += dx;
      top += dy;
    case _Grip.bottomLeft:
      left += dx;
      bottom += dy;
    case _Grip.bottomRight:
      right += dx;
      bottom += dy;
    case _Grip.left:
      left += dx;
    case _Grip.right:
      right += dx;
    case _Grip.top:
      top += dy;
    case _Grip.bottom:
      bottom += dy;
    case _Grip.move:
      break;
  }

  left = left.clamp(0.0, 1.0);
  top = top.clamp(0.0, 1.0);
  right = right.clamp(0.0, 1.0);
  bottom = bottom.clamp(0.0, 1.0);

  var width = math.max(right - left, minimum);
  var height = math.max(bottom - top, minimum);

  if (aspectRatio != null) {
    // The lock is on the ratio the author sees; in normalized fractions that is
    // scaled by the source's own aspect, because a fraction of width and a
    // fraction of height are different numbers of pixels.
    final normalized = aspectRatio / sourceAspectRatio;
    if (width / normalized >= height) {
      height = width / normalized;
    } else {
      width = height * normalized;
    }
    if (height > 1) {
      height = 1;
      width = height * normalized;
    }
    if (width > 1) {
      width = 1;
      height = width / normalized;
    }
  }

  // Anchor whichever edge the drag did not touch.
  final anchorRight =
      grip == _Grip.topLeft || grip == _Grip.bottomLeft || grip == _Grip.left;
  final anchorBottom =
      grip == _Grip.topLeft || grip == _Grip.topRight || grip == _Grip.top;

  return CropRect(
    left: anchorRight ? right - width : left,
    top: anchorBottom ? bottom - height : top,
    width: width,
    height: height,
  ).clampedToBounds();
}

class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.crop,
    required this.dragging,
    required this.chrome,
    required this.scrim,
  });

  final CropRect crop;
  final bool dragging;
  final Color chrome;
  final Color scrim;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      crop.left * size.width,
      crop.top * size.height,
      crop.width * size.width,
      crop.height * size.height,
    );

    // One even-odd pass so the corners do not double-darken.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(rect),
      ),
      Paint()..color = scrim,
    );

    // Thirds only while dragging — a permanent grid is noise once the
    // composition is settled.
    if (dragging) {
      final grid = Paint()
        ..color = chrome.withValues(alpha: 0.4)
        ..strokeWidth = 1;
      for (var i = 1; i < 3; i++) {
        final x = rect.left + rect.width * i / 3;
        final y = rect.top + rect.height * i / 3;
        canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
        canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
      }
    }

    canvas.drawRect(
      rect,
      Paint()
        ..color = chrome.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Corner brackets, drawn inside the border so they read as grab targets.
    final bracket = Paint()
      ..color = chrome
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.square;
    final length = math.min(24.0, math.min(rect.width, rect.height) / 3);
    for (final (corner, sx, sy) in [
      (rect.topLeft, 1.0, 1.0),
      (rect.topRight, -1.0, 1.0),
      (rect.bottomLeft, 1.0, -1.0),
      (rect.bottomRight, -1.0, -1.0),
    ]) {
      final origin = corner.translate(sx * 1.5, sy * 1.5);
      canvas.drawLine(origin, origin.translate(sx * length, 0), bracket);
      canvas.drawLine(origin, origin.translate(0, sy * length), bracket);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.crop != crop || old.dragging != dragging || old.chrome != chrome;
}
