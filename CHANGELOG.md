# Changelog

All notable changes to monolens are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

0.4.0 is the first version published to pub.dev. 0.1.0 through 0.3.0 were
development iterations, kept here because what changed in them is still the
history of this API.

## 0.4.0

Value equality, capture timing, and a reworked example.

### Added

- **Value equality** on `ImageEdit`, `VideoEdit` and every `Annotation`. These
  are value types and were compared by identity, which meant `EditHistory`'s
  no-op guard never fired for them: `copyWith` never returns the receiver, so a
  drag that emitted an unchanged sample still cost an undo press. Hosts can now
  compare edits directly too.

### Changed

- The example app is rebuilt as a reference editor rather than a control
  gallery. The three stacked rows of mode, tool and panel buttons collapse into
  one tool rail with a contextual tray; the media goes full-bleed on monokit's
  media register with chrome floating over it; and the editing glyphs -- crop,
  flip, blur, a pen nib -- are drawn rather than substituted from the nearest
  available icon. A blur region now previews as a real backdrop blur instead of
  a white wash, so what the author sees matches what the exporter burns in.
- The example's blur tool exposes `BlurAnnotation.strength`, which the API has
  always carried and the old UI never surfaced.
- Play/pause moved out of the example's trim tool and onto the media itself, so
  it is available while annotating rather than one tool away. Playback loops the
  trimmed range rather than the whole source, and drives the trim playhead.

### Fixed

- The example's tool rail held its own copy of the selected tool, so placing an
  annotation -- which moves the controller to the select tool so the new
  annotation can be dragged -- left the rail highlighting a tool that was no
  longer active. It derives from the controller now.
- Pinch and twist did nothing to a selected annotation in the example. The
  canvas carried a pan recognizer, which never reports a second finger, so a
  two-finger gesture was invisible to it. It uses a scale recognizer now, with
  a single pointer meaning drag.
- The example's corner resize handle did nothing. A `Stack` stops hit-testing
  at the topmost child that reports a hit and `RenderCustomPaint.hitTestSelf`
  returns true by default, so the glyph inside the handle swallowed the drag
  before it could reach the canvas detector underneath. Each handle carries its
  own recognizer now, on a 48pt target.
- Scaling a stroke in the example changed only its line weight, leaving the
  drawn shape the size it was.
- A capped recording left its ticker running after the cap fired, so the
  reported duration ran past the cap and a host that did not collect the take
  immediately leaked a periodic timer.
- `recordedDuration` accumulated the tick's nominal period rather than reading
  a clock, so it drifted from the real take under load — precisely where it is
  being read against a cap. It comes off a `Stopwatch` now and holds at the cap.
- `MonolensCameraSession.dispose` and `FakeCameraSession.dispose` were not
  idempotent, and disposing a `ChangeNotifier` twice throws. A host that
  disposes from both a lifecycle callback and `State.dispose` is doing something
  reasonable.
- The example's selection chrome ignored rotation: the outline stayed square
  around a turned annotation, the handles sat at the unturned corners, and the
  tappable region was a different shape from the drawn one. Outline, handles
  and hit test now all read from one oriented box.

## 0.3.0

Annotations, video crop, and undo.

### Added

- **Annotations**, burned into stills and into every frame of a clip:
  `TextAnnotation` (emoji included — an emoji is a glyph, so
  `AnnotationFactories.emoji` is a convenience over the same primitive),
  `StickerAnnotation`, `BlurAnnotation` (rectangle or oval), and
  `StrokeAnnotation` for coloured freehand lines. Geometry is normalized
  against the *output* frame, so an annotation survives a change of crop.
- **`VideoEdit`** — crop, rotation, horizontal flip, trim, mute and annotations
  for clips, so a clip is edited through the same declarative shape a still is.
  The flip mirrors the *rotated* frame on both platforms, matching stills.
- **`EditHistory`** — undo/redo over any edit value, with gesture coalescing so
  a drag is one step rather than four hundred. It implements `ValueListenable`,
  so it binds to any UI library. Undo is cheap precisely because an edit is a
  value: there is nothing to invert, and blur has no inverse.
- Pixel-level integration tests for strokes, blur, text, stickers (placement,
  the stretch-to-rect semantic, and opacity) and annotations-under-crop, plus a
  video flip test — all on both platforms. The sticker tests run against a
  generated magenta fixture, since a sticker needs a real file on disk.

### Fixed

- Sticker opacity was ignored on iOS. `UIImage.draw(in:)` is defined as
  `draw(in:blendMode:alpha:)` with alpha 1, so it overwrote the context alpha
  and a translucent sticker exported fully opaque. Caught by the new test.

