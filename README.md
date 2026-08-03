# Monolens

Monolens is headless camera capture and on-device media editing for Flutter.

**Capture and edit.** A camera and a gallery import; crop, rotate and downscale;
blur regions; text, emoji, stickers and coloured lines burned in; mute; and a
frame-accurate video trim. With undo.

**Headless.** The package ships no widgets. Capture hands back a texture id and
the geometry to orient it; editing takes and returns files. What the author sees
is entirely yours to build, in your own design system.

**No ffmpeg.** Trimming goes through `AVAssetExportSession` on iOS and
`androidx.media3.transformer.Transformer` on Android — no bundled native binary
and no per-ABI size cost. (`ffmpeg_kit` is retired; this is the maintained path.)

**One decode, one draw.** An image edit computes its output size from metadata
first, then decodes only as many pixels as that output needs. Cropping a 12 MP
photo to a 1080 px square never materialises the 12 MP bitmap.

## Install

```bash
flutter pub add monolens
```

Declare the usage strings the platforms require. iOS `Info.plist`:

```xml
<key>NSCameraUsageDescription</key><string>…</string>
<key>NSMicrophoneUsageDescription</key><string>…</string>
<key>NSPhotoLibraryUsageDescription</key><string>…</string>
```

Android `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

Monolens deliberately does **not** depend on a permissions plugin. Most apps
already have one, and two competing requesters produce two prompts. The session
reports what it found (`CameraAccess`) and you decide what to show.

## Capture

```dart
final session = MonolensCameraSession();

final access = await session.initialize(CameraCaptureMode.video);
if (access != CameraAccess.granted) return showRationale(access);

await session.startVideoRecording(maxDuration: const Duration(seconds: 15));
```

The cap is enforced at the shutter: the session clears `isRecording` on its own
when it is reached, and you call `stopVideoRecording()` to collect the file. A
capped composer therefore never has to reject its own take.

```dart
session.isRecording.addListener(() {
  if (!session.isRecording.value) collect();   // fires on tap *or* on the cap
});
```

### Rendering the viewfinder

`session.preview` is data, not a widget:

```dart
// Test for a null preview, not a falsy id — zero is a valid texture id, and
// an iPhone reports exactly that for its first session.
final preview = session.preview;
if (preview == null) return const SizedBox.shrink();

Widget texture = Texture(textureId: preview.textureId);

// iOS delivers frames already oriented; Android streams them in sensor
// orientation, so rotate by that much (folding in device orientation if you
// support more than portrait).
if (Platform.isAndroid && preview.sensorOrientation % 360 != 0) {
  texture = RotatedBox(
    quarterTurns: (preview.sensorOrientation ~/ 90) % 4,
    child: texture,
  );
}

return AspectRatio(aspectRatio: preview.aspectRatio, child: texture);
```

Mirroring the front lens is a presentation choice, so it lives in your code too.
See `example/lib/capture_page.dart` for a complete viewfinder built this way.

Gallery import is a separate, stateless seam:

```dart
final picker = SystemMediaPicker();
final image = await picker.pickImage();   // null if cancelled
final video = await picker.pickVideo();   // duration is populated on return
```

## Edit

An edit is a **declaration**, not a command log. `ImageEdit` re-applies to the
original every time, so stacking edits costs no generation loss and "revert" is
just dropping back to `ImageEdit.none`.

```dart
final editor = MonolensEditor();

final cropped = await editor.applyImageEdit(
  image.path,
  const ImageEdit(
    crop: CropRect(left: 0.25, top: 0, width: 0.5, height: 1),
    rotation: MonoRotation.quarterTurn,
    maxDimension: 2048,
  ),
);
```

Order is fixed: **crop → rotate → flip → downscale → encode**, and the flip
mirrors the *rotated* frame, so a rotate-and-flip lands identically on both
platforms. `CropRect` is normalized (fractions of the frame) all the way to the
platform, which is what keeps an edit to a single channel call — nothing has to
probe the source first — and keeps the two sides from disagreeing about what the
source's dimensions are.

Trimming returns a handle, because an export is the one operation here slow
enough to need a progress bar and a cancel button:

```dart
final job = editor.startTrim(
  video.path,
  const VideoEdit(
    trim: VideoTrim(
      start: Duration(milliseconds: 1500),
      end: Duration(milliseconds: 3500),
    ),
  ),
);

