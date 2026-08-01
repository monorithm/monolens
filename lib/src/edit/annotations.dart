/// @docImport '../media/captured_media.dart';
library;

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show listEquals;

import 'edit_specs.dart';

/// How a blur region is masked.
enum BlurShape {
  rectangle,

  /// An ellipse inscribed in the region — what a face usually wants.
  oval,
}

/// Something painted over the media.
///
/// Every geometry here is **normalized against the output frame** — the frame
/// as it looks after the crop and rotation, which is the frame the author was
/// looking at when they placed it. That keeps an annotation valid when the crop
/// changes underneath it, and it is the only interpretation that means the same
/// thing for a still and for every frame of a clip.
///
/// Annotations are painted in list order, back to front.
sealed class Annotation {
  const Annotation({required this.id});

  /// Stable across edits, so a host can select, move or delete one, and so undo
  /// can tell "moved the caption" from "added a second caption".
  final String id;

  /// Mints an id. Hosts may supply their own instead.
  static String newId() =>
      'a${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  static int _seq = 0;
}

/// Text burned into the media.
///
/// Emoji are text: they are glyphs the platform already knows how to shape, so
/// there is no separate emoji primitive and no emoji asset table to keep
/// current. [AnnotationFactories.emoji] is the convenience that says so out loud.
final class TextAnnotation extends Annotation {
  TextAnnotation({
    required this.text,
    required this.center,
    this.heightFraction = 0.08,
    this.colorArgb = 0xFFFFFFFF,
    this.backgroundArgb,
    this.rotation = 0,
    String? id,
  }) : super(id: id ?? Annotation.newId());

  final String text;

  /// Centre of the text box, in 0–1 of the output frame.
  final Offset center;

  /// Cap height as a fraction of the output's height, so the same annotation
  /// looks the same on a 720p export and a 4K one.
  final double heightFraction;

  final int colorArgb;

  /// Painted behind the glyphs, with padding. Null draws none.
  final int? backgroundArgb;

  /// Clockwise, in radians.
  final double rotation;

  TextAnnotation copyWith({
    String? text,
    Offset? center,
    double? heightFraction,
    int? colorArgb,
    int? backgroundArgb,
    double? rotation,
  }) => TextAnnotation(
    id: id,
    text: text ?? this.text,
    center: center ?? this.center,
    heightFraction: heightFraction ?? this.heightFraction,
    colorArgb: colorArgb ?? this.colorArgb,
    backgroundArgb: backgroundArgb ?? this.backgroundArgb,
    rotation: rotation ?? this.rotation,
  );

  @override
  bool operator ==(Object other) =>
      other is TextAnnotation &&
      other.id == id &&
      other.text == text &&
      other.center == center &&
      other.heightFraction == heightFraction &&
      other.colorArgb == colorArgb &&
      other.backgroundArgb == backgroundArgb &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(
    id,
    text,
    center,
    heightFraction,
    colorArgb,
    backgroundArgb,
    rotation,
  );
}

/// An image composited over the media — a sticker, a badge, a watermark.
final class StickerAnnotation extends Annotation {
  StickerAnnotation({
    required this.imagePath,
    required this.rect,
    this.rotation = 0,
    this.opacity = 1,
    String? id,
  }) : super(id: id ?? Annotation.newId());

  /// A PNG or JPEG on disk. A file rather than bytes for the same reason
  /// [CapturedMedia] is path-first: the platform is going to read it directly,
  /// and a sticker sheet should not transit the Dart heap.
  final String imagePath;

  /// Destination in the output frame, before [rotation].
  final CropRect rect;

  /// Clockwise, in radians, about the rect's centre.
  final double rotation;

  /// 0–1.
  final double opacity;

  StickerAnnotation copyWith({
    String? imagePath,
    CropRect? rect,
    double? rotation,
    double? opacity,
  }) => StickerAnnotation(
    id: id,
    imagePath: imagePath ?? this.imagePath,
    rect: rect ?? this.rect,
    rotation: rotation ?? this.rotation,
    opacity: opacity ?? this.opacity,
  );

