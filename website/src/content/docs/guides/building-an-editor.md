---
title: "Building an editor"
description: "The recipe for an editing surface built on monolens, and the traps."
---

Monolens ships no widgets, so the editing surface is yours.
This page is the recipe, and the traps.

The example app is a working implementation of everything here -- a full editor with direct manipulation, crop handles, a filmstrip scrubber, annotation tools and undo, in about a thousand lines under `example/lib/editor/`.
Read it alongside this.

## What you own, and what you do not

| Yours | Monolens's |
|---|---|
| Gestures, hit-testing, selection, handles | The geometry those produce |
| Rendering the preview | Rendering the export |
| Tool pickers, colour palettes, sheets | Nothing |
| Undo *controls* | The undo *stack* (`EditHistory`) |
| Device orientation policy | Sensor orientation, reported |

The dividing line is: monolens owns anything that has to be identical between the preview and the export, and nothing else.

## The one rule

**The canvas must show what the exporter will produce.**

Everything below follows from it, and every bug worth having a name for is a violation of it.

Concretely: the canvas renders the media with the crop and rotation *already applied*, at the output's aspect ratio.
Then annotation coordinates are literally output coordinates, and there is no conversion to get wrong.

```dart
final aspect = draft.outputAspectRatio(source.aspectRatio);

AspectRatio(
  aspectRatio: aspect,
  child: Stack(children: [
    _croppedRotatedMedia(),   // what the export will contain
    _annotationLayer(),       // drawn in output coordinates
    _gestureLayer(),
  ]),
);
```

The exception is crop mode, where the *whole* frame has to stay visible so the author can see what they are cutting away.
Swap the canvas rather than trying to serve both at once.

Showing a cropped region of an untouched image is a scale and a translate:

```dart
LayoutBuilder(builder: (context, constraints) {
  final width = constraints.maxWidth / crop.width;
  final height = constraints.maxHeight / crop.height;
  return ClipRect(
    child: Stack(children: [
      Positioned(
        left: -crop.left * width,
        top: -crop.top * height,
        width: width,
        height: height,
        child: media,
      ),
    ]),
  );
});
```

## Normalizing a gesture

```dart
Offset _normalize(Offset local, Size canvas) => Offset(
  (local.dx / canvas.width).clamp(0.0, 1.0),
  (local.dy / canvas.height).clamp(0.0, 1.0),
);
```

That is the whole conversion, because the canvas *is* the output frame.

## Selection and direct manipulation

An editor that only places things is a catalogue.
Four behaviours make it an editor: select, move, transform, delete.

Hit-test front to back, so the thing drawn last is the thing you grab:

```dart
for (final annotation in annotations.reversed) {
  if (box(annotation, size).contains(point, slop: 8)) return annotation;
}
```

Make that box carry its *angle*, not just its rectangle, and share it between the painter, the hit test and the handles.

A plain `Rect` is tempting because most of the geometry is axis-aligned, and it survives contact with a rotated annotation surprisingly badly: the outline stays square around a turned sticker, the corner handles sit nowhere near the corners the author can see, and the tappable region is a different shape from the drawn one. That last is how you get "I tapped it and nothing happened" — and the further the annotation is turned, the wider the two diverge.

```dart
Offset corner(double sx, double sy) => _spin(unrotatedCorner(sx, sy), rotation);
bool contains(Offset point, {double slop = 0}) =>
    rect.inflate(slop).contains(_spin(point, -rotation));
```

Paint the outline by turning the *canvas* about the box's centre rather than by turning the geometry — in the annotation's own frame it is a plain rectangle again.

Not everything needs it: a stroke has no rotation of its own, since turning one rewrites its points, and a blur is deliberately never turned at all.

Offer two ways to scale and turn a selection, because people reach for both.

**Pinch** wants a *scale* recognizer, not a pan one.
A pan recognizer never reports a second finger, so pinch and twist are simply invisible to it, and `GestureDetector` refuses to carry `onPan*` and `onScale*` at once -- so the scale recognizer has to serve dragging too, with `pointerCount == 1` meaning drag.

**A corner handle** stays worth having: it is the discoverable affordance, and it works one-handed.
Compare the vector from the shape's centre now against the vector at the grab.

Both report *totals* measured from the start of the gesture -- `ScaleUpdateDetails.scale` is cumulative, not incremental.
So apply them to a snapshot of the annotation taken when the gesture began, never to the value the last frame produced, or the transform compounds exponentially and the shape explodes on the first pinch.

```dart
_baseline = annotation;                       // at gesture start
...
controller.update(transformedFrom(_baseline,  // never from the live value
  scale: details.scale, rotation: details.rotation));
```

Two traps in the handle specifically:

**It needs its own recognizer.**
A `Stack`'s hit test stops at the topmost child that reports a hit, and an icon inside a handle reports one -- `RenderCustomPaint.hitTestSelf` returns true by default. So a drag beginning on the handle never reaches the canvas detector underneath it, and a handle that relies on falling through simply does nothing.

**Measure its travel globally.**
The handle rides the corner it is resizing, so it moves under the finger; a local delta folds the widget's own movement back into the gesture.