### Changed — breaking

- `MediaEditor.startTrim` takes a `VideoEdit` rather than a `VideoTrim`.
- `VideoTrim` is now purely a range; `muteAudio` moved to `VideoEdit`.
- `ImageEdit` gained `annotations`, and `isIdentity` accounts for them.

### Native

Regional video blur on Android is a custom Media3 `GlEffect`. Media3's stock
`GaussianBlur` blurs the whole frame with no mask, and no chain of stock effects
can recover the sharp part, because an overlay draws onto a frame and can never
sample it. The mask is rasterized once by the same Canvas code the still path
uses and uploaded as a texture — rather than passed as array uniforms, which
GLES reports under the name `uName[0]` and which therefore fail to bind by the
name written in the shader source.

Media3's `ExportException` reports only the top of its cause chain, which for
anything in the frame pipeline is the useless "Video frame processing error".
Failures now carry the flattened chain instead.

## 0.2.0

Headless, and a good deal faster.

### Changed — breaking

- **The package ships no widgets.** `MonolensCameraView`, `MonolensCropView` and
  `MonolensTrimView`, with their controllers and style objects, are gone.
  Monolens is an API; the UI is the host's.
- `CameraSession.buildPreview(BuildContext)` is replaced by
  `CameraSession.preview`, a `PreviewTexture` carrying the texture id, the
  stream size, the sensor orientation and the active lens. Render it with
  `Texture(textureId: …)` — see the README for the few lines involved.
- `ImageEditRequest.crop` is a `NormalizedRect` rather than a `PixelRect`, which
  is now removed along with `CropRect.resolve`. The platform resolves the
  fractions, so `applyImageEdit` no longer probes the source first: an edit is
  one channel call instead of two.
- A flip now mirrors the *rotated* frame on both platforms. iOS previously
  mirrored before rotating and Android after, so `rotation + flipHorizontal`
  combinations disagreed between them. Covered now by pixel-level tests.

### Performance

- Image edits derive their output size from bounds metadata, then decode only
  that many pixels (`kCGImageSourceThumbnailMaxPixelSize` / `inSampleSize`), and
  fold crop, rotate, mirror and scale into one composite pass. Previously this
  was a full-resolution decode followed by up to three full-size redraws.
- Encoding on iOS goes straight to disk through ImageIO, with no `UIImage` round
  trip and no intermediate `Data`.
- Filmstrips: iOS batches every timestamp through
  `generateCGImagesAsynchronously` rather than re-seeking per frame; Android
  decodes directly to thumbnail size via `getScaledFrameAtTime` where available.

### Added

- Pixel-level integration tests that assert *which* region a crop kept and which
  way up it came out, on both platforms — dimensions alone cannot catch a
  transform composed in the wrong order.
- Camera integration tests covering preview, still capture and the recording
  auto-stop, which run wherever a camera exists and skip where one does not.

## 0.1.0

First cut. Capture and on-device editing behind interfaces, with real native
exporters on both platforms.

### Added

- **Capture.** `CameraSession` (a live viewfinder with lens flip, flash cycle
  and a recording cap enforced at the shutter) and `MediaPicker` (gallery
  import), both interfaces with a `camera`/`image_picker` implementation and a
  test double in `package:monolens/testing.dart`.
- **Editing.** `MediaEditor` — `applyImageEdit` for crop/rotate/flip/downscale,
  `startTrim` for a cancellable video export with progress, `filmstrip` for
  scrubbing frames, and `probe` for dimensions and duration.
- **Native exporters.** Video trim runs on `AVAssetExportSession` (iOS) and
  `androidx.media3.transformer.Transformer` (Android). No ffmpeg, no bundled
  native binary, no per-ABI size cost. Cuts are frame-accurate: both sides force
  a re-encode rather than snapping the in-point back to a keyframe.
- **Widgets.** `MonolensCameraView`, `MonolensCropView` and `MonolensTrimView`,
  built on `package:flutter/widgets.dart` only — no Material dependency, so they
  drop into a `WidgetsApp` host. Each takes a style object, and the camera view
  takes a `controlsBuilder` for hosts that supply their own chrome.
- **Typed bridge.** All platform traffic goes through Pigeon
  (`pigeons/monolens_api.dart`), with generated Dart, Swift and Kotlin committed.

### Notes

- Value types are declarative, not command logs: an `ImageEdit` re-applies to
  the original, so stacking edits costs no generation loss and "revert" is just
  dropping back to `ImageEdit.none`.
- `CropRect` is normalized, resolving to pixels only at export, so a crop
  survives rotation and preview resizing.
- The plugin carries no `path_provider` dependency — it asks the platform for
  its own cache directory.
