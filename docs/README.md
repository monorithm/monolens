# monolens

Headless camera capture and on-device media editing for Flutter -- crop, rotate, trim, blur, annotate.
No ffmpeg, no widgets.

A camera, an editor and a frame-accurate video trim that hand back textures and files instead of screens.
What the author sees is yours to build.

```bash
flutter pub add monolens
```

```dart
final session = MonolensCameraSession();
if (await session.initialize(CameraCaptureMode.photo) != CameraAccess.granted) {
  return showRationale();
}

final photo = await session.capturePhoto();

final edited = await MonolensEditor().applyImageEdit(
  photo.path,
  ImageEdit.none
      .copyWith(crop: CropRect.centered(aspectRatio: 1, sourceAspectRatio: photo.aspectRatio))
      .withAnnotation(TextAnnotation(text: 'Hello', center: const Offset(0.5, 0.8))),
);
```

## Start here

- [What is monolens?](00-start/00-what-is-monolens.md) -- what the package does, what headless means in practice, and why there is no ffmpeg.
- [Getting started](00-start/10-getting-started.md) -- from an empty project to a captured photo with a caption burned into it.

## What the shape buys you

**Headless.**
No widgets.
Capture hands back a texture id and the geometry to orient it; editing takes and returns file paths.
Nothing to theme, nothing to fight.

**No ffmpeg.**
`AVAssetExportSession` on iOS, Media3 `Transformer` on Android.
No bundled binary and no per-ABI size cost -- and cuts stay frame-accurate.

**Edits are values.**
An `ImageEdit` re-applies to the original every time, so stacking costs no generation loss and undo is just the previous value.

**One decode, one draw.**
Output size comes from metadata first, then the decoder is asked for only those pixels.
Cropping a 12 MP photo to 1080 px never materialises 12 MP.

## Guides

- [Capture](10-guides/00-capture.md) -- `CameraSession` holds a device and hands back a preview texture; `MediaPicker` is a one-shot gallery import.
  Both have test doubles.
- [Editing](10-guides/10-editing.md) -- probe a file, apply an image edit, run a video export, pull frames for a filmstrip.
- [Annotations](10-guides/20-annotations.md) -- text, stickers, blur and strokes, burned into a still or into every frame of a clip.
- [Building an editor](10-guides/30-building-an-editor.md) -- the recipe for an editing surface built on monolens, and the traps.
- [Testing](10-guides/40-testing.md) -- unit tests against the shipped fakes, integration tests against the real native code, and what each tier can answer.

## Reference

- [API reference](20-reference/00-api.md) -- the whole public surface of `package:monolens/monolens.dart`, grouped by what it is for.
- [Platform notes](20-reference/10-platforms.md) -- requirements, permissions, and the places the two platforms differ.
- [Architecture](20-reference/20-architecture.md) -- why the package is headless, how the native bridge is drawn, and what each boundary buys.

---

monolens is on [pub.dev](https://pub.dev/packages/monolens).
To work on the package itself rather than with it, see [CONTRIBUTING.md](https://github.com/monorithm/monolens/blob/main/CONTRIBUTING.md) -- an absolute link because that file lives outside `docs/` and so is not published to the site, where a relative one would dangle.
