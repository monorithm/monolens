/// @docImport 'edit_specs.dart';
library;

import 'package:flutter/foundation.dart';

/// Undo/redo over a value.
///
/// Undo is cheap here because an edit is already a *value*, not a command log:
/// there is nothing to invert and nothing to replay, so a history is just the
/// previous values. That is the payoff for [ImageEdit] and [VideoEdit] being
/// declarative — a mutable canvas would have needed an inverse for every
/// operation, and blur has no inverse.
///
/// Implements [ValueListenable] rather than exposing a Flutter-specific
/// controller, so it binds to any UI library: `ValueListenableBuilder`, a bloc,
/// a signal, or a plain listener.
class EditHistory<T> extends ChangeNotifier implements ValueListenable<T> {
  EditHistory(this._value, {this.limit = 50}) : _initial = _value;

  /// How many steps back are kept. A crop drag can generate hundreds of
  /// intermediate values, and past a certain depth nobody is going back.
  final int limit;

  final T _initial;
  final List<T> _past = [];
  final List<T> _future = [];

  T _value;
  Object? _openKey;

  @override
  T get value => _value;

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// How many steps back are available, for a host that shows a count.
  int get depth => _past.length;

  /// Records [next] as the current value.
  ///
  /// Pass a [coalesceKey] for continuous gestures: consecutive pushes sharing a
  /// key collapse into one history entry, so dragging a sticker across the
  /// frame is a single undo rather than four hundred. Call [commit] when the
  /// gesture ends, or push with a different key.
  void push(T next, {Object? coalesceKey}) {
    if (next == _value) return;

    final coalescing =
        coalesceKey != null && coalesceKey == _openKey && _past.isNotEmpty;
    if (!coalescing) {
      _past.add(_value);
      if (_past.length > limit) _past.removeAt(0);
    }

    _openKey = coalesceKey;
    // A new edit invalidates anything that was undone past it.
    _future.clear();
    _value = next;
    notifyListeners();
  }

  /// Ends a coalescing run, so the next push starts a fresh entry. Call from a
  /// gesture's end handler.
  void commit() => _openKey = null;

  void undo() {
    if (_past.isEmpty) return;
    _future.add(_value);
    _value = _past.removeLast();
    _openKey = null;
    notifyListeners();
  }

  void redo() {
    if (_future.isEmpty) return;
    _past.add(_value);
    _value = _future.removeLast();
    _openKey = null;
    notifyListeners();
  }

  /// Back to the value this started from, in one undoable step.
  void reset() => push(_initial);

  /// Drops the history without changing the current value — after an export,
  /// say, where going back would no longer match what was written.
  void clearHistory() {
    if (_past.isEmpty && _future.isEmpty) return;
    _past.clear();
    _future.clear();
    _openKey = null;
    notifyListeners();
  }
}
