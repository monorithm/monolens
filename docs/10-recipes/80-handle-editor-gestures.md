# Handle editor gestures

An editor that only places things is a catalogue.
Four behaviours make it an editor: select, move, transform, delete.

## Normalize a gesture

```dart
Offset _normalize(Offset local, Size canvas) => Offset(
  (local.dx / canvas.width).clamp(0.0, 1.0),
  (local.dy / canvas.height).clamp(0.0, 1.0),
);
```

That is the whole conversion, because [the canvas *is* the output frame](./70-render-the-editing-canvas.md).

## Hit-test front to back

So the thing drawn last is the thing you grab:

```dart
for (final annotation in annotations.reversed) {
  if (box(annotation, size).contains(point, slop: 8)) return annotation;
}
```

**Make that box carry its angle, not just its rectangle**, and share it between the painter, the hit test and the handles.

A plain `Rect` is tempting because most of the geometry is axis-aligned, and it survives contact with a rotated annotation surprisingly badly: the outline stays square around a turned sticker, the corner handles sit nowhere near the corners the author can see, and the tappable region is a different shape from the drawn one.
That last is how you get "I tapped it and nothing happened".

```dart
Offset corner(double sx, double sy) => _spin(unrotatedCorner(sx, sy), rotation);
bool contains(Offset point, {double slop = 0}) =>
    rect.inflate(slop).contains(_spin(point, -rotation));
```

Paint the outline by turning the *canvas* about the box's centre rather than by turning the geometry -- in the annotation's own frame it is a plain rectangle again.

Not everything needs it: a stroke has no rotation of its own, since turning one rewrites its points, and a blur is deliberately never turned at all.

## Pinch to scale and rotate

**Use a scale recognizer, not a pan one.**
A pan recognizer never reports a second finger, so pinch and twist are invisible to it, and `GestureDetector` refuses to carry `onPan*` and `onScale*` at once -- so the scale recognizer serves dragging too, with `pointerCount == 1` meaning drag.

:::caution[Apply the transform to a snapshot, never to the live value]
`ScaleUpdateDetails.scale` and `.rotation` report *totals* measured from the start of the gesture, not increments.
Apply them to the annotation as it was when the gesture began, or the transform compounds exponentially and the shape explodes on the first pinch.
:::

```dart
_baseline = annotation;                       // at gesture start
...
controller.update(transformedFrom(_baseline,  // never from the live value
  scale: details.scale, rotation: details.rotation));
```

## Add a corner handle

Worth having alongside the pinch: it is the discoverable affordance, and it works one-handed.
Compare the vector from the shape's centre now against the vector at the grab.

Two traps in the handle specifically:

**It needs its own recognizer.**
A `Stack`'s hit test stops at the topmost child that reports a hit, and an icon inside a handle reports one -- `RenderCustomPaint.hitTestSelf` returns true by default.
So a drag beginning on the handle never reaches the canvas detector underneath it, and a handle that relies on falling through simply does nothing.

**Measure its travel globally.**
The handle rides the corner it is resizing, so it moves under the finger; a local delta folds the widget's own movement back into the gesture.

## Scale each primitive correctly

This is what keeps output crisp:

| Primitive | What scaling changes |
|---|---|
| Text | `heightFraction` -- the type size, so glyphs stay sharp |
| Sticker | The rect, about its centre |
| Blur | The rect, about its centre |
| Stroke | The points *and* `widthFraction` -- pinching a drawn shape and having only its thickness change reads as broken |

**Rotate a stroke in pixels and convert back.**
Normalized space is not isotropic -- a fraction of the width and a fraction of the height are different numbers of pixels -- so rotating in it shears the line.

## Coalesce the drag into one undo step

```dart
onPanUpdate: (d) => history.push(next, coalesceKey: '${id}.move'),
onPanEnd: (_) => history.commit(),
```

Without this, undo walks back one drag sample at a time and is useless.
See [wire undo and redo](./50-wire-undo-and-redo.md).