Scale means different things per primitive, and getting this right is what keeps output crisp:

| Primitive | What scaling changes |
|---|---|
| Text | `heightFraction` -- the type size, so glyphs stay sharp |
| Sticker | The rect, about its centre |
| Blur | The rect, about its centre |
| Stroke | The points *and* `widthFraction` -- pinching a drawn shape and having only its thickness change reads as broken |

Rotating a stroke has to happen in pixels and be converted back.
Normalized space is not isotropic -- a fraction of the width and a fraction of the height are different numbers of pixels -- so rotating in it shears the line.

## Coalescing undo

A drag emits hundreds of values.
Push them all with the same key, and commit when the gesture ends:

```dart
onPanUpdate: (d) => history.push(next, coalesceKey: '${id}.move'),
onPanEnd: (_) => history.commit(),
```

Without this, undo walks back one drag sample at a time and is useless.

## The square-rect trap

A `CropRect` with equal `width` and `height` is only square on a square frame.
On a 9:16 clip it is markedly taller than it is wide -- and because both platforms **stretch** a sticker to fill its rect, that exports a distorted sticker while a `BoxFit.contain` preview looks perfect.

Place square things square *in pixels*:

```dart
CropRect squareAt(Offset centre, {double fraction = 0.28}) {
  final aspect = draft.outputAspectRatio(source.aspectRatio);
  final width = aspect >= 1 ? fraction / aspect : fraction;
  final height = aspect >= 1 ? fraction : fraction * aspect;
  return CropRect(
    left: (centre.dx - width / 2).clamp(0.0, 1 - width),
    top: (centre.dy - height / 2).clamp(0.0, 1 - height),
    width: width,
    height: height,
  );
}
```

And draw sticker previews with `BoxFit.fill`, which is what the exporters do.
`contain` looks better and is a lie.

## Previewing blur

You cannot: a `CustomPainter` cannot sample the media beneath it.

Draw a frosted stand-in -- a translucent white fill in the region's shape -- and let the export be the truth.
Trying to fake a real blur in the preview costs a shader and still will not match.

## Rendering stickers

Stickers are files, and a `CustomPainter` cannot decode an image synchronously, so they render as widgets layered above the media rather than in the painter:

```dart
Positioned(
  left: rect.left * size.width,
  top: rect.top * size.height,
  width: rect.width * size.width,
  height: rect.height * size.height,
  child: IgnorePointer(
    child: Transform.rotate(
      angle: rotation,
      child: Image.file(File(path), fit: BoxFit.fill),
    ),
  ),
);
```

`IgnorePointer` matters: gestures belong to the canvas's gesture layer, not to the sticker.

## Export

```dart
if (draft.isUntouched) return original;   // no encode, no generation loss

final job = editor.startTrim(source.path, edit);
job.progress.listen((v) => setState(() => _progress = v));

try {
  return await job.result;
} on TrimCancelled {
  return null;                            // not a failure; show nothing
} on MediaEditException catch (e) {
  showBanner(e.message);
}
```

Show a blocking overlay with the progress and a cancel button.
An export can take long enough that a silent UI reads as a hang.

## A tour of the example

| File | What to look at |
|---|---|
| `editor/editor_page.dart` | The shell: the tool rail, the contextual tray, the export overlay. |
| `editor/editor_controller.dart` | All state in one place -- tool, selection, history, job. |
| `editor/editor_draft.dart` | One sealed type over `ImageEdit` and `VideoEdit`, so the UI is written once. |
| `editor/media_canvas.dart` | The canvas, hit-testing, handles, and the drag maths. |
| `editor/crop_overlay.dart` | Crop grips, aspect locking, the thirds grid. |
| `editor/trim_bar.dart` | Filmstrip, in/out handles, playhead. |
| `editor/tool_panels.dart` | Text composer, emoji grid, sticker sheet, colours. |
| `editor/stickers.dart` | Stickers painted at runtime and written to the cache. |
| `ui/lens_icons.dart` | The editing glyphs, drawn rather than borrowed. |
| `ui/lens_chrome.dart` | Chrome over media: the rail, the tray, the shutter, the scrims. |

The draft wrapper is the trick worth stealing: a still and a clip carry different edits, but almost every control touches the parts they share, so wrapping both in one sealed type means the canvas, the tools and the undo stack are written once instead of twice.

Two things in there are about how an editor *looks* rather than what it does, and both are worth copying.

**The rail is flat, the controller is not.**
`EditorMode` and `EditorTool` are separate in the controller because crop changes what the canvas shows and nothing else does.
That distinction is real, and it is entirely the controller's business: the rail presents one row of tools with cropping as one of them, and maps each entry onto the pair.
Surfacing an internal state machine as two rows of buttons is how an editor ends up looking like a settings screen.

**Domain glyphs get drawn.**
A general icon set will not carry *crop*, *flip*, *blur*, *a pen nib*, and substituting the nearest available glyph is what makes a toolbar look improvised.
`lens_icons.dart` draws the dozen it needs on the same grid and stroke weight as the rest of the system, which is a couple of hundred lines and the single largest visual difference in the app.
