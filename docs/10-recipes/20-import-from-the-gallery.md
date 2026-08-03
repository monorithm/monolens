# Import from the gallery

`MediaPicker` is a one-shot call that hands back a file and forgets.
It holds no device and has no lifecycle, which is the whole of its difference from [a camera session](./00-capture-a-photo-or-video.md).

```dart
final picker = SystemMediaPicker();

final image = await picker.pickImage();   // null if cancelled
final video = await picker.pickVideo();   // null if cancelled
```

Null means cancelled, and it is the common case rather than an error -- handle it before anything else.

## Enforce your own limits on what came back

A picked clip is whatever the library holds.
Length and size are **not** checked, because that is your policy rather than monolens's.

`CapturedVideo.duration` is populated on return precisely so a capped composer can decide:

```dart
final video = await picker.pickVideo();
if (video == null) return;

if (video.duration > const Duration(seconds: 15)) {
  // Either refuse it, or trim it -- see below.
}
```

Trimming is usually the kinder answer: see [trim a clip](./40-trim-a-clip.md).

`origin` on the result is `gallery`, which is worth carrying if your upload path treats camera media and imported media differently.
