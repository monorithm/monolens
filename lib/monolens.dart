/// Headless camera capture and on-device media editing.
///
/// The package ships no widgets. Capture hands back a texture id and the
/// geometry to orient it; editing takes and returns files. What the author sees
/// is entirely the host's to build, in the host's own design system.
///
/// * **capture** — [CameraSession] (a live device with a preview texture) and
///   [MediaPicker] (gallery import), both interfaces with test doubles in
///   `package:monolens/testing.dart`.
/// * **edit** — [MediaEditor]: crop, rotate, flip and downscale stills; trim,
///   crop and mute clips natively (AVFoundation on iOS, Media3 Transformer on
///   Android). No ffmpeg, so no bundled binary and no per-ABI size cost.
/// * **annotate** — [TextAnnotation] (emoji included), [StickerAnnotation],
///   [BlurAnnotation] and [StrokeAnnotation], burned into a still or into every
///   frame of a clip, positioned against the *output* frame so they survive a
///   change of crop.
/// * **undo** — [EditHistory] over any edit value, with gesture coalescing.
///   Cheap because an edit is a value: there is nothing to invert, and blur has
///   no inverse.
library;

export 'src/capture/camera_contract.dart';
export 'src/capture/camera_session.dart';
export 'src/capture/media_picker.dart';
export 'src/edit/annotations.dart';
export 'src/edit/edit_history.dart';
export 'src/edit/edit_specs.dart';
export 'src/edit/media_editor.dart';
export 'src/media/captured_media.dart';
// MediaInfo is what probe() returns, and the two enums appear in ImageEdit. The
// request types are exported for anyone implementing MonolensPlatform; the
// generated Api classes are not — callers go through MediaEditor.
export 'src/messages.g.dart'
    show
        AnnotationKind,
        AnnotationSpec,
        BlurShapeSpec,
        ImageEditRequest,
        MediaInfo,
        MonoImageFormat,
        MonoRotation,
        NormalizedRect,
        VideoTrimRequest;
export 'src/platform/monolens_platform.dart'
    show MonolensPlatform, TrimProgress;
