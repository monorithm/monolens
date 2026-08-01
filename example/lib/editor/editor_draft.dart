import 'package:monolens/monolens.dart';

/// Whatever is currently being edited, as one value.
///
/// A still and a clip carry different edits — [ImageEdit] has a flip and an
/// encode format, [VideoEdit] has a trim range and a mute flag — but almost
/// every control in the editor touches the parts they share. Wrapping both in
/// one sealed type means the canvas, the annotation tools and the undo stack
/// are written once instead of twice.
sealed class EditorDraft {
  const EditorDraft();

  List<Annotation> get annotations;
  CropRect get crop;
  MonoRotation get rotation;

  /// True when nothing has been changed, so "Done" can hand back the original
  /// instead of paying for an export.
  bool get isUntouched;

  bool get flipHorizontal;

  EditorDraft withAnnotations(List<Annotation> value);
  EditorDraft withCrop(CropRect value);
  EditorDraft rotatedClockwise();
  EditorDraft toggledFlip();

  /// True when the source is displayed on its side.
  bool get isQuarterTurned =>
      rotation == MonoRotation.quarterTurn ||
      rotation == MonoRotation.threeQuarterTurns;

  /// The aspect ratio of what the export will produce, which is the frame the
  /// author is placing annotations against.
  double outputAspectRatio(double sourceAspectRatio) {
    final cropped = sourceAspectRatio * (crop.width / crop.height);
    return isQuarterTurned ? 1 / cropped : cropped;
  }
}

final class ImageDraft extends EditorDraft {
  const ImageDraft(this.edit);

  final ImageEdit edit;

  @override
  List<Annotation> get annotations => edit.annotations;

  @override
  CropRect get crop => edit.crop;

  @override
  MonoRotation get rotation => edit.rotation;

  @override
  bool get flipHorizontal => edit.flipHorizontal;

  @override
  bool get isUntouched => edit.isIdentity;

  @override
  EditorDraft withAnnotations(List<Annotation> value) =>
      ImageDraft(edit.copyWith(annotations: value));

  @override
  EditorDraft withCrop(CropRect value) =>
      ImageDraft(edit.copyWith(crop: value));

  @override
  EditorDraft rotatedClockwise() => ImageDraft(edit.rotatedClockwise());

  @override
  EditorDraft toggledFlip() =>
      ImageDraft(edit.copyWith(flipHorizontal: !edit.flipHorizontal));
}

final class VideoDraft extends EditorDraft {
  const VideoDraft(this.edit, {required this.sourceDuration});

  final VideoEdit edit;
  final Duration sourceDuration;

  @override
  List<Annotation> get annotations => edit.annotations;

  @override
  CropRect get crop => edit.crop;

  @override
  MonoRotation get rotation => edit.rotation;

  @override
  bool get flipHorizontal => edit.flipHorizontal;

  @override
  bool get isUntouched => edit.isIdentityFor(sourceDuration);

  @override
  EditorDraft toggledFlip() =>
      VideoDraft(edit.toggledFlip(), sourceDuration: sourceDuration);

  @override
  EditorDraft withAnnotations(List<Annotation> value) => VideoDraft(
    edit.copyWith(annotations: value),
    sourceDuration: sourceDuration,
  );

  @override
  EditorDraft withCrop(CropRect value) =>
      VideoDraft(edit.copyWith(crop: value), sourceDuration: sourceDuration);

  @override
  EditorDraft rotatedClockwise() =>
      VideoDraft(edit.rotatedClockwise(), sourceDuration: sourceDuration);

  VideoDraft withTrim(VideoTrim trim) =>
      VideoDraft(edit.copyWith(trim: trim), sourceDuration: sourceDuration);

  VideoDraft toggledMute() =>
      VideoDraft(edit.toggledMute(), sourceDuration: sourceDuration);
}