job.progress.listen((value) => setState(() => _progress = value));

try {
  final trimmed = await job.result;
} on TrimCancelled {
  // job.cancel() was called — not a failure, nothing to report.
} on MediaEditException catch (error) {
  showBanner(error.message);
}
```

Cuts are frame-accurate. Both platforms force a re-encode rather than snapping
the in-point back to the nearest keyframe, which would slide a hand-placed
handle backwards by up to a GOP.

Skip the export when there is nothing to cut:

```dart
if (edit.isIdentityFor(video.duration)) return original;   // no encode, no loss
```

## Annotations

The same four primitives apply to a still and to every frame of a clip:

```dart
final edit = ImageEdit.none
    .withAnnotation(TextAnnotation(text: 'Hello', center: const Offset(0.5, 0.8)))
    .withAnnotation(AnnotationFactories.emoji('🎉', center: const Offset(0.2, 0.2)))
    .withAnnotation(StickerAnnotation(imagePath: badge, rect: someRect))
    .withAnnotation(BlurAnnotation(rect: faceRect, shape: BlurShape.oval))
    .withAnnotation(StrokeAnnotation(points: dragPoints, colorArgb: 0xFFE5484D));
```

An emoji is text — a glyph the platform already shapes — so there is no emoji
asset table to keep current. A sticker is any PNG or JPEG on disk, drawn to fill
its rect rather than fitted inside it, so a non-square rect stretches it.

Geometry is normalized against the **output** frame: the frame after the crop
and rotation, which is the frame the author was looking at. Change the crop and
the annotations stay where they were put.

Blur is the one primitive that samples the media, so it is applied beneath the
others — a caption across a blurred face stays legible. It also cannot be
flattened into the overlay layer, which is why it takes a different route per
platform: Core Image on iOS, a per-region box blur for Android stills, and a
custom masked-blur `GlEffect` for Android video.

## Undo

```dart
final history = EditHistory(ImageEdit.none);

history.push(edit.rotatedClockwise());
history.push(next, coalesceKey: 'drag');   // a whole gesture is one step
history.commit();                          // gesture ended

if (history.canUndo) history.undo();
```

Undo is cheap because an edit is a value: there is nothing to invert and nothing
to replay. `EditHistory` implements `ValueListenable`, so it binds to any UI
library — and it is generic, so the same control drives a still and a clip.

`filmstrip` returns evenly spaced frames as JPEG bytes, for a scrubber:

```dart
final frames = await editor.filmstrip(
  video.path,
  duration: video.duration,
  frames: 10,
);
```

`CropRect` and `VideoTrim` carry the fiddly geometry so your UI does not have
to: `CropRect.centered` fits a target ratio inside a source, and
`VideoTrim.clamped` enforces a minimum and a maximum while holding whichever
handle you are not dragging.

## Testing

```dart
import 'package:monolens/testing.dart';

final platform = FakeMonolensPlatform();
platform.install();
addTearDown(FakeMonolensPlatform.uninstall);

