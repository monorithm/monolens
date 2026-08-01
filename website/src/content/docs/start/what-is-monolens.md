---
title: "What is monolens?"
description: "What the package does, what headless means in practice, and why there is no ffmpeg."
---

Monolens is a Flutter plugin that captures media and edits it on the device. A
camera and a gallery import; crop, rotate and downscale; blur regions; text,
emoji, stickers and coloured lines burned in; mute; and a frame-accurate video
trim. With undo.

It ships no widgets.

## Headless is the organizing constraint

Most camera and editor packages hand you a screen. That screen is someone
else's design system, and the work of a real integration is fighting it back
into yours.

Monolens draws the boundary one level lower. Capture hands back a texture id and
the geometry needed to orient it; you render `Texture(textureId: …)` inside
whatever chrome you want. Editing takes a file path and a declaration, and gives
you back a file path. There is nothing to theme, because there is nothing drawn.

```dart
final preview = session.preview;          // data, not a widget
if (preview == null) return const SizedBox.shrink();

return AspectRatio(
  aspectRatio: preview.aspectRatio,
  child: Texture(textureId: preview.textureId),
);
```

The cost is that you write the viewfinder and the editing surface. The
[example app](https://github.com/monorithm/monolens/tree/main/example) is a
complete one — direct manipulation, crop handles, a filmstrip scrubber,
annotation tools and undo — and
[building an editor](/monolens/guides/building-an-editor/) is the recipe.

## An edit is a value, not a command

`ImageEdit` and `VideoEdit` are immutable declarations that get re-applied to
the original every time.

```dart
const ImageEdit(
  crop: CropRect(left: 0.25, top: 0, width: 0.5, height: 1),
  rotation: MonoRotation.quarterTurn,
  maxDimension: 2048,
)
```

Three things fall out of that. Stacking edits costs no generation loss, because
nothing ever re-encodes an encode. "Revert" is dropping back to
`ImageEdit.none`. And undo is cheap — [`EditHistory`](/monolens/guides/editing/)
just keeps previous values, so there is nothing to invert and nothing to replay,
which matters because blur has no inverse.

## No ffmpeg

Trimming goes through `AVAssetExportSession` on iOS and
`androidx.media3.transformer.Transformer` on Android. No bundled native binary,
no per-ABI size cost.

Cuts are frame-accurate: both platforms force a re-encode rather than snapping
the in-point back to the nearest keyframe, which would slide a hand-placed
handle backwards by up to a GOP.

## What it does not do

- **No permissions plugin.** Most apps already have one, and two competing
  requesters produce two prompts. The session reports what it found
  (`CameraAccess`) and you decide what to show.
- **No playback.** Use `video_player` or anything else; monolens hands you a
  file path.
- **No filters or LUTs.** The four annotation primitives are the drawing
  surface; colour grading is out of scope.
- **iOS and Android only.** A native capture pipeline has nothing to say on web
  or desktop.

## Where to go next

- [Getting started](/monolens/start/getting-started/) — empty project to a
  captured photo with a caption on it.
- [Capture](/monolens/guides/capture/) — the session, the preview texture, and
  the gallery import.
- [Editing](/monolens/guides/editing/) — crops, trims, filmstrips and exports.
- [Architecture](/monolens/reference/architecture/) — why each boundary sits
  where it does.
