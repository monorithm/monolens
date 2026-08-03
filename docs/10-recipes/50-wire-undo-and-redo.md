# Wire undo and redo

Undo is a stack of previous values.
There is nothing to invert and nothing to replay, which matters because blur has no inverse -- see [architecture](../20-concepts/90-architecture.md#undo).

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

`EditHistory` is generic, so the same control drives a still and a clip.

## Coalesce a drag into one step

A crop gesture emits hundreds of values, and going back should undo the gesture rather than one sample of it.

Push with a `coalesceKey` for the duration of the gesture, then `commit()` when it ends:

```dart
void onCropUpdate(CropRect rect) =>
    history.push(history.value.copyWith(crop: rect), coalesceKey: 'crop-drag');

void onCropEnd(_) => history.commit();
```

Forgetting `commit()` is the bug to look for: the next unrelated push with the same key would join the previous run.

## Bind it to your UI

`EditHistory` implements `ValueListenable`, so it binds to a `ValueListenableBuilder`, a bloc, a signal or a plain listener -- it is not tied to one state-management choice:

```dart
ValueListenableBuilder<ImageEdit>(
  valueListenable: history,
  builder: (context, edit, _) => Preview(edit: edit),
)
```
