# Contributing

Documentation for people changing monolens, not people using it.

User documentation lives in [`docs/`](docs/) and is published at
[monorithm.github.io/opensource/monolens/latest](https://monorithm.github.io/opensource/monolens/latest/),
alongside monowave's.
The pages are plain markdown with no frontmatter -- the first `#` heading is the title, numeric filename prefixes set the order -- so they read correctly here on GitHub and on the site without being written twice.
`redirect/` keeps the old URLs working, including the one baked into monolens 0.4.0's pubspec.

## The checks

Everything below must pass before a change lands; CI runs the same set.

```bash
flutter analyze
flutter test
dart format --output=none --set-exit-if-changed $(git ls-files '*.dart' | grep -v '\.g\.dart$')
```

Generated files are excluded from the format check and never edited by hand.

Native changes need a real run, not just a compile:

```bash
cd example && flutter test integration_test -d <device-id>
```

Run it on both platforms.
Most of the bugs this project has had were places where the two agreed on dimensions and disagreed on pixels, and only a device catches those.

## Regenerating the bridge

`pigeons/monolens_api.dart` is the single source of truth for everything crossing to native.

```bash
dart run pigeon --input pigeons/monolens_api.dart
```

The generated Dart, Swift and Kotlin are **committed**, so a consumer never needs pigeon installed.
CI regenerates and fails if the result differs, which is what keeps the three languages honest about the schema.

Formatting the Dart output is part of regenerating, not an afterthought:

```bash
dart run pigeon --input pigeons/monolens_api.dart
dart format lib/src/messages.g.dart
```

Pigeon emits in its own style, and the two checks pull in opposite directions unless both steps run.
pub.dev scores formatting across every Dart file in the published archive, so an unformatted `messages.g.dart` costs 10 points on the analysis score; but a formatted one that CI does not re-format after regenerating fails the drift check on every run, reporting stale bindings when the schema never moved.
Running both leaves the committed file equal to `pigeon + dart format`, which is what each check independently expects.
The Swift and Kotlin output is committed exactly as pigeon writes it -- `dart format` does not touch either, and pub.dev does not score them.

## Adding an operation

1. Add it to `pigeons/monolens_api.dart` and regenerate.
2. Implement it in Swift and Kotlin.
3. Widen `MonolensPlatform`, and `FakeMonolensPlatform` with it.
4. Expose it through `MediaEditor` or `CameraSession` -- callers should not touch the generated API.
5. Test it: a unit test against the fake, and an integration test against the real thing.

Step 3 is not optional.
An operation with no test double is one no host can write a test around, which makes it useless to the people it is for.

If the operation changes pixels, add a pixel-level assertion.
See [why pixels](#why-pixels) below for why dimensions are not enough and for the two traps in writing those assertions.

## Conventions

**Code.**
`flutter_lints`, plus the house habit of explaining *why* in comments rather than restating *what*.
A comment that says what the next line does is noise; one that says why it is that way instead of the obvious alternative is the reason the file is readable a year later.

**Docs.**
One sentence per line, ASCII prose, diagrams as mermaid.
Documents explain *why* a thing is shaped the way it is and *how* to use it; the exact signature of a type belongs in the dartdoc on that type.
The conventions for the published pages -- no frontmatter, the leading `#` heading as the title, numeric filename prefixes, relative cross-links between files -- live in the [site's README](https://github.com/monorithm/monorithm.github.io#writing).

**Commits.**
Conventional commits, enforced by commitlint through a lefthook hook:

```bash
bun install && bun run hooks:install
```

`feat!:` or a `BREAKING CHANGE:` footer for anything that changes the public surface.

## Releasing

1. Update `CHANGELOG.md` -- what changed, and for breaking changes what to do about it.
2. Bump the version in `pubspec.yaml` **and** `ios/monolens.podspec`; they are separate and drift silently.
3. Run the full set above on both platforms.
4. Tag.

## Repository layout

```
lib/                   the public API and the platform seam
pigeons/               the bridge schema
ios/monolens/Sources/  Swift: probe, transform, export, annotations
android/src/main/      Kotlin: the same, plus the blur shader
example/               a complete editor built on the public API
tool/make_fixture.swift generates the integration fixtures
docs/                  the user documentation, published to the site
redirect/              keeps the URL published in 0.4.0 alive
```

The example is not a scratch pad.
It is the reference implementation for [building an editing surface](docs/10-recipes/70-render-the-editing-canvas.md), and it is where the gesture and rendering code lives that a headless plugin deliberately does not ship -- so changes to the API should be reflected there.

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
