import 'package:flutter/foundation.dart' show listEquals;

import '../messages.g.dart';
import 'annotations.dart';

/// A crop expressed as fractions of the source frame rather than pixels.
///
/// Normalized all the way down to the platform: a crop UI works in layout
/// space, whose size changes with rotation, insets and screen size, so a pixel
/// rect captured against one preview size is wrong at the next. Fractions
/// survive that, and letting the native side resolve them removes a probe round
/// trip per edit along with any chance of the two sides disagreeing about the
/// source's dimensions.
class CropRect {
  const CropRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// The whole frame — the identity crop.
  const CropRect.full() : left = 0, top = 0, width = 1, height = 1;

  /// The largest centred rect of [aspectRatio] (width / height) that fits a
  /// source of [sourceAspectRatio]. How the aspect-ratio chips seed a crop.
  factory CropRect.centered({
    required double aspectRatio,
    required double sourceAspectRatio,
  }) {
    // Wider target than source: full width, inset vertically. Else the reverse.
    if (aspectRatio >= sourceAspectRatio) {
      final height = sourceAspectRatio / aspectRatio;
      return CropRect(left: 0, top: (1 - height) / 2, width: 1, height: height);
    }
    final width = aspectRatio / sourceAspectRatio;
    return CropRect(left: (1 - width) / 2, top: 0, width: width, height: 1);
  }

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  bool get isFull => left == 0 && top == 0 && width == 1 && height == 1;

  /// Pins the rect inside the unit square without changing its size, then
  /// clamps the size if it could not fit. What a drag gesture runs through.
  CropRect clampedToBounds() {
    final w = width.clamp(0.0, 1.0);
    final h = height.clamp(0.0, 1.0);
    return CropRect(
      left: left.clamp(0.0, 1.0 - w),
      top: top.clamp(0.0, 1.0 - h),
      width: w,
      height: h,
    );
  }

