# API map

What is in `package:monolens/monolens.dart`, grouped by what it is for.

**Signatures, parameters and per-member notes are in the dartdoc**, which is
generated from the source and cannot drift from it:
[pub.dev/documentation/monolens/latest](https://pub.dev/documentation/monolens/latest/).
This page is the thing an alphabetical class list cannot give you -- which types
belong together, and which job each group does.

Test doubles are in `package:monolens/testing.dart`, deliberately not exported
from the main library so they cannot reach production code by autocomplete.

## Capture

`CameraSession` · `MonolensCameraSession` · `CameraCaptureMode` ·
`CameraFacing` · `CameraFlash` · `CameraAccess` · `PreviewTexture` ·
`MediaPicker` · `SystemMediaPicker`

A held device with a lifecycle, and a one-shot picker that hands back a file
and forgets. Both are interfaces, so a composer runs against a fake.
`PreviewTexture` is data rather than a widget -- the id plus the geometry needed
to orient it.

→ [Capture a photo or a video](../10-recipes/00-capture-a-photo-or-video.md) ·
[Render the viewfinder](../10-recipes/10-render-the-viewfinder.md) ·
[Import from the gallery](../10-recipes/20-import-from-the-gallery.md)

## Media

`CapturedMedia` · `CapturedImage` · `CapturedVideo` · `MediaOrigin`

Sealed, path-first. Dimensions arrive already rotation-corrected, and `origin`
records whether it came from the camera, the gallery or an edit -- the three
have different trust properties.

## Editing

`MediaEditor` · `MonolensEditor` · `ImageEdit` · `VideoEdit` · `VideoTrim` ·
`CropRect` · `MonoRotation` · `MonoImageFormat` · `TrimJob` · `EditHistory` ·
`MediaEditException` · `TrimCancelled`

An edit is a **value** describing a result, not a sequence of operations against
a buffer, which is what makes it re-applicable to the untouched original and
undo almost free. `TrimCancelled` is a separate type from `MediaEditException`
because cancelling is not a failure.

→ [Edit a still](../10-recipes/30-edit-a-still.md) ·
[Trim a clip](../10-recipes/40-trim-a-clip.md) ·
[Wire undo and redo](../10-recipes/50-wire-undo-and-redo.md)

## Annotations

`Annotation` · `TextAnnotation` · `StickerAnnotation` · `BlurAnnotation` ·
`StrokeAnnotation` · `BlurShape` · `AnnotationList` · `AnnotationFactories`

Four primitives, all positioned against the **output** frame in normalized
coordinates. `AnnotationList` is a pure extension on `List<Annotation>`, so it
composes with any state management.

→ [Annotate a photo or a clip](../10-recipes/60-annotate-media.md)

## The platform seam

`MonolensPlatform`

Every call to native crosses it, and it is settable. That indirection is what
lets a composer be tested with no device and no native code.

→ [Test without a camera](../10-recipes/90-test-without-hardware.md)

## Things deliberately absent

| Not here | Why |
|---|---|
| Widgets | The package is headless. See [architecture](../20-concepts/90-architecture.md#why-headless). |
| A permissions API | Most apps already have one; two requesters produce two prompts. |
| ffmpeg | `AVAssetExportSession` and Media3 `Transformer` instead: no bundled binary, no per-ABI size cost, frame-accurate cuts. |
| A crop UI | Geometry helpers, yes. The surface is yours -- see [render the editing canvas](../10-recipes/70-render-the-editing-canvas.md). |
| Filters or LUTs | Nothing here samples the media except blur. |