  @override
  bool operator ==(Object other) =>
      other is StickerAnnotation &&
      other.id == id &&
      other.imagePath == imagePath &&
      other.rect == rect &&
      other.rotation == rotation &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(id, imagePath, rect, rotation, opacity);
}

/// A region blurred out — a face, a plate, a screen.
///
/// Unlike every other annotation this one *samples the source*, which is why it
/// cannot be flattened into the overlay layer and why the two platforms take
/// visibly different routes to it for video.
final class BlurAnnotation extends Annotation {
  BlurAnnotation({
    required this.rect,
    this.strength = 0.5,
    this.shape = BlurShape.rectangle,
    String? id,
  }) : super(id: id ?? Annotation.newId());

  final CropRect rect;

  /// 0–1, scaled to a radius against the region's size, so a small region is
  /// not obliterated by a radius meant for a large one.
  final double strength;

  final BlurShape shape;

  BlurAnnotation copyWith({
    CropRect? rect,
    double? strength,
    BlurShape? shape,
  }) => BlurAnnotation(
    id: id,
    rect: rect ?? this.rect,
    strength: strength ?? this.strength,
    shape: shape ?? this.shape,
  );

  @override
  bool operator ==(Object other) =>
      other is BlurAnnotation &&
      other.id == id &&
      other.rect == rect &&
      other.strength == strength &&
      other.shape == shape;

  @override
  int get hashCode => Object.hash(id, rect, strength, shape);
}

/// A freehand coloured line.
final class StrokeAnnotation extends Annotation {
  StrokeAnnotation({
    required this.points,
    this.colorArgb = 0xFFFFFFFF,
    this.widthFraction = 0.01,
    String? id,
  }) : super(id: id ?? Annotation.newId());

  /// Normalized, in draw order. A single point renders as a dot.
  final List<Offset> points;

  final int colorArgb;

  /// Fraction of the output's *shorter* edge, so a line keeps its weight
  /// whichever way the frame is turned.
  final double widthFraction;

  StrokeAnnotation copyWith({
    List<Offset>? points,
    int? colorArgb,
    double? widthFraction,
  }) => StrokeAnnotation(
    id: id,
    points: points ?? this.points,
    colorArgb: colorArgb ?? this.colorArgb,
    widthFraction: widthFraction ?? this.widthFraction,
  );

  /// Appends a point. What a drag gesture calls, once per sample.
  StrokeAnnotation extendedTo(Offset point) =>
      copyWith(points: [...points, point]);

  @override
  bool operator ==(Object other) =>
      other is StrokeAnnotation &&
      other.id == id &&
      listEquals(other.points, points) &&
      other.colorArgb == colorArgb &&
      other.widthFraction == widthFraction;

  @override
  int get hashCode =>
      Object.hash(id, Object.hashAll(points), colorArgb, widthFraction);
}

/// Convenience constructors that name what the caller is actually doing.
extension AnnotationFactories on Annotation {
  /// An emoji is a [TextAnnotation]; this exists so calling code reads right.
  static TextAnnotation emoji(
    String emoji, {
    required Offset center,
    double heightFraction = 0.12,
    double rotation = 0,
  }) => TextAnnotation(
    text: emoji,
    center: center,
    heightFraction: heightFraction,
    rotation: rotation,
  );
}

/// Helpers over an ordered annotation list. Pure, so a host can drive them from
/// whatever state management it uses.
extension AnnotationList on List<Annotation> {
  /// Replaces the annotation carrying [id], or returns the list unchanged.
  List<Annotation> replacing(Annotation value) => [
    for (final annotation in this)
      if (annotation.id == value.id) value else annotation,
  ];

  List<Annotation> removing(String id) => [
    for (final annotation in this)
      if (annotation.id != id) annotation,
  ];

  /// Moves an annotation to the front of the paint order.
  List<Annotation> bringingToFront(String id) => [
    ...removing(id),
    ...where((annotation) => annotation.id == id),
  ];

  Annotation? byId(String id) {
    for (final annotation in this) {
      if (annotation.id == id) return annotation;
    }
    return null;
  }

  /// True when nothing here samples the source, so the whole list can be
  /// flattened into a single overlay bitmap.
  bool get isFlattenable => !any((a) => a is BlurAnnotation);
}
