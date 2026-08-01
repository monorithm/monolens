---
title: "Testing"
description: "Unit tests against the shipped fakes, integration tests against the real native code, and what each tier can answer."
---

Three tiers, each answering something the others cannot.

| Tier | Runs on | Answers |
|---|---|---|
| Unit + fakes | Any machine, no device | Does the Dart layer do the right thing? |
| Integration | Device, simulator or emulator | Does the native code actually work? |
| Pixel-level | Same | Is the *picture* right, not just its dimensions? |

```bash
flutter test                                  # tiers 1
cd example && flutter test integration_test   # tiers 2 and 3
```

## Testing your own composer

Every seam monolens exposes has a double in `package:monolens/testing.dart`.
Import it from `test/` only.

### FakeMonolensPlatform

Stands in for the whole native side.

```dart
final platform = FakeMonolensPlatform();
platform.install();
addTearDown(FakeMonolensPlatform.uninstall);
addTearDown(platform.dispose);

final editor = MonolensEditor(platform: platform);
```

It records the *requests* rather than producing bytes, so a test asserts on intent:

```dart
expect(platform.imageEdits.single.crop!.left, 0.5);
expect(platform.trims.single.startMs, 1500);
expect(platform.probes, isEmpty);
```

| Member | Use |
|---|---|
| `files` | Canned `probe` answers, keyed by path. |
| `defaultInfo` | What an unregistered path probes as. |
| `imageEdits`, `trims`, `cancellations`, `probes` | What was asked for. |
| `exportDuration` | Non-zero gives a test room to cancel mid-flight. |
| `progressTicks` | The values emitted before completion. |
| `nextImageEditError`, `nextTrimError` | Make the next call of that kind throw. |

The fake yields between progress ticks on purpose.
A real export delivers progress over a channel, never in the same microtask as its result, and a fake that emitted synchronously would let the result outrun the ticks and hide a real ordering bug.

### FakeCameraSession

Drives the same state a real session does -- recording flag, elapsed timer, facing, flash -- so viewfinder chrome can be exercised without hardware.

```dart
final session = FakeCameraSession();
// ...pump your composer, then:
session.tick(const Duration(seconds: 15));   // fires the auto-stop at the cap
```

| Member | Use |
|---|---|
| `access` | Set a denial to render a permission state. |
| `tick(elapsed)` | Advance the timer; fires the cap without a real clock. |
| `initializeCount`, `photoCount`, `flipCount` | Assertions. |
| `lastMaxDuration` | What cap the composer passed. |
| `isDisposed` | Whether the device was released. |

### FakeMediaPicker

Returns canned media, or null for a cancelled pick.
`imagePickCount` and `videoPickCount` record what was asked for.

## The integration suite

Runs against the real native code -- no fakes, no mocked channel -- on whatever device you point it at.

```bash
swift tool/make_fixture.swift                       # once, macOS
cd example && flutter test integration_test -d <device-id>
```

### The fixtures

Generated rather than committed, so the repo carries no binaries and the numbers the tests assert against are exactly what the generator produced.

| Fixture | What it is | Why that shape |
|---|---|---|
| `fixture.mp4` | 5 s, 640x360, keyframe every second, 440 Hz tone | The keyframe spacing is what makes a mid-GOP cut genuinely tested: a cut at 1.5 s cannot be served by snapping to a sync sample. A white counter block near the left edge gives flips and blurs something to move. |
| `fixture.jpg` | 800x600, four coloured quadrants | Red, green, blue, yellow. A sampled pixel says unambiguously which region survived and which way up it came out. |
| `fixture_sticker.png` | 128x128 magenta | No quadrant is magenta, so a sample says whether the sticker reached that pixel. Opaque edge to edge, so the stretch-to-rect semantic is assertable. |

The generator is macOS-only -- it uses AVFoundation -- which is not a practical constraint, since every developer of a Flutter iOS plugin has a Mac.

### Why pixels

Dimensions alone cannot catch a transform composed in the wrong order: it gets the size right and the picture wrong.
That is not hypothetical -- it is exactly how iOS and Android came to disagree about whether a flip mirrors the source or the rotated frame, and how an upside-down annotation layer passed a symmetric test.

So the tests decode the output and sample it:

```dart
expect(await _sample(result.path, 0.25, 0.25), _blue);
```

Two rules learned the hard way:

**Assert on channels when a value is near a boundary.**
A 50/50 red-green blur blend lands at roughly `(124, 130, 0)`, two units from a 128 naming threshold -- which name it rounds to is luck, and it rounded differently on the two platforms.

**Compare like with like.**
An export with no annotations takes a different pipeline than one with them -- on iOS it skips the video composition entirely -- so a blur test compares two exports that *both* blur, in different places.
Otherwise it measures the gap between two encoders.

### The example's own chrome

One group in the suite is not about the plugin at all.
`capture chrome` pumps the example's `CapturePage` against a real camera, taps its shutter and asserts on what the page pops -- because the shutter, the cap countdown and the auto-collect wired around them are host code, and they are the part of this repo a reader is most likely to copy.

It is also where the plugin's headless contract is checked at the point it actually reaches a screen: the viewfinder is a plain `Texture` the app built, not a widget that crossed the boundary.

Two things that group had to avoid, both of which bite any test of a live viewfinder:

**Do not `pumpAndSettle` a page that shows a spinner.**
The page renders one until the device opens, and settling waits for animations to stop -- which a spinner never does.
Pump a bounded number of frames instead.

**Assert on widgets, not on semantic labels.**
`find.bySemanticsLabel` throws unless the semantics tree is being built, which an integration test does not enable by default.
`tester.widget<LensShutter>(...).isRecording` says the same thing and says it about state rather than about a string.

### Where things run

| | Physical device | Emulator / simulator |
|---|---|---|
| probe, edit, trim, annotations | Yes | Yes |
| Camera, capture chrome | Yes | Android emulator only; skipped on the iOS simulator |

Camera tests call `markTestSkipped` where no camera exists and carry a long timeout, because opening one on an emulator can take minutes.
That is emulator slowness, not the plugin.

Running two suites back to back can occasionally fail a camera test on device contention as the previous session releases.
It passes in isolation.
