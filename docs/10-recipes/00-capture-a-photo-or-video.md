# Capture a photo or a video

`CameraSession` is a held device with a lifecycle.
Open it for a mode, capture, release it when the app leaves the foreground.

```dart
final session = MonolensCameraSession();
final access = await session.initialize(CameraCaptureMode.video);
```

`initialize` opens the device for a mode and is safe to call again to switch mode.
Switching rebuilds the underlying controller, because neither the lens nor the audio track can be changed on a live one.

**Mode decides whether the microphone is claimed at all**, which is why it is a parameter rather than a setting: a photo-only author never sees a microphone prompt.

```dart
final photo = await session.capturePhoto();          // CapturedImage

await session.startVideoRecording();
final clip = await session.stopVideoRecording();     // CapturedVideo
```

`flip()` and `cycleFlash()` change lens and flash; `flip` is refused mid-recording.
`isRecording` and `recordedDuration` are `ValueListenable`s, for a shutter button and an on-screen timer.

## Handle the permission you were given

Monolens never prompts.
Most apps already broker permissions through something of their own, and two competing requesters produce two dialogs and a confused user.

Request through whatever you already use, then call `initialize` and act on what it reports:

| `CameraAccess` | What to do |
|---|---|
| `granted` | Render the preview. |
| `denied` | Show a rationale and offer to ask again. |
| `permanentlyDenied` | Deep-link to Settings; asking again will not prompt. |
| `unavailable` | No camera, or another app holds it. |

The distinction between `denied` and `permanentlyDenied` exists so you can choose between a rationale and a Settings link rather than showing the wrong one.

## Cap a recording at the shutter

`startVideoRecording(maxDuration:)` stops the take itself:

```dart
session.isRecording.addListener(() {
  if (!session.isRecording.value) collect();  // fires on tap *or* on the cap
});

await session.startVideoRecording(maxDuration: const Duration(seconds: 15));
```

The session clears `isRecording` when the cap is reached, and that flag is your cue to call `stopVideoRecording()` and collect the file -- the same cue a second shutter tap produces, so there is one code path for both.

Enforcing the limit at the shutter rather than checking afterwards matters: rejecting a recording the author has already made is a strictly worse experience than not letting it run long.

## Release the device in the background

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

## What you get back

`CapturedMedia` is a sealed type with two cases, `CapturedImage` and `CapturedVideo`.
Both carry `path`, `contentType`, `byteSize`, `width`, `height` and `aspectRatio` -- already rotation-corrected -- plus `duration` on video and `readBytes()` for the point of upload.

`origin` is worth keeping: it is `camera`, `gallery` or `edit`, and the two capture paths have different trust properties -- a camera clip was length-capped at the shutter, a [gallery import](./20-import-from-the-gallery.md) is whatever the library holds.

Files monolens produces live in the app cache, which is the OS's to evict, so copy anything that has to outlive the session.

Next: [render the viewfinder](./10-render-the-viewfinder.md).
