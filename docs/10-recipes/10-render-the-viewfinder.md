# Render the viewfinder

`session.preview` returns a `PreviewTexture` or null.
It is data, not a widget, so the chrome around it is entirely yours.

| Field | Why you need it |
|---|---|
| `textureId` | The id for a `Texture` widget. |
| `size` | The stream's dimensions, in sensor orientation. |
| `sensorOrientation` | Degrees the sensor is mounted clockwise. |
| `facing` | Which lens, so you can mirror the front one. |
| `aspectRatio` | `size` with the sensor orientation folded in. |

```dart
final preview = session.preview;
if (preview == null) return const SizedBox.shrink();

Widget texture = Texture(textureId: preview.textureId);

// iOS delivers frames already oriented; Android streams them in sensor
// orientation. Fold in the device orientation too if you support more than one.
if (Platform.isAndroid && preview.sensorOrientation % 360 != 0) {
  texture = RotatedBox(
    quarterTurns: (preview.sensorOrientation ~/ 90) % 4,
    child: texture,
  );
}

// Mirroring the front lens is a presentation choice, so it lives here.
if (preview.facing == CameraFacing.front) {
  texture = Transform(
    alignment: Alignment.center,
    transform: Matrix4.diagonal3Values(-1, 1, 1),
    child: texture,
  );
}

return AspectRatio(aspectRatio: preview.aspectRatio, child: texture);
```

:::caution[Test the null, not the id]
Zero is a valid texture id -- an iPhone reports exactly that for its first session -- so `if (textureId != 0)` silently blanks the viewfinder on the most common device there is.
:::

`example/lib/capture_page.dart` is a complete viewfinder built this way.
