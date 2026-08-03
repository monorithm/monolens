# Test without a camera or a device

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

To work on monolens itself rather than with it -- the integration suite, the
fixtures, and why the assertions sample pixels -- see
[CONTRIBUTING.md](https://github.com/monorithm/monolens/blob/main/CONTRIBUTING.md).
