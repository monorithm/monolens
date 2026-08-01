---
title: "Getting started"
description: "From an empty project to a captured photo with a caption burned into it."
---

Monolens is a headless Flutter plugin: it captures media and edits it, and it ships no widgets at all.
That means there is nothing to theme and nothing to fight, and it means you draw the viewfinder and the editing surface yourself.
This page gets you from an empty project to a captured photo with a caption burned into it.

## Install

```bash
flutter pub add monolens --hosted-url <private-pub-server>
```

Monolens needs iOS 13 and Android minSdk 24; see [platforms](/monolens/reference/platforms/) for what those floors buy and cost.

## Permissions

Declare the usage strings each platform requires.
Monolens never asks for a permission itself -- see [capture](/monolens/guides/capture/#permissions) for why -- but the OS still requires the declarations.

iOS `Info.plist`:

```xml
<key>NSCameraUsageDescription</key><string>Take photos and record clips.</string>
<key>NSMicrophoneUsageDescription</key><string>Record sound with your clips.</string>
<key>NSPhotoLibraryUsageDescription</key><string>Import photos and videos.</string>
```

Android `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

## Capture a photo

```dart
final session = MonolensCameraSession();

final access = await session.initialize(CameraCaptureMode.photo);
if (access != CameraAccess.granted) {
  return showRationale(access);
}

final photo = await session.capturePhoto();
```

`photo` is a `CapturedImage`: a path, dimensions, a byte size and a content type.
Media is path-first throughout -- nothing large sits in the Dart heap until you ask for it with `readBytes()`.

To show the viewfinder, render the texture the session hands back:

```dart
final preview = session.preview;
if (preview == null) return const SizedBox.shrink();

return AspectRatio(
  aspectRatio: preview.aspectRatio,
  child: Texture(textureId: preview.textureId),
);
```

On Android you also apply `preview.sensorOrientation`; the full recipe is in [capture](/monolens/guides/capture/#rendering-the-viewfinder).

## Apply an edit

An edit is a *value* describing the result, not a sequence of operations.

```dart
final editor = MonolensEditor();

final edited = await editor.applyImageEdit(
  photo.path,
  ImageEdit(
    crop: const CropRect(left: 0.1, top: 0.1, width: 0.8, height: 0.8),
    rotation: MonoRotation.quarterTurn,
    annotations: [
      TextAnnotation(
        text: 'Hello',
        center: const Offset(0.5, 0.85),
        backgroundArgb: 0x99000000,
      ),
    ],
  ),
);
```

The source file is never modified, so the same edit can be re-applied with different parameters and lose nothing to re-compression.
Order is fixed and documented in [editing](/monolens/guides/editing/#the-order-of-operations).

## Trim a clip

A video export is slow enough to need a progress bar and a cancel button, so it returns a handle rather than a bare future.

```dart
final job = editor.startTrim(
  clip.path,
  VideoEdit(
    trim: const VideoTrim(
      start: Duration(seconds: 1),
      end: Duration(seconds: 4),
    ),
    muteAudio: true,
  ),
);

job.progress.listen((value) => setState(() => _progress = value));

try {
  final trimmed = await job.result;
} on TrimCancelled {
  // job.cancel() was called. Not a failure.
} on MediaEditException catch (error) {
  showBanner(error.message);
}
```

## Run the example

The example app is a complete editor -- direct manipulation, crop handles, a filmstrip scrubber, annotation tools and undo -- built entirely on the public API.
It is the reference implementation for [building an editor](/monolens/guides/building-an-editor/).

```bash
cd example && flutter run
```

## Where to go next

- Building a viewfinder or importing from the gallery: [capture](/monolens/guides/capture/).
- Cropping, trimming, exporting, undo: [editing](/monolens/guides/editing/).
- Text, emoji, stickers, blur and strokes: [annotations](/monolens/guides/annotations/).
- Writing the UI around it: [building an editor](/monolens/guides/building-an-editor/).
- Testing your composer without a device: [testing](/monolens/guides/testing/).
- Why any of it is shaped this way: [architecture](/monolens/reference/architecture/).
