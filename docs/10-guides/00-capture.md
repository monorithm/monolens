# Capture

Two seams, with nothing in common at runtime.
`CameraSession` is a held device with a lifecycle; `MediaPicker` is a one-shot call that hands back a file and forgets.
Both are interfaces with test doubles, so a composer can be exercised without hardware -- see [testing](./40-testing.md).

## The session

```dart
final session = MonolensCameraSession();
final access = await session.initialize(CameraCaptureMode.video);
```

`initialize` opens the device for a mode and is safe to call again to switch mode.
Switching rebuilds the underlying controller, which is not an oversight: neither the lens nor the audio track can be changed on a live one.

Mode decides whether the microphone is claimed at all.
A photo-only author never sees a microphone prompt, which is the entire reason mode is a parameter rather than a setting.

| Member | What it is for |
|---|---|
| `isInitialized` | Whether the device is open. |
| `mode`, `facing`, `flash` | Current state, for rendering chrome. |
| `isRecording` | A `ValueListenable`. Also the auto-stop signal -- see below. |
| `recordedDuration` | A `ValueListenable`, for an on-screen timer. |
| `flip()`, `cycleFlash()` | Lens and flash. `flip` is refused mid-recording. |
| `capturePhoto()` | Returns a `CapturedImage`. |
| `startVideoRecording()`, `stopVideoRecording()` | Returns a `CapturedVideo`. |
| `pausePreview()`, `resumePreview()` | Hand the device back when backgrounded. |
| `dispose()` | Release everything. |

Release the device when the app leaves the foreground.
Holding a camera in the background is a fast way to be killed by the OS, and on iOS the session is interrupted anyway:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.inactive ||
      state == AppLifecycleState.paused) {
    session.pausePreview();
  } else if (state == AppLifecycleState.resumed) {
    session.resumePreview();
  }
}
```

## Rendering the viewfinder

`session.preview` returns a `PreviewTexture` or null.
It is data, not a widget -- that is what headless means here, and it is the one place the constraint costs the host anything.

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

**Test the null, not the id.**
Zero is a valid texture id -- an iPhone reports exactly that for its first session -- so `if (textureId != 0)` silently blanks the viewfinder on the most common device there is.

`example/lib/capture_page.dart` is a complete viewfinder built this way.

## The recording cap

`startVideoRecording(maxDuration:)` stops the take itself.

```dart
session.isRecording.addListener(() {
  if (!session.isRecording.value) collect();  // fires on tap *or* on the cap
});

await session.startVideoRecording(maxDuration: const Duration(seconds: 15));
```

The session clears `isRecording` when the cap is reached, and that flag is your cue to call `stopVideoRecording()` and collect the file -- the same cue a second shutter tap produces, so there is one code path for both.

Enforcing the limit at the shutter rather than checking afterwards matters: rejecting a recording the author has already made is a strictly worse experience than not letting it run long.

## Permissions

Monolens does not depend on a permissions plugin and never prompts.

Most apps already broker permissions through something of their own, and two competing requesters produce two dialogs and a confused user.
`initialize` reports what it found:

| `CameraAccess` | What to do |
|---|---|
| `granted` | Render the preview. |
| `denied` | Show a rationale and offer to ask again. |
| `permanentlyDenied` | Deep-link to Settings; asking again will not prompt. |
| `unavailable` | No camera, or another app holds it. |

Request through whatever you already use, then call `initialize`.
The distinction between `denied` and `permanentlyDenied` exists so you can choose between a rationale and a Settings link rather than showing the wrong one.

## Gallery import

```dart
final picker = SystemMediaPicker();

final image = await picker.pickImage();   // null if cancelled
final video = await picker.pickVideo();   // null if cancelled
```

A picked clip is whatever the library holds.
Length and size are **not** checked -- that is the caller's policy -- which is why `CapturedVideo.duration` is populated on return: a capped composer probes the result and either trims it or refuses it.

## What you get back

`CapturedMedia` is a sealed type with two cases, `CapturedImage` and `CapturedVideo`.

| Member | Notes |
|---|---|
| `path`, `file` | Absolute path. Files monolens produces live in the app cache. |
| `contentType` | `image/jpeg`, `video/mp4`, and so on. |
| `byteSize` | From disk. |
| `width`, `height` | Display dimensions, already rotation-corrected. |
| `aspectRatio` | `width / height`. |
| `origin` | `camera`, `gallery` or `edit`. |
| `duration` | `CapturedVideo` only. |
| `readBytes()` | Reads the file. Call at the point of upload. |

`origin` is worth keeping because the two capture paths have different trust properties: a camera clip was length-capped at the shutter, a gallery import is whatever the library holds.

The cache directory is the OS's to evict, so copy anything that has to outlive the session.
