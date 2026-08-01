import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

import '../ui/lens_icons.dart';
import 'editor_controller.dart';
import 'editor_draft.dart';

/// The interactive editing surface.
///
/// Everything here is the host's work — monolens ships no gestures and no
/// painter. What it ships is the coordinate system these produce: annotations
/// normalized against the output frame, which the platform then reproduces
/// exactly. This widget's job is to make sure what the author sees while
/// dragging matches what the exporter will burn in.
class MediaCanvas extends StatefulWidget {
  const MediaCanvas({
    required this.controller,
    required this.media,
    required this.sourceAspectRatio,
    super.key,
  });

  final EditorController controller;

  /// The image or video widget, rendered at full frame; this widget applies the
  /// crop and rotation around it.
  final Widget media;

  final double sourceAspectRatio;

  @override
  State<MediaCanvas> createState() => _MediaCanvasState();
}

class _MediaCanvasState extends State<MediaCanvas> {
  _Drag? _drag;

  EditorController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final draft = controller.draft;
    final cropping = controller.mode == EditorMode.crop;

    // While cropping the whole frame stays visible so the author can see what
    // they are cutting away; otherwise the canvas shows the result.
    final aspect = cropping
        ? widget.sourceAspectRatio
        : draft.outputAspectRatio(widget.sourceAspectRatio);
    final theme = MonokitTheme.of(context);