  CropRect copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
  }) => CropRect(
    left: left ?? this.left,
    top: top ?? this.top,
    width: width ?? this.width,
    height: height ?? this.height,
  );

  /// The wire form. Clamped here so the platform never has to reason about a
  /// rect that runs past the frame.
  NormalizedRect toRequest() {
    final rect = clampedToBounds();
    return NormalizedRect(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'CropRect($left, $top, ${width}x$height)';
}

/// Everything the still editor can do in one export: crop, then rotate, then
/// flip, then downscale, then encode. Declarative rather than a command log, so
/// an edit is re-applicable to the original — no generation loss from stacking
/// exports, and "revert" is just dropping back to [ImageEdit.none].
class ImageEdit {
  const ImageEdit({
    this.crop = const CropRect.full(),
    this.rotation = MonoRotation.none,
    this.flipHorizontal = false,
    this.annotations = const [],
    this.format = MonoImageFormat.jpeg,
    this.quality = 90,
    this.maxDimension,
  });

  /// No-op edit.
  static const ImageEdit none = ImageEdit();

  final CropRect crop;
  final MonoRotation rotation;
  final bool flipHorizontal;

  /// Painted over the result, back to front, positioned against the *output*
  /// frame — the one the author was looking at.
  final List<Annotation> annotations;

  final MonoImageFormat format;

  /// 1–100, JPEG only.
  final int quality;

  /// Caps the longest edge after crop and rotation. Null keeps full size.
  final int? maxDimension;

  /// True when applying this would only re-encode. Lets a caller skip the
  /// native round trip and keep the original file.
  bool get isIdentity =>
      crop.isFull &&
      rotation == MonoRotation.none &&
      !flipHorizontal &&
      annotations.isEmpty;

  /// Adds a quarter turn clockwise. What the rotate button calls.
  ImageEdit rotatedClockwise() {
    const order = [
      MonoRotation.none,
      MonoRotation.quarterTurn,
      MonoRotation.halfTurn,
      MonoRotation.threeQuarterTurns,
    ];
    return copyWith(rotation: order[(order.indexOf(rotation) + 1) % 4]);
  }

  ImageEdit copyWith({
    CropRect? crop,
    MonoRotation? rotation,
    bool? flipHorizontal,
    List<Annotation>? annotations,
    MonoImageFormat? format,
    int? quality,
    int? maxDimension,
  }) => ImageEdit(
    crop: crop ?? this.crop,
    rotation: rotation ?? this.rotation,
    flipHorizontal: flipHorizontal ?? this.flipHorizontal,
    annotations: annotations ?? this.annotations,
    format: format ?? this.format,
    quality: quality ?? this.quality,
    maxDimension: maxDimension ?? this.maxDimension,
  );

  ImageEdit withAnnotation(Annotation annotation) =>
      copyWith(annotations: [...annotations, annotation]);

  ImageEdit withoutAnnotation(String id) =>
      copyWith(annotations: annotations.removing(id));

  /// Replaces the annotation carrying the same id — what a drag calls.
  ImageEdit updatingAnnotation(Annotation annotation) =>
      copyWith(annotations: annotations.replacing(annotation));

  @override
  bool operator ==(Object other) =>
      other is ImageEdit &&
      other.crop == crop &&
      other.rotation == rotation &&
      other.flipHorizontal == flipHorizontal &&
      listEquals(other.annotations, annotations) &&
      other.format == format &&
      other.quality == quality &&
      other.maxDimension == maxDimension;

  @override
  int get hashCode => Object.hash(
    crop,
    rotation,
    flipHorizontal,
    Object.hashAll(annotations),
    format,
    quality,
    maxDimension,
  );
}

/// A trim range over a clip.
///
/// [start]/[end] are absolute offsets into the source, not a start plus a
/// length, because both handles are dragged independently in the UI and a
/// length would have to be recomputed on every frame of a left-handle drag.
class VideoTrim {
  const VideoTrim({required this.start, required this.end});

  /// The whole clip.
  VideoTrim.full(Duration duration) : start = Duration.zero, end = duration;

  final Duration start;
  final Duration end;

  Duration get duration => end - start;

  /// True when this keeps the whole clip.
  bool isIdentityFor(Duration sourceDuration) =>
      start == Duration.zero && end >= sourceDuration;

  /// Clamps to the source and enforces [minimum], holding whichever handle the
  /// caller did not just move. Runs on every drag frame.
  VideoTrim clamped(
    Duration sourceDuration, {
    Duration minimum = const Duration(milliseconds: 500),
    Duration? maximum,
    bool anchorStart = true,
  }) {
    var s = start < Duration.zero ? Duration.zero : start;
    var e = end > sourceDuration ? sourceDuration : end;
    if (e - s < minimum) {
      if (anchorStart) {
        e = s + minimum;
        if (e > sourceDuration) {
          e = sourceDuration;
          s = e - minimum;
        }
      } else {
        s = e - minimum;
        if (s < Duration.zero) {
          s = Duration.zero;
          e = minimum;
        }
      }
    }
    if (maximum != null && e - s > maximum) {
      if (anchorStart) {
        e = s + maximum;
      } else {
        s = e - maximum;
      }
    }
    return VideoTrim(
      start: s < Duration.zero ? Duration.zero : s,
      end: e > sourceDuration ? sourceDuration : e,
    );
  }

  VideoTrim copyWith({Duration? start, Duration? end}) =>
      VideoTrim(start: start ?? this.start, end: end ?? this.end);

  @override
  bool operator ==(Object other) =>
      other is VideoTrim && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'VideoTrim($start–$end)';
}

/// Everything the clip editor can do in one export: trim to a range, crop,
/// rotate, drop the audio, and burn in annotations.
///
/// Declarative for the same reason [ImageEdit] is — and it matters more here,
/// because a video export is expensive enough that re-deriving from the
/// original beats stacking encodes.
class VideoEdit {
  const VideoEdit({
    required this.trim,
    this.crop = const CropRect.full(),
    this.rotation = MonoRotation.none,
    this.flipHorizontal = false,
    this.muteAudio = false,
    this.annotations = const [],
  });

  /// The whole clip, untouched.
  VideoEdit.full(Duration duration) : this(trim: VideoTrim.full(duration));

  final VideoTrim trim;
  final CropRect crop;
  final MonoRotation rotation;

  /// Mirrors the *rotated* frame, exactly as [ImageEdit.flipHorizontal] does.
  final bool flipHorizontal;

  /// Drops the audio track rather than exporting a silent one — smaller file,
  /// and what a "mute" toggle means.
  final bool muteAudio;

  /// Burned into every frame, back to front, against the output frame.
  final List<Annotation> annotations;

  Duration get duration => trim.duration;

  /// True when nothing would change, so the caller can hand back the original
  /// instead of paying for an encode.
  bool isIdentityFor(Duration sourceDuration) =>
      trim.isIdentityFor(sourceDuration) &&
      crop.isFull &&
      rotation == MonoRotation.none &&
      !flipHorizontal &&
      !muteAudio &&
      annotations.isEmpty;

  VideoEdit copyWith({
    VideoTrim? trim,
    CropRect? crop,
    MonoRotation? rotation,
    bool? flipHorizontal,
    bool? muteAudio,
    List<Annotation>? annotations,
  }) => VideoEdit(
    trim: trim ?? this.trim,
    crop: crop ?? this.crop,
    rotation: rotation ?? this.rotation,
    flipHorizontal: flipHorizontal ?? this.flipHorizontal,
    muteAudio: muteAudio ?? this.muteAudio,
    annotations: annotations ?? this.annotations,
  );

  VideoEdit withAnnotation(Annotation annotation) =>
      copyWith(annotations: [...annotations, annotation]);

  VideoEdit withoutAnnotation(String id) =>
      copyWith(annotations: annotations.removing(id));

  VideoEdit updatingAnnotation(Annotation annotation) =>
      copyWith(annotations: annotations.replacing(annotation));

  VideoEdit toggledMute() => copyWith(muteAudio: !muteAudio);

  VideoEdit toggledFlip() => copyWith(flipHorizontal: !flipHorizontal);

  VideoEdit rotatedClockwise() {
    const order = [
      MonoRotation.none,
      MonoRotation.quarterTurn,
      MonoRotation.halfTurn,
      MonoRotation.threeQuarterTurns,
    ];
    return copyWith(rotation: order[(order.indexOf(rotation) + 1) % 4]);
  }

  @override
  bool operator ==(Object other) =>
      other is VideoEdit &&
      other.trim == trim &&
      other.crop == crop &&
      other.rotation == rotation &&
      other.flipHorizontal == flipHorizontal &&
      other.muteAudio == muteAudio &&
      listEquals(other.annotations, annotations);

  @override
  int get hashCode => Object.hash(
    trim,
    crop,
    rotation,
    flipHorizontal,
    muteAudio,
    Object.hashAll(annotations),
  );
}
