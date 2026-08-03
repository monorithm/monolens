# API reference

The whole public surface of `package:monolens/monolens.dart`, grouped by what it is for.
Signatures live in the dartdoc on each type; this is the map and the reasoning.

Test doubles are in `package:monolens/testing.dart` and are covered in [testing](../10-guides/40-testing.md).

## Capture

| Type | Role |
|---|---|
| `CameraSession` | Interface. A held device with a lifecycle. |
| `MonolensCameraSession` | The `camera`-backed implementation. |
| `CameraSessionFactory` | `CameraSession Function()`, so a host can inject a fake. |
| `PreviewTexture` | Texture id plus the geometry to orient it. |
| `CameraCaptureMode` | `photo`, `video`. Decides whether the mic is claimed. |
| `CameraFacing` | `back`, `front`. |
| `CameraFlash` | `off`, `auto`, `on`. |
| `CameraAccess` | `granted`, `denied`, `permanentlyDenied`, `unavailable`. |
| `MediaPicker` | Interface. One-shot gallery import. |
| `SystemMediaPicker` | The `image_picker`-backed implementation. |

See [capture](../10-guides/00-capture.md).

## Media

| Type | Role |
|---|---|
| `CapturedMedia` | Sealed. A file on disk with its dimensions. |
| `CapturedImage` | A still. |
| `CapturedVideo` | A clip; adds `duration`. |
| `MediaOrigin` | `camera`, `gallery`, `edit`. |
| `MediaInfo` | What `probe` returns. |

Media is path-first: a 25 MB clip should not sit in the Dart heap to be previewed.
`readBytes()` is for the one moment that needs the bytes, usually an upload.

## Editing

| Type | Role |
|---|---|
| `MediaEditor` | Interface. `probe`, `applyImageEdit`, `startTrim`, `filmstrip`. |
| `MonolensEditor` | The platform-backed implementation. |
| `ImageEdit` | A still's edit, as a value. |
| `VideoEdit` | A clip's edit: trim, crop, rotation, flip, mute, annotations. |
| `VideoTrim` | A range. Absolute start and end. |
| `CropRect` | A crop as fractions of the frame. |
| `MonoRotation` | Clockwise quarter turns. |
| `MonoImageFormat` | `jpeg`, `png`. |
| `TrimJob` | A running export: `id`, `progress`, `result`, `cancel()`. |
| `OutputPathBuilder` | `Future<String> Function(String extension)`. |
| `EditHistory<T>` | Undo/redo. A `ValueListenable`. |
| `MediaEditException` | A platform failure, with `code` and `message`. |
| `TrimCancelled` | Thrown when an export was cancelled. Not a failure. |

See [editing](../10-guides/10-editing.md).

## Annotations

| Type | Role |
|---|---|
| `Annotation` | Sealed. Carries a stable `id`. |
| `TextAnnotation` | Text and emoji. |
| `StickerAnnotation` | An image file in a rect. |
| `BlurAnnotation` | A blurred region. |
| `StrokeAnnotation` | A freehand line. |
| `BlurShape` | `rectangle`, `oval`. |
| `AnnotationFactories` | Extension. `emoji(...)`. |
| `AnnotationList` | Extension on `List<Annotation>`: `replacing`, `removing`, `byId`, `bringingToFront`, `isFlattenable`. |

See [annotations](../10-guides/20-annotations.md).

## The platform seam

Most hosts never touch these.
They are exported for two reasons: implementing `MonolensPlatform` for a fake, and the day the package is federated into per-platform pieces.

| Type | Role |
|---|---|
| `MonolensPlatform` | The interface every native call crosses. `instance` is settable. |
| `TrimProgress` | A `(jobId, value)` tick. |
| `ImageEditRequest`, `VideoTrimRequest` | The wire shapes. |
| `AnnotationSpec`, `AnnotationKind`, `BlurShapeSpec` | The flattened annotation wire form. |
| `NormalizedRect` | A crop on the wire. |

`MonolensPlatform` is an interface in front of the generated Pigeon class rather than a direct call into it, which is what lets tests run the whole editor -- job handles, progress, cancellation, error mapping -- with no channel and no device.

The generated `MonolensHostApi` is not exported.
Callers go through `MediaEditor`.

## Things deliberately absent

| Not here | Why |
|---|---|
| Widgets | The package is headless. See [architecture](./20-architecture.md#why-headless). |
| A permissions API | Most apps already have one; two requesters produce two prompts. |
| `path_provider` | The platform is asked for its own cache directory. |
| ffmpeg | Retired upstream; the platform encoders are the maintained path. |
| Audio recording | Monolens is lens-shaped. `record` is the right tool for an AAC file. |
| Filters and colour grading | Not asked for. The annotation pipeline is where they would go. |