    return Center(
      child: AspectRatio(
        aspectRatio: aspect <= 0 ? 1 : aspect,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return ClipRRect(
              borderRadius: BorderRadius.circular(theme.radii.xl),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (cropping) widget.media else _framed(draft, size),
                  if (!cropping) ...[
                    // Blur is beneath everything else, as it is in the export:
                    // a caption over a blurred face has to stay legible.
                    ..._blurs(draft, size),
                    // Stickers are files, so they render as widgets rather than
                    // in the painter — a CustomPainter cannot decode an image
                    // synchronously.
                    ..._stickers(draft, size),
                    CustomPaint(
                      painter: _AnnotationPainter(
                        annotations: draft.annotations,
                        selectedId: controller.selectedId,
                        accent: theme.colors.tint,
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) => _onTap(details.localPosition, size),
                      // Scale rather than pan, because one recognizer has to
                      // serve both: a pan recognizer never reports a second
                      // finger, so pinch and twist are invisible to it, and
                      // GestureDetector refuses to carry both at once.
                      onScaleStart: (d) => _onScaleStart(d, size),
                      onScaleUpdate: (d) => _onScaleUpdate(d, size),
                      onScaleEnd: (_) => _endGesture(),
                    ),
                    ..._handles(size),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The media with the crop and rotation applied, so the canvas shows exactly
  /// what the export will produce.
  Widget _framed(EditorDraft draft, Size size) {
    final crop = draft.crop;
    final quarterTurns = switch (draft.rotation) {
      MonoRotation.none => 0,
      MonoRotation.quarterTurn => 1,
      MonoRotation.halfTurn => 2,
      MonoRotation.threeQuarterTurns => 3,
    };

    return RotatedBox(
      quarterTurns: quarterTurns,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Blow the frame up so the kept region fills the box, then slide the
          // discarded part out of view.
          final width = constraints.maxWidth / crop.width;
          final height = constraints.maxHeight / crop.height;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: -crop.left * width,
                  top: -crop.top * height,
                  width: width,
                  height: height,
                  child: widget.media,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A real blur of the frame beneath, rather than a frosted stand-in.
  ///
  /// The painter cannot do this — sampling what is already on the canvas needs
  /// a backdrop filter, not a `Paint`. It matters more than it sounds: a white
  /// wash tells the author a region is *marked*, and this tells them what the
  /// export will actually look like, which is the whole point of the preview.
  List<Widget> _blurs(EditorDraft draft, Size size) => [
    for (final annotation in draft.annotations)
      if (annotation is BlurAnnotation)
        Positioned.fromRect(
          rect: annotationBounds(annotation, size),
          child: IgnorePointer(
            child: ClipPath(
              clipper: _ShapeClipper(annotation.shape),
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  // Scaled against the region the way the native blur scales
                  // its radius, so a small region is softened rather than
                  // obliterated.
                  sigmaX: _sigma(annotation, size),
                  sigmaY: _sigma(annotation, size),
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
  ];

  double _sigma(BlurAnnotation annotation, Size size) {
    final box = annotationBounds(annotation, size);
    return math.max(1.5, annotation.strength * box.shortestSide * 0.16);
  }

  List<Widget> _stickers(EditorDraft draft, Size size) => [
    for (final annotation in draft.annotations)
      if (annotation is StickerAnnotation)
        Positioned(
          left: annotation.rect.left * size.width,
          top: annotation.rect.top * size.height,
          width: annotation.rect.width * size.width,
          height: annotation.rect.height * size.height,
          child: IgnorePointer(
            child: Transform.rotate(
              angle: annotation.rotation,
              child: Opacity(
                opacity: annotation.opacity.clamp(0.0, 1.0),
                // Both exporters stretch a sticker to fill its rect, so the
                // preview has to as well. BoxFit.contain would look better and
                // be a lie.
                child: Image.file(File(annotation.imagePath), fit: BoxFit.fill),
              ),
            ),
          ),
        ),
  ];

  // Gestures

  Offset _normalize(Offset point, Size size) => Offset(
    (point.dx / size.width).clamp(0.0, 1.0),
    (point.dy / size.height).clamp(0.0, 1.0),
  );

  void _onTap(Offset point, Size size) {
    final at = _normalize(point, size);

    if (controller.tool == EditorTool.select) {
      controller.select(_hitTest(point, size)?.id);
      return;
    }

    final created = switch (controller.tool) {
      EditorTool.blur => BlurAnnotation(
        rect: controller.squareAt(at),
        shape: BlurShape.oval,
      ),
      EditorTool.sticker when controller.stickerPath != null =>
        StickerAnnotation(
          imagePath: controller.stickerPath!,
          rect: controller.squareAt(at),
        ),
      _ => null,
    };
    if (created != null) controller.add(created);
  }

  void _onScaleStart(ScaleStartDetails details, Size size) {
    final point = details.localFocalPoint;

    // Two fingers always mean transform, whatever tool is armed. Pinching is
    // never an attempt to draw.
    if (details.pointerCount >= 2) {
      final target = controller.selected ?? _hitTest(point, size);
      if (target == null) return;
      controller.select(target.id);
      setState(
        () => _drag = _Drag.pinch(
          target.id,
          baseline: target,
          grabbedAt: _normalize(point, size),
        ),
      );
      return;
    }

    if (controller.tool == EditorTool.draw) {
      final stroke = StrokeAnnotation(
        points: [_normalize(point, size)],
        colorArgb: controller.color,
        widthFraction: controller.strokeWidth,
      );
      controller.push(
        controller.draft.withAnnotations([
          ...controller.draft.annotations,
          stroke,
        ]),
        coalesceKey: stroke.id,
      );
      setState(() => _drag = _Drag.stroke(stroke.id));
      return;
    }

    final hit = _hitTest(point, size);
    if (hit != null) {
      controller.select(hit.id);
      setState(
        () => _drag = _Drag.move(hit.id, grabbedAt: _normalize(point, size)),
      );
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size size) {
    final drag = _drag;
    if (drag == null) return;
    final annotation = controller.draft.annotations.byId(drag.id);
    if (annotation == null) return;
    final point = details.localFocalPoint;

    switch (drag.kind) {
      case _DragKind.stroke:
        if (annotation is! StrokeAnnotation) return;
        controller.update(
          annotation.extendedTo(_normalize(point, size)),
          coalesceKey: drag.id,
        );

      case _DragKind.move:
        final delta = _normalize(point, size) - drag.grabbedAt!;
        controller.update(
          _moved(annotation, delta),
          coalesceKey: '${drag.id}.move',
        );
        setState(
          () => _drag = drag.copyWith(grabbedAt: _normalize(point, size)),
        );

      case _DragKind.pinch:
        // Applied to the annotation as it was when the fingers landed, not to
        // its current value: `scale` and `rotation` are cumulative from the
        // start of the gesture, so compounding them would run away.
        controller.update(
          _transformedFrom(
            drag.baseline!,
            scale: details.scale,
            rotation: details.rotation,
            delta: _normalize(point, size) - drag.grabbedAt!,
            size: size,
          ),
          coalesceKey: '${drag.id}.pinch',
        );

      case _DragKind.handle:
        // Driven by the handle's own recognizer, not by the canvas.
        break;
    }
  }

  /// Drives the corner handle, which carries its own recognizer.
  ///
  /// [travel] is the accumulated finger movement since the grab, which is a
  /// translation and therefore the same in any coordinate space -- so the
  /// handle never has to convert between its box and the canvas's.
  void _onHandleUpdate(Offset travel, Size size) {
    final drag = _drag;
    if (drag == null || drag.kind != _DragKind.handle) return;

    final start = drag.startVector!;
    if (start.distance < 1) return;
    final vector = start + travel;

    controller.update(
      _transformedFrom(
        drag.baseline!,
        scale: vector.distance / start.distance,
        rotation: vector.direction - start.direction,
        delta: Offset.zero,
        size: size,
      ),
      coalesceKey: '${drag.id}.handle',
    );
  }

  void _endGesture() {
    controller.endGesture();
    setState(() => _drag = null);
  }

  // Selection handles, as widgets so they take taps of their own.

  List<Widget> _handles(Size size) {
    final selected = controller.selected;
    if (selected == null || _drag?.kind == _DragKind.stroke) return const [];

    final box = annotationBox(selected, size);
    const target = 48.0;

    // On the turned outline, not on the square one it was drawn from — the
    // handles have to be where the corners look like they are.
    final resizeAt = box.corner(1, 1, inflate: 6);
    final removeAt = box.corner(-1, -1, inflate: 6);

    // Each handle carries its own recognizer. It cannot rely on the canvas
    // detector underneath it: a Stack's hit test stops at the topmost child
    // that reports a hit, and the icon inside a handle reports one -- so a
    // drag that starts on a handle never reaches the canvas at all.
    return [
      Positioned(
        left: resizeAt.dx - target / 2,
        top: resizeAt.dy - target / 2,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) {
            final grabbed = controller.selected;
            if (grabbed == null) return;
            setState(
              () => _drag = _Drag.handle(
                grabbed.id,
                baseline: grabbed,
                // From the turned corner, so the angle the drag adds is
                // measured from where the finger actually started.
                startVector: resizeAt - box.center,
                // Global, because the handle itself travels with the corner it
                // is resizing: a local delta would fold the widget's own
                // movement back into the gesture.
                grabbedAt: d.globalPosition,
              ),
            );
          },
          onPanUpdate: (d) => _onHandleUpdate(
            d.globalPosition - (_drag?.grabbedAt ?? d.globalPosition),
            size,
          ),
          onPanEnd: (_) => _endGesture(),
          child: const SizedBox(
            width: target,
            height: target,
            child: Center(child: _HandleDot(glyph: LensGlyph.resize)),
          ),
        ),
      ),
      Positioned(
        left: (removeAt.dx - target / 2).clamp(0.0, size.width - target),
        top: (removeAt.dy - target / 2).clamp(0.0, size.height - target),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => controller.remove(selected.id),
          child: const SizedBox(
            width: target,
            height: target,
            child: Center(
              child: _HandleDot(glyph: LensGlyph.trash, destructive: true),
            ),
          ),
        ),
      ),
    ];
  }

  // Geometry

  Annotation? _hitTest(Offset point, Size size) {
    // Front to back: the thing drawn last is the thing on top.
    for (final annotation in controller.draft.annotations.reversed) {
      if (annotation is StrokeAnnotation) {
        if (_nearStroke(annotation, point, size)) return annotation;
        continue;
      }
      // Against the turned box, so what is tappable is what is outlined.
      if (annotationBox(annotation, size).contains(point, slop: 8)) {
        return annotation;
      }
    }
    return null;
  }

  bool _nearStroke(StrokeAnnotation stroke, Offset point, Size size) {
    final tolerance = math.max(16.0, stroke.widthFraction * size.shortestSide);
    for (final normalized in stroke.points) {
      final at = Offset(
        normalized.dx * size.width,
        normalized.dy * size.height,
      );
      if ((at - point).distance <= tolerance) return true;
    }
    return false;
  }

  Annotation _moved(Annotation annotation, Offset delta) =>
      switch (annotation) {
        TextAnnotation() => annotation.copyWith(
          center: Offset(
            (annotation.center.dx + delta.dx).clamp(0.0, 1.0),
            (annotation.center.dy + delta.dy).clamp(0.0, 1.0),
          ),
        ),
        StickerAnnotation() => annotation.copyWith(
          rect: _shifted(annotation.rect, delta),
        ),
        BlurAnnotation() => annotation.copyWith(
          rect: _shifted(annotation.rect, delta),
        ),
        StrokeAnnotation() => annotation.copyWith(
          points: [
            for (final point in annotation.points)
              Offset(
                (point.dx + delta.dx).clamp(0.0, 1.0),
                (point.dy + delta.dy).clamp(0.0, 1.0),
              ),
          ],
        ),
      };

  CropRect _shifted(CropRect rect, Offset delta) => CropRect(
    left: (rect.left + delta.dx).clamp(0.0, 1 - rect.width),
    top: (rect.top + delta.dy).clamp(0.0, 1 - rect.height),
    width: rect.width,
    height: rect.height,
  ).clampedToBounds();

  /// Scales, turns and shifts [base] by amounts measured from the start of a
  /// gesture.
  ///
  /// Relative to a baseline rather than to the live value, because both the
  /// pinch and the handle report totals rather than increments — applying a
  /// total to an already-transformed annotation compounds it exponentially.
  Annotation _transformedFrom(
    Annotation base, {
    required double scale,
    required double rotation,
    required Offset delta,
    required Size size,
  }) {
    final factor = scale.clamp(0.15, 8.0);
    return switch (base) {
      // Text scales by type size, which is what keeps it crisp — scaling the
      // glyphs as pixels would soften them.
      TextAnnotation() => base.copyWith(
        heightFraction: (base.heightFraction * factor).clamp(0.02, 0.8),
        rotation: base.rotation + rotation,
        center: Offset(
          (base.center.dx + delta.dx).clamp(0.0, 1.0),
          (base.center.dy + delta.dy).clamp(0.0, 1.0),
        ),
      ),
      StickerAnnotation() => base.copyWith(
        rect: _shifted(_resized(base.rect, factor), delta),
        rotation: base.rotation + rotation,
      ),
      // A blur has no orientation worth rotating — an oval mask looks the same
      // turned, and a rectangle turned would need a mask this UI cannot express.
      BlurAnnotation() => base.copyWith(
        rect: _shifted(_resized(base.rect, factor), delta),
      ),
      // The line itself scales and turns, not just its weight: pinching a
      // drawn shape and having only its thickness change reads as broken.
      StrokeAnnotation() => base.copyWith(
        points: _transformedPoints(base.points, factor, rotation, delta, size),
        widthFraction: (base.widthFraction * factor).clamp(0.002, 0.15),
      ),
    };
  }

  /// Turns and scales [points] about their own centre.
  ///
  /// Done in pixels and converted back, because normalized space is not
  /// isotropic — a fraction of the width and a fraction of the height are
  /// different numbers of pixels, so rotating in it would shear the line.
  List<Offset> _transformedPoints(
    List<Offset> points,
    double scale,
    double rotation,
    Offset delta,
    Size size,
  ) {
    if (points.isEmpty) return points;

    var sumX = 0.0;
    var sumY = 0.0;
    for (final point in points) {
      sumX += point.dx;
      sumY += point.dy;
    }
    final centre = Offset(sumX / points.length, sumY / points.length);
    final cos = math.cos(rotation);
    final sin = math.sin(rotation);

    final moved = <Offset>[];
    for (final point in points) {
      final x = (point.dx - centre.dx) * size.width;
      final y = (point.dy - centre.dy) * size.height;
      moved.add(
        Offset(
          (centre.dx + (x * cos - y * sin) * scale / size.width + delta.dx)
              .clamp(0.0, 1.0),
          (centre.dy + (x * sin + y * cos) * scale / size.height + delta.dy)
              .clamp(0.0, 1.0),
        ),
      );
    }
    return moved;
  }

  CropRect _resized(CropRect rect, double scale) {
    final width = (rect.width * scale).clamp(0.04, 1.0);
    final height = (rect.height * scale).clamp(0.04, 1.0);
    final centreX = rect.left + rect.width / 2;
    final centreY = rect.top + rect.height / 2;
    return CropRect(
      left: centreX - width / 2,
      top: centreY - height / 2,
      width: width,
      height: height,
    ).clampedToBounds();
  }
}

/// The on-screen box an annotation occupies.
///
/// Shared with the painter so the outline the author sees and the region their
/// finger hits are the same rectangle — the classic source of "I tapped it and
/// nothing happened".
/// An annotation's box *and* the angle it sits at.
///
/// Selection chrome has to agree with the thing it is describing: an outline
/// that stays square around a turned sticker reads as a bug, and a handle that
/// stays at the square corner is worse -- it is nowhere near the corner the
/// author is looking at.
///
/// This also keeps the outline and the touch target computed from one place,
/// which is what stops them drifting into "I tapped it and nothing happened".
@immutable
class AnnotationBox {
  const AnnotationBox({required this.rect, required this.rotation});

  /// Axis-aligned, before the rotation is applied.
  final Rect rect;

  /// Radians, about [rect]'s centre.
  final double rotation;

  Offset get center => rect.center;

  /// A corner of the box, turned into canvas coordinates.
  ///
  /// [sx] and [sy] are -1 or 1, picking which corner. [inflate] grows the box
  /// first, so a handle can sit on a drawn outline rather than inside it.
  Offset corner(double sx, double sy, {double inflate = 0}) {
    final box = rect.inflate(inflate);
    return _toCanvas(
      Offset(
        box.center.dx + sx * box.width / 2,
        box.center.dy + sy * box.height / 2,
      ),
    );
  }

  /// Whether [point] falls inside the turned box.
  bool contains(Offset point, {double slop = 0}) {
    final local = _toLocal(point);
    return rect.inflate(slop).contains(local);
  }

  Offset _toCanvas(Offset point) => _spin(point, rotation);
  Offset _toLocal(Offset point) => _spin(point, -rotation);

  Offset _spin(Offset point, double angle) {
    final centre = rect.center;
    final vector = point - centre;
    final cos = math.cos(angle);
    final sin = math.sin(angle);
    return centre +
        Offset(
          vector.dx * cos - vector.dy * sin,
          vector.dx * sin + vector.dy * cos,
        );
  }
}

/// The oriented box an annotation occupies.
///
/// A stroke has no rotation of its own — turning one rewrites its points — so
/// its bounds are genuinely axis-aligned, and a blur is deliberately never
/// turned at all.
AnnotationBox annotationBox(Annotation annotation, Size size) => AnnotationBox(
  rect: annotationBounds(annotation, size),
  rotation: switch (annotation) {
    TextAnnotation(:final rotation) => rotation,
    StickerAnnotation(:final rotation) => rotation,
    BlurAnnotation() || StrokeAnnotation() => 0.0,
  },
);

Rect annotationBounds(Annotation annotation, Size size) {
  switch (annotation) {
    case TextAnnotation():
      final painter = TextPainter(
        text: TextSpan(
          text: annotation.text,
          style: TextStyle(
            fontSize: annotation.heightFraction * size.height,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return Rect.fromCenter(
        center: Offset(
          annotation.center.dx * size.width,
          annotation.center.dy * size.height,
        ),
        width: painter.width,
        height: painter.height,
      );

    case StickerAnnotation(:final rect):
    case BlurAnnotation(:final rect):
      return Rect.fromLTWH(
        rect.left * size.width,
        rect.top * size.height,
        rect.width * size.width,
        rect.height * size.height,
      );

    case StrokeAnnotation(:final points):
      if (points.isEmpty) return Rect.zero;
      var left = double.infinity;
      var top = double.infinity;
      var right = -double.infinity;
      var bottom = -double.infinity;
      for (final point in points) {
        left = math.min(left, point.dx * size.width);
        top = math.min(top, point.dy * size.height);
        right = math.max(right, point.dx * size.width);
        bottom = math.max(bottom, point.dy * size.height);
      }
      return Rect.fromLTRB(
        left,
        top,
        right,
        bottom,
      ).inflate(annotation.widthFraction * size.shortestSide / 2);
  }
}

class _HandleDot extends StatelessWidget {
  const _HandleDot({required this.glyph, this.destructive = false});

  final LensGlyph glyph;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = MonokitTheme.of(context).colors;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: destructive ? colors.danger : colors.onMedia,
        shape: BoxShape.circle,
        // A handle sits on the picture, so it needs its own separation from
        // whatever happens to be behind it.
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: LensIcon(
          glyph,
          size: 15,
          strokeWidth: 1.9,
          color: destructive ? colors.onStatus : colors.canvas,
        ),
      ),
    );
  }
}

enum _DragKind { move, pinch, handle, stroke }

class _Drag {
  const _Drag(
    this.kind,
    this.id, {
    this.grabbedAt,
    this.baseline,
    this.startVector,
  });

  factory _Drag.move(String id, {required Offset grabbedAt}) =>
      _Drag(_DragKind.move, id, grabbedAt: grabbedAt);

  factory _Drag.pinch(
    String id, {
    required Annotation baseline,
    required Offset grabbedAt,
  }) => _Drag(_DragKind.pinch, id, baseline: baseline, grabbedAt: grabbedAt);

  factory _Drag.handle(
    String id, {
    required Annotation baseline,
    required Offset startVector,
    required Offset grabbedAt,
  }) => _Drag(
    _DragKind.handle,
    id,
    baseline: baseline,
    startVector: startVector,
    grabbedAt: grabbedAt,
  );

  factory _Drag.stroke(String id) => _Drag(_DragKind.stroke, id);

  final _DragKind kind;
  final String id;
  final Offset? grabbedAt;

  /// The annotation as it was when the gesture began. Scale and rotation are
  /// reported as totals, so they have to be applied to this rather than to
  /// whatever the last frame produced.
  final Annotation? baseline;

  final Offset? startVector;

  _Drag copyWith({Offset? grabbedAt}) => _Drag(
    kind,
    id,
    grabbedAt: grabbedAt ?? this.grabbedAt,
    baseline: baseline,
    startVector: startVector,
  );
}

/// A preview of what the exporter will burn in.
///
/// Approximate on purpose: the export is the source of truth, and keeping the
/// preview cheap is what lets it repaint on every drag sample.
class _AnnotationPainter extends CustomPainter {
  const _AnnotationPainter({
    required this.annotations,
    required this.selectedId,
    required this.accent,
  });

  final List<Annotation> annotations;
  final String? selectedId;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    for (final annotation in annotations) {
      switch (annotation) {
        case BlurAnnotation():
          // Drawn as a backdrop filter beneath this layer; nothing to paint.
          break;

        case StrokeAnnotation(
          :final points,
          :final colorArgb,
          :final widthFraction,
        ):
          if (points.isEmpty) break;
          final paint = Paint()
            ..color = Color(colorArgb)
            ..style = PaintingStyle.stroke
            ..strokeWidth = widthFraction * size.shortestSide
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round;
          if (points.length == 1) {
            canvas.drawCircle(
              Offset(
                points.first.dx * size.width,
                points.first.dy * size.height,
              ),
              paint.strokeWidth / 2,
              Paint()..color = Color(colorArgb),
            );
            break;
          }
          final path = Path()
            ..moveTo(
              points.first.dx * size.width,
              points.first.dy * size.height,
            );
          for (final point in points.skip(1)) {
            path.lineTo(point.dx * size.width, point.dy * size.height);
          }
          canvas.drawPath(path, paint);

        case TextAnnotation():
          _paintText(canvas, size, annotation);

        case StickerAnnotation():
          // Drawn as a widget above; nothing to paint here.
          break;
      }
    }

    final selected = selectedId == null ? null : annotations.byId(selectedId!);
    if (selected != null) _paintSelection(canvas, selected, size);
  }

  /// A hairline plus corner ticks, in the accent.
  ///
  /// A plain white rectangle over a photograph is indistinguishable from
  /// something in the picture; the ticks and the accent say "chrome".
  void _paintSelection(Canvas canvas, Annotation selected, Size size) {
    final box = annotationBox(selected, size);
    final bounds = box.rect.inflate(6);

    // Turn the canvas rather than the geometry: the outline is then authored
    // in the annotation's own frame, where it is a plain rectangle.
    canvas.save();
    canvas.translate(box.center.dx, box.center.dy);
    canvas.rotate(box.rotation);
    canvas.translate(-box.center.dx, -box.center.dy);

    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(6)),
      Paint()
        ..color = accent.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    final tick = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final arm = math.min(12.0, bounds.shortestSide / 3);
    for (final (corner, sx, sy) in [
      (bounds.topLeft, 1.0, 1.0),
      (bounds.topRight, -1.0, 1.0),
      (bounds.bottomLeft, 1.0, -1.0),
      (bounds.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner.translate(sx * arm, 0), tick);
      canvas.drawLine(corner, corner.translate(0, sy * arm), tick);
    }

    canvas.restore();
  }

  void _paintText(Canvas canvas, Size size, TextAnnotation annotation) {
    final painter = TextPainter(
      text: TextSpan(
        text: annotation.text,
        style: TextStyle(
          color: Color(annotation.colorArgb),
          fontSize: annotation.heightFraction * size.height,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final centre = Offset(
      annotation.center.dx * size.width,
      annotation.center.dy * size.height,
    );
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(annotation.rotation);

    final background = annotation.backgroundArgb;
    if (background != null) {
      final padding = painter.height * 0.14;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: painter.width + padding * 2,
            height: painter.height + padding,
          ),
          Radius.circular(padding),
        ),
        Paint()..color = Color(background),
      );
    }
    painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AnnotationPainter old) =>
      old.annotations != annotations ||
      old.selectedId != selectedId ||
      old.accent != accent;
}

/// Clips a blur to the shape the export will use.
class _ShapeClipper extends CustomClipper<Path> {
  const _ShapeClipper(this.shape);

  final BlurShape shape;

  @override
  Path getClip(Size size) {
    final box = Offset.zero & size;
    return switch (shape) {
      BlurShape.oval => Path()..addOval(box),
      BlurShape.rectangle => Path()..addRect(box),
    };
  }

  @override
  bool shouldReclip(_ShapeClipper old) => old.shape != shape;
}
