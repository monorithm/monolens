---
title: "Editing"
description: "MediaEditor: probe a file, apply an image edit, run a video export, pull frames for a filmstrip."
---

Everything goes through `MediaEditor`.

| Call | What it does |
|---|---|
| `probe(path)` | Dimensions, duration and size. Cheap -- no full decode. |
| `applyImageEdit(path, edit)` | Crop, rotate, flip, downscale, annotate, encode. |
| `startTrim(path, edit)` | Cancellable clip export with progress. |
| `filmstrip(path, …)` | Evenly spaced frames as JPEG bytes. |

`MonolensEditor` is the implementation; `MediaEditor` is an interface so a composer's tests can run against a fake.

## Edits are values

An `ImageEdit` and a `VideoEdit` describe a *result*, not a sequence of operations applied to a buffer.

That is what makes an edit re-applicable to the original.
Rotating twice and cropping does not stack three encodes with three rounds of generation loss; it produces one value, applied once, to the untouched source.
"Revert" is `ImageEdit.none` rather than an undo stack, and a host can persist an edit next to the original as a few numbers and re-derive the output whenever it likes.

It is also what makes [undo](#undo) almost free.

### Skip the no-op

```dart
if (edit.isIdentity) return original;                       // stills
if (edit.isIdentityFor(clip.duration)) return original;     // clips
```

An identity edit would still cost a full decode and re-encode, and would still lose a generation of quality.
Checking is the difference between a free "Done" and a pointless export.

## The order of operations

Fixed, and the same on both platforms:

**crop → rotate → flip → downscale → annotate → encode**

Two clauses are worth stating out loud because they are the ones that silently differ between implementations:

- The flip mirrors the **rotated** frame, not the source. A rotate-and-flip therefore lands identically on iOS and Android; before this was pinned by tests, the two disagreed and produced correctly-sized, visibly wrong images.
- Annotations are positioned against the **output** frame -- after the crop and rotation. That is the frame the author was looking at, and it means changing the crop does not move a caption out from under them.

## Stills

```dart
final result = await editor.applyImageEdit(
  source.path,
  ImageEdit(
    crop: const CropRect(left: 0.25, top: 0, width: 0.5, height: 1),
    rotation: MonoRotation.quarterTurn,
    flipHorizontal: true,
    maxDimension: 2048,
    format: MonoImageFormat.jpeg,
    quality: 90,
    annotations: [...],
  ),
);
```

| Field | Notes |
|---|---|
| `crop` | Normalized fractions. Defaults to the whole frame. |
| `rotation` | Clockwise quarter turns. |
| `flipHorizontal` | Mirrors the rotated frame. |
| `maxDimension` | Caps the longest edge after crop and rotation. |
| `format`, `quality` | `quality` is JPEG only, 1--100. |
| `annotations` | See [annotations](/monolens/guides/annotations/). |

`CropRect` carries the fiddly geometry so your UI does not have to:

```dart
CropRect.full();                                              // identity
CropRect.centered(aspectRatio: 1, sourceAspectRatio: 16 / 9); // largest 1:1 that fits
someRect.clampedToBounds();                                   // slide back inside
```

Fractions rather than pixels because a crop UI works in layout space, whose size changes with rotation, insets and screen size -- a pixel rect captured against one preview size is wrong at the next.
They stay normalized all the way to the platform, which is what keeps an edit to a single channel call: nothing has to probe the source first, and the two sides cannot disagree about what the source's dimensions are.

## Clips

```dart
final job = editor.startTrim(
  source.path,
  VideoEdit(
    trim: const VideoTrim(
      start: Duration(milliseconds: 1500),
      end: Duration(milliseconds: 3500),
    ),
    crop: someRect,
    rotation: MonoRotation.quarterTurn,
    flipHorizontal: true,
    muteAudio: true,
    annotations: [...],
  ),
);
```

`VideoTrim` is purely a range -- an absolute start and end, not a start plus a length, because both handles are dragged independently and a length would have to be recomputed on every frame of a left-handle drag.

`clamped` enforces limits while holding whichever handle you are not dragging:

```dart
trim.clamped(
  clip.duration,
  minimum: const Duration(milliseconds: 500),
  maximum: const Duration(seconds: 15),
  anchorStart: true,   // the start is fixed; push the end
);
```

Muting drops the audio track rather than exporting a silent one, which is bytes an upload does not need.

### Cuts are frame-accurate

Both platforms force a re-encode rather than cutting on the nearest sync sample.
Passthrough export is far faster, but it can only cut on keyframes, so an in-point between them silently slides backwards by up to a GOP.
That is fine for a rough cut and wrong when an author has just placed a handle on a specific frame.

### The job handle

An export is the one operation here slow enough to need a progress bar and a cancel button.
A 15 second clip is a few hundred milliseconds on a recent phone; a minute of 4K on an old one is not.

```dart
job.id;                                    // addresses this export
job.progress.listen(...);                  // 0.0-1.0, broadcast, closes on completion
await job.cancel();                        // result then throws TrimCancelled
final CapturedVideo result = await job.result;
```

`TrimCancelled` is a distinct type from `MediaEditException` because cancelling is not a failure: a composer should drop it silently rather than show the banner it shows for a real error.

## Filmstrips

```dart
final frames = await editor.filmstrip(
  clip.path,
  duration: clip.duration,
  frames: 12,
  maxDimension: 160,
);
```

Returns encoded JPEG bytes, one per frame, in time order.
Frames are sampled at their *centres* rather than at clip edges: the first and last frames of a recording are often a black lead-in or a motion-blurred stop, and a strip of those reads as a broken decode.

An unreadable frame comes back empty rather than failing the whole strip.

## Undo

Undo is a stack of previous values, and that is the whole design.
There is nothing to invert and nothing to replay -- which matters, because blur has no inverse.

```dart
final history = EditHistory(ImageEdit.none);

history.push(edit.rotatedClockwise());
history.push(next, coalesceKey: 'drag');   // a whole gesture is one step
history.commit();                          // gesture ended

if (history.canUndo) history.undo();
if (history.canRedo) history.redo();
history.reset();          // back to the start, itself undoable
history.clearHistory();   // keep the value, drop the steps
```

| Member | Notes |
|---|---|
| `value` | The current edit. |
| `canUndo`, `canRedo`, `depth` | For enabling controls. |
| `push(next, coalesceKey:)` | Consecutive pushes sharing a key collapse into one step. |
| `commit()` | Ends a coalescing run. |
| `limit` | How many steps are kept. Defaults to 50. |

`EditHistory` implements `ValueListenable`, so it binds to a `ValueListenableBuilder`, a bloc, a signal or a plain listener -- it is not tied to one state-management choice.
It is generic, so the same control drives a still and a clip.

Coalescing is what keeps a drag from flooding the stack: a crop gesture emits hundreds of values, and going back should undo the gesture rather than one sample of it.

## Errors

| Code | Dart |
|---|---|
| `monolens/cancelled` | `TrimCancelled` |
| everything else | `MediaEditException`, carrying `code` and `message` |

Codes you may see: `monolens/not-found`, `monolens/unsupported`, `monolens/decode-failed`, `monolens/encode-failed`, `monolens/invalid-range`, `monolens/export-failed`.

## Where output goes

Into the app's cache directory, which monolens asks the platform for rather than pulling in `path_provider`.
The OS may evict it, so copy anything that has to outlive the session.

`MonolensEditor` takes an `outputPath` builder if you want to place files yourself -- which is also how tests write into a directory they control.
