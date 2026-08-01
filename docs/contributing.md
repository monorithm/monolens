# Contributing

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
See [testing](/monolens/guides/testing/#why-pixels) for why dimensions are not enough and for the two traps in writing those assertions.

## Conventions

**Code.**
`flutter_lints`, plus the house habit of explaining *why* in comments rather than restating *what*.
A comment that says what the next line does is noise; one that says why it is that way instead of the obvious alternative is the reason the file is readable a year later.

**Docs.**
One sentence per line, ASCII prose, diagrams as mermaid.
Documents in `docs/` explain why a thing is shaped the way it is and how to use it; exact signatures belong in the dartdoc on the type.

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
docs/                  contributor notes -- this file
website/               the user documentation site
```

The example is not a scratch pad.
It is the reference implementation for [building an editor](/monolens/guides/building-an-editor/), and it is where the gesture and rendering code lives that a headless plugin deliberately does not ship -- so changes to the API should be reflected there.
