# monolens example

A complete editor built on monolens — the reference implementation for
[building an editor](https://github.com/monorithm/monolens/blob/main/docs/building-an-editor.md).

Because monolens is headless, everything here is host code: the viewfinder, the
shutter, the gesture layer, the crop handles, the filmstrip scrubber and the
tool rail are all built in this app, against
[monokit](https://github.com/monorithm/monokit). No widget crosses the plugin
boundary, so bringing your own design system changes none of the shape below.

```bash
cd example
flutter run
```

## What it shows

| | |
|---|---|
| **Capture** | A viewfinder drawn from a texture id, a shutter with the cap as a countdown arc, flash cycling, and a designed permission-denied state. |
| **Crop** | Direct manipulation with aspect presets, a thirds grid while dragging, rotate and flip. |
| **Trim** | A filmstrip from `MediaEditor.filmstrip`, draggable in and out points, and a playhead that tracks playback. |
| **Annotate** | Text, emoji, stickers, blur regions and freehand lines — placed, dragged, pinched, turned and deleted. |
| **Undo** | One `EditHistory` behind every control, with drags coalesced into single steps. |

## Worth reading

| File | Why |
|---|---|
| `lib/editor/editor_draft.dart` | One sealed type over `ImageEdit` and `VideoEdit`, so the editor is written once instead of twice. |
| `lib/editor/media_canvas.dart` | The gesture layer: hit-testing against oriented boxes, pinch and twist, and the transform maths. |
| `lib/editor/editor_controller.dart` | All editor state in one place, so "what can be undone" has exactly one answer. |
| `lib/ui/lens_icons.dart` | The editing glyphs, drawn rather than borrowed from a general icon set. |

## Fixtures

The integration suite needs generated fixtures. They are produced rather than
committed, so the repository carries no binaries:

```bash
swift tool/make_fixture.swift
```

Then, on a device, simulator or emulator:

```bash
cd example && flutter test integration_test
```

Camera tests skip where there is no camera; everything else runs anywhere.
