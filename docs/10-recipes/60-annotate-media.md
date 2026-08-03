# Annotate a photo or a clip

Four primitives -- text, stickers, blur and strokes -- burned in at export, into a still or into every frame of a clip.

**Everything is normalized against the output frame**, the frame as it looks after the crop and the rotation.
`Offset(0.5, 0.5)` is its centre.
Sizes are fractions too, so an annotation looks the same on a 720p export and a 4K one.
[Architecture](../20-concepts/90-architecture.md#annotations) explains why that frame and not the source.

## Place a caption

```dart
TextAnnotation(
  text: 'Hello',
  center: const Offset(0.5, 0.8),
  heightFraction: 0.08,         // cap height, fraction of output height
  colorArgb: 0xFFFFFFFF,
  backgroundArgb: 0x99000000,   // null draws no plate
  rotation: 0,                  // clockwise radians
);
```

Use the plate (`backgroundArgb`) over busy media.
It is a rounded rectangle behind the glyphs with padding derived from the type size, and it is what keeps text legible over a photo you do not control.

## Add an emoji

**An emoji is text.**
It is a glyph the platform already knows how to shape, so there is no emoji primitive to keep current:

```dart
AnnotationFactories.emoji('🎉', center: const Offset(0.2, 0.2));
```

## Composite a sticker

```dart
StickerAnnotation(
  imagePath: '/path/to/badge.png',
  rect: const CropRect(left: 0.6, top: 0.1, width: 0.3, height: 0.3),
  rotation: 0,
  opacity: 1,
);
```

Any PNG or JPEG on disk. A missing or unreadable file costs that sticker, not the export.

:::caution[A sticker fills its rect; it is not fitted inside it]
Both platforms stretch the bitmap to the rect, so a square sticker in a wide rect comes out wide.
This is the one primitive whose preview can silently disagree with its export.
Draw previews with `BoxFit.fill`, and make placement rects square *in pixels* rather than in normalized units -- [the square-rect trap](./70-render-the-editing-canvas.md#the-square-rect-trap) has the arithmetic.
:::

## Blur a face

```dart
BlurAnnotation(
  rect: faceRect,
  strength: 0.5,              // 0-1
  shape: BlurShape.oval,      // or rectangle
);
```

`strength` scales against the region's own shorter edge rather than being an absolute radius, so a value chosen for a large box still reads on a small one.

Blur is the only primitive that **samples the media**, which is why it is applied beneath the other three regardless of list position -- a caption across a blurred face has to stay legible.

## Draw a freehand stroke

```dart
StrokeAnnotation(
  points: [const Offset(0.1, 0.5), const Offset(0.9, 0.5)],
  colorArgb: 0xFFE5484D,
  widthFraction: 0.012,       // fraction of the output's shorter edge
);

stroke.extendedTo(nextPoint);   // what a drag calls, once per sample
```

Points are normalized and in draw order.
A single point renders as a dot, so a tap is not nothing.

## Work with the list

`AnnotationList` is an extension on `List<Annotation>`, pure so it composes with any state management:

| Method | Notes |
|---|---|
| `replacing(annotation)` | Matches on `id`. What a drag calls. |
| `removing(id)` | |
| `bringingToFront(id)` | Moves to the end of the paint order. |
| `byId(id)` | Null when absent. |
| `isFlattenable` | True when nothing samples the source -- no blur. |

The list paints back to front: the last annotation is on top.

Every annotation carries a stable `id`, which is what lets a host select, move and delete one, and what lets undo tell "moved the caption" from "added a second caption".