final session = FakeCameraSession();
// …drive your composer, then:
session.tick(const Duration(seconds: 15));   // fires the auto-stop at the cap
```

`FakeMonolensPlatform` records the *requests* — the normalized crop, the trim
range in milliseconds — so a test asserts on intent rather than on bytes it
would have to decode.

## Architecture

The shape below is the summary. User documentation is at
[monorithm.github.io/opensource/monolens/latest](https://monorithm.github.io/opensource/monolens/latest/),
written in [`docs/`](docs/) and published by [the site](https://github.com/monorithm/monorithm.github.io):
[getting started](https://monorithm.github.io/opensource/monolens/latest/00-start/00-tutorial/),
recipes for [capture](https://monorithm.github.io/opensource/monolens/latest/10-recipes/00-capture-a-photo-or-video/),
[editing](https://monorithm.github.io/opensource/monolens/latest/10-recipes/30-edit-a-still/) and
[annotations](https://monorithm.github.io/opensource/monolens/latest/10-recipes/60-annotate-media/), a recipe
for
[building an editor](https://monorithm.github.io/opensource/monolens/latest/10-recipes/70-render-the-editing-canvas/),
the [API reference](https://monorithm.github.io/opensource/monolens/latest/30-reference/00-api-map/),
[platform notes](https://monorithm.github.io/opensource/monolens/latest/30-reference/10-platforms/),
[testing](https://monorithm.github.io/opensource/monolens/latest/10-recipes/90-test-without-hardware/), and the
[architecture](https://monorithm.github.io/opensource/monolens/latest/20-concepts/90-architecture/)
behind all of it. Contributor documentation is in
[`docs/`](https://github.com/monorithm/monolens/tree/main/docs).

```
lib/
  monolens.dart              public surface — no widgets
  testing.dart               test doubles (never imported by lib/src)
  src/
    capture/                 CameraSession, MediaPicker + implementations
    edit/                    ImageEdit, VideoEdit, Annotation, EditHistory,
                             MediaEditor, TrimJob
    media/                   CapturedImage / CapturedVideo
    platform/                MonolensPlatform — the mockable seam over Pigeon
    messages.g.dart          generated
pigeons/monolens_api.dart    the bridge's single source of truth
ios/…/ImageTransformer.swift ImageIO + Core Graphics
ios/…/VideoExporter.swift    AVAssetExportSession
android/…/ImageTransformer.kt  BitmapFactory + Matrix
android/…/VideoExporter.kt     Media3 Transformer
```

`MonolensPlatform` is an interface rather than the generated Pigeon class
directly, so tests run against an in-memory fake — and so the plugin can be
federated into per-platform packages later without touching callers.

Media is **path-first**, not bytes-first: a 25 MB clip should not be resident in
the Dart heap just to be previewed, and every native op reads and writes files
anyway. Call `readBytes()` at the point of upload.

Files land in the app's cache directory — asked of the platform rather than
pulled in via `path_provider` — which the OS may evict, so copy anything that
has to outlive the session.

### Performance notes

- **Images.** Output dimensions are derived from bounds metadata, then the
  decoder is asked for only that many pixels (`kCGImageSourceThumbnailMaxPixelSize`
  / `inSampleSize`). Crop, rotate, mirror and scale then happen in a *single*
  composite pass — `CGImage.cropping` is a view rather than a copy, and Android's
  `createBitmap` takes a sub-rectangle and a matrix together. Encoding goes
  straight to disk through ImageIO with no intermediate `Data`.
- **Filmstrips.** iOS batches every requested time through
  `generateCGImagesAsynchronously`, so AVFoundation walks the file once instead
  of re-seeking per frame. Android decodes straight to thumbnail size with
  `getScaledFrameAtTime` where the API level allows.
- **Threading.** Every operation runs off the platform thread, so decoding a
  12 MP still never stalls the viewfinder the author is looking at.

### Regenerating the bridge

```bash
dart run pigeon --input pigeons/monolens_api.dart
```

Generated Dart, Swift and Kotlin are committed, so consumers never need pigeon.
CI fails if they drift from the schema.

## Running the tests

Unit tests need nothing:

```bash
flutter test
```

The integration suite exercises the real native code on a device, simulator or
emulator. Generate the fixtures first — a 5 s clip with a keyframe every second,
so a mid-GOP cut is genuinely tested, plus a quartered still whose colours prove
which region a crop kept and which way up it came out:

```bash
swift tool/make_fixture.swift
```

```bash
cd example && flutter test integration_test
```

The camera tests skip where no camera exists (an iOS simulator); they run on an
Android emulator's virtual scene and on real hardware. Opening a camera on an
emulator can take minutes, which is why that group carries a long timeout.
