import '../messages.g.dart';
import 'annotations.dart';

/// Flattens the sealed [Annotation] types onto the single wire struct.
///
/// The ugliness is deliberately confined here: Dart callers get an exhaustive
/// sealed hierarchy, the three native sides get one record with a kind tag to
/// switch on, and neither has to know about the other's shape.
extension AnnotationWire on Annotation {
  AnnotationSpec toSpec() => switch (this) {
    TextAnnotation(
      :final text,
      :final center,
      :final heightFraction,
      :final colorArgb,
      :final backgroundArgb,
      :final rotation,
    ) =>
      AnnotationSpec(
        kind: AnnotationKind.text,
        rotation: rotation,
        text: text,
        centerX: center.dx,
        centerY: center.dy,
        heightFraction: heightFraction,
        colorArgb: colorArgb,
        backgroundArgb: backgroundArgb,
      ),

    StickerAnnotation(
      :final imagePath,
      :final rect,
      :final rotation,
      :final opacity,
    ) =>
      AnnotationSpec(
        kind: AnnotationKind.sticker,
        rotation: rotation,
        imagePath: imagePath,
        rect: rect.toRequest(),
        opacity: opacity,
      ),

    BlurAnnotation(:final rect, :final strength, :final shape) =>
      AnnotationSpec(
        kind: AnnotationKind.blur,
        rotation: 0,
        rect: rect.toRequest(),
        strength: strength,
        shape: switch (shape) {
          BlurShape.rectangle => BlurShapeSpec.rectangle,
          BlurShape.oval => BlurShapeSpec.oval,
        },
      ),

    StrokeAnnotation(:final points, :final colorArgb, :final widthFraction) =>
      AnnotationSpec(
        kind: AnnotationKind.stroke,
        rotation: 0,
        // Flattened x, y pairs — a nested point type would need a codec entry
        // in all three languages to say nothing extra.
        points: [
          for (final point in points) ...[point.dx, point.dy],
        ],
        colorArgb: colorArgb,
        widthFraction: widthFraction,
      ),
  };
}

extension AnnotationListWire on List<Annotation> {
  List<AnnotationSpec> toSpecs() => [for (final a in this) a.toSpec()];
}
