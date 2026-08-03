# Render the editing canvas

**The canvas must show what the exporter will produce.**
Every bug worth having a name for in an editing surface is a violation of that.

Render the media with the crop and rotation *already applied*, at the output's aspect ratio.
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

## Swap the canvas for crop mode

Crop mode is the exception: the *whole* frame has to stay visible so the author can see what they are cutting away.
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

## Render stickers as widgets, not in the painter

A `CustomPainter` cannot decode an image synchronously, so stickers layer above the media:

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

**`BoxFit.fill`, not `contain`** -- that is what the exporters do. `contain` looks better and is a lie.

## The square-rect trap

A `CropRect` with equal `width` and `height` is only square on a square frame.
On a 9:16 clip it is markedly taller than it is wide -- and because both platforms stretch a sticker to fill its rect, that exports a distorted sticker while a `BoxFit.contain` preview looks perfect.

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

## Preview blur with a stand-in

You cannot preview a real blur: a `CustomPainter` cannot sample the media beneath it.

Draw a frosted stand-in -- a translucent white fill in the region's shape -- and let the export be the truth.
Trying to fake a real blur in the preview costs a shader and still will not match.

Next: [handle the gestures](./80-handle-editor-gestures.md).
