# Platform notes

## Requirements

| | Floor | Why it matters |
|---|---|---|
| iOS | 13.0 | Below `UTType`, so the encoder uses raw UTI strings. |
| Android | minSdk 24 | `getScaledFrameAtTime` is guarded to API 27. |
| Flutter | 3.35 | |
| Dart | 3.12 | Sealed classes and pattern matching are used throughout. |

Android compiles against SDK 36 with Java 17 and Media3 1.10.1.

## The engines

| Concern | iOS | Android |
|---|---|---|
| Probe | `CGImageSource` / `AVURLAsset` | `BitmapFactory` bounds / `MediaMetadataRetriever` |
| Image decode | `CGImageSourceCreateThumbnailAtIndex` | `BitmapFactory` with `inSampleSize` |
| Image transform | Core Graphics, one composite pass | `Bitmap.createBitmap` with a sub-rect and matrix |
| Image encode | ImageIO, straight to disk | `Bitmap.compress` |
| Video trim | `AVAssetExportSession` | Media3 `Transformer` |
| Video crop / rotate | Core Image composition | `Crop` + `ScaleAndRotateTransformation` |
| Video overlay | Composited in the Core Image pass | `OverlayEffect` + `BitmapOverlay` |
| Still blur | Core Image `blendWithMask` | Per-region separable box blur |
| Video blur | Core Image, per frame | Custom masked-blur `GlEffect` |
| Filmstrip | Batched `generateCGImagesAsynchronously` | `getScaledFrameAtTime` per frame |

No ffmpeg on either side.
`ffmpeg_kit` is retired, and the platform encoders mean no bundled native binary, no per-ABI size cost, and work that lands on hardware.

## Divergences that reach the API

**Preview rotation.** iOS delivers frames already oriented; Android streams them in sensor orientation.
The host applies `PreviewTexture.sensorOrientation` -- see [capture](../10-guides/00-capture.md#rendering-the-viewfinder).

**Texture ids.**
Zero is valid.
An iPhone reports it for its first session, so test `preview == null` rather than a falsy id.

**Camera cold start.**
Sub-second on a handset.
On an Android emulator's virtual scene it can exceed two minutes, which is why the camera tests carry a long timeout.

## Divergences that do not

These are handled internally and are listed so nobody re-discovers them the hard way.

**Trim threading.**
Media3's `Transformer` is single-threaded on the looper it was built on and throws if cancelled from elsewhere, so the Android exporter confines itself to the main looper.
AVFoundation has no such constraint.

**Cancellation.**
`AVAssetExportSession.cancelExport()` reports `.cancelled` through its completion.
`Transformer.cancel()` fires no listener callback at all, so the Android exporter settles the pending result itself -- exactly once, or the awaiting Dart future would hang forever.

**Error reporting.**
Media3's `ExportException` surfaces only the top of its cause chain, which for anything in the frame pipeline is the useless "Video frame processing error".
Failures carry the flattened chain instead.

**Flip composition order.**
A flip mirrors the *rotated* frame on both platforms.
Getting there differs: iOS applies a `scaleX: -1` after the rotation in its Core Image chain, Android adds a second `ScaleAndRotateTransformation` after the rotation one, because folding `setScale(-1, 1)` into the rotation would scale first and mirror the source instead.

**Sticker alpha.**
`UIImage.draw(in:)` is defined as `draw(in:blendMode:alpha:)` with alpha 1, so it overwrites the context alpha; the opacity goes on the draw call.
Android uses `Paint.alpha`.

**GLES array uniforms.**
The Android video blur passes its mask as a *texture*, not as uniforms.
GLES reports an array uniform under the name `uRegions[0]`, so binding it by the name written in the shader source silently fails.

## Performance

Image edits derive their output size from bounds metadata first, then decode only that many pixels.
Cropping a 12 MP photo to a 1080 px square never materialises the 12 MP bitmap, which on Android is also what keeps it off the OOM killer's radar.
Crop, rotate, mirror and scale then fold into a single composite pass.

Every native operation runs off the platform thread.
Decoding a 12 MP still on it would stall the viewfinder the author is looking at.
Trimming is the exception on both platforms, for the looper reason above.

Video blur costs a shader pass per frame, but fragments outside every region take an early-out after one texture fetch, which is most of the frame.

## Output location

The app's cache directory, which monolens asks the platform for (`NSTemporaryDirectory()` / `context.cacheDir`) rather than depending on `path_provider`.
That dependency turned out to be actively hostile: its transitive `jni` package breaks under AGP 9.

The OS may evict the cache, so copy anything that has to outlive the session.
