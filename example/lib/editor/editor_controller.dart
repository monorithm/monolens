import 'dart:typed_data';

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

import 'editor_draft.dart';

/// Which surface the canvas is currently in.
///
/// Crop is a *mode* rather than a tool because it changes what the canvas
/// shows — the full frame with an overlay, instead of the cropped result — and
/// nothing else does that.
enum EditorMode { annotate, crop, trim }

/// What a tap on the canvas creates while in [EditorMode.annotate].
enum EditorTool { select, text, emoji, sticker, blur, draw }

/// All editor state in one place.
///
/// The undo stack lives here rather than in a widget so that every control —
/// the toolbar, the canvas, a sheet — pushes through the same door, and so
/// "what can be undone" has exactly one answer.
class EditorController extends ChangeNotifier {
  EditorController({
    required this.source,
    required this.editor,
    required EditorDraft initial,
    this.maxClipDuration,
  }) : history = EditHistory(initial);

  final CapturedMedia source;
  final MediaEditor editor;
  final EditHistory<EditorDraft> history;
  final Duration? maxClipDuration;

  EditorDraft get draft => history.value;
  bool get isVideo => source is CapturedVideo;

  EditorMode _mode = EditorMode.annotate;
  EditorTool _tool = EditorTool.select;
  String? _selectedId;
  int _color = 0xFFFFFFFF;
  double _strokeWidth = 0.012;
  String? _stickerPath;

  List<Uint8List> _filmstrip = const [];
  Duration _playhead = Duration.zero;
  bool _isScrubbing = false;

  TrimJob? _job;
  double _progress = 0;
  String? _error;

  EditorMode get mode => _mode;
  EditorTool get tool => _tool;
  String? get selectedId => _selectedId;
  int get color => _color;
  double get strokeWidth => _strokeWidth;
  String? get stickerPath => _stickerPath;
  List<Uint8List> get filmstrip => _filmstrip;
  Duration get playhead => _playhead;
  bool get isScrubbing => _isScrubbing;
  TrimJob? get job => _job;
  double get progress => _progress;
  String? get error => _error;

  Annotation? get selected =>
      _selectedId == null ? null : draft.annotations.byId(_selectedId!);

  /// A rect that is square *in pixels*, centred on [centre].
  ///
  /// A normalized rect with equal width and height is only square on a square
  /// frame; on a 9:16 clip it is markedly taller than it is wide. That matters
  /// because both platforms stretch a sticker to fill its rect, so a
  /// "square-looking" normalized rect would export a distorted sticker while
  /// the preview looked fine — the preview-versus-export mismatch this whole
  /// coordinate system exists to avoid.
  CropRect squareAt(Offset centre, {double fraction = 0.28}) {
    final aspect = draft.outputAspectRatio(source.aspectRatio);
    final width = aspect >= 1 ? fraction / aspect : fraction;
    final height = aspect >= 1 ? fraction : fraction * aspect;
    return CropRect(
      left: (centre.dx - width / 2).clamp(0.0, 1 - width),
      top: (centre.dy - height / 2).clamp(0.0, 1 - height),
      width: width,
      height: height,
    );
  }

  void setMode(EditorMode value) {
    if (_mode == value) return;
    _mode = value;
    // Leaving annotate drops the selection: its handles would sit over a
    // surface that no longer responds to them.
    if (value != EditorMode.annotate) _selectedId = null;
    notifyListeners();
  }

  void setTool(EditorTool value) {
    _tool = value;
    if (value != EditorTool.select) _selectedId = null;
    notifyListeners();
  }

  void select(String? id) {
    if (_selectedId == id) return;
    _selectedId = id;
    notifyListeners();
  }

  void setColor(int value) {
    _color = value;
    // Recolour the selection rather than only the next thing drawn — otherwise
    // picking a colour with something selected appears to do nothing.
    final current = selected;
    final recoloured = switch (current) {
      TextAnnotation() => current.copyWith(colorArgb: value),
      StrokeAnnotation() => current.copyWith(colorArgb: value),
      _ => null,
    };
    if (recoloured != null) {
      update(recoloured);
    } else {
      notifyListeners();
    }
  }

  void setStrokeWidth(double value) {
    _strokeWidth = value;
    final current = selected;
    if (current is StrokeAnnotation) {
      update(current.copyWith(widthFraction: value));
    } else {
      notifyListeners();
    }
  }

  void setStickerPath(String? value) {
    _stickerPath = value;
    notifyListeners();
  }

  // Draft mutation — everything routes through here so undo stays truthful.

  void push(EditorDraft next, {Object? coalesceKey}) {
    history.push(next, coalesceKey: coalesceKey);
    notifyListeners();
  }

  void add(Annotation annotation) {
    push(draft.withAnnotations([...draft.annotations, annotation]));
    _selectedId = annotation.id;
    _tool = EditorTool.select;
    notifyListeners();
  }

  /// Replaces an annotation in place. [coalesceKey] collapses a drag into one
  /// undo step.
  void update(Annotation annotation, {Object? coalesceKey}) {
    push(
      draft.withAnnotations(draft.annotations.replacing(annotation)),
      coalesceKey: coalesceKey,
    );
  }

  void remove(String id) {
    push(draft.withAnnotations(draft.annotations.removing(id)));
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  void clearAnnotations() {
    push(draft.withAnnotations(const []));
    _selectedId = null;
    notifyListeners();
  }

  void endGesture() => history.commit();

  void undo() {
    history.undo();
    _selectedId = null;
    notifyListeners();
  }

  void redo() {
    history.redo();
    _selectedId = null;
    notifyListeners();
  }

  // Trim

  void setTrim(VideoTrim trim, {required bool anchorStart}) {
    final current = draft;
    if (current is! VideoDraft) return;
    push(
      current.withTrim(
        trim.clamped(
          current.sourceDuration,
          maximum: maxClipDuration,
          anchorStart: anchorStart,
        ),
      ),
      coalesceKey: anchorStart ? 'trim.end' : 'trim.start',
    );
  }

  void setPlayhead(Duration value, {bool scrubbing = false}) {
    _playhead = value;
    _isScrubbing = scrubbing;
    notifyListeners();
  }

  Future<void> loadFilmstrip() async {
    final media = source;
    if (media is! CapturedVideo) return;
    try {
      _filmstrip = await editor.filmstrip(
        media.path,
        duration: media.duration,
        frames: 12,
        maxDimension: 160,
      );
      notifyListeners();
    } on MediaEditException {
      // The strip is a scrubbing aid, not the feature.
    }
  }

  // Export

  /// Returns the exported media, or null when the author cancelled.
  Future<CapturedMedia?> export() async {
    _error = null;
    final current = draft;

    // Nothing changed: hand back the original rather than paying for an encode.
    if (current.isUntouched) return source;

    try {
      if (current is ImageDraft) {
        return await editor.applyImageEdit(source.path, current.edit);
      }
      if (current is VideoDraft) {
        final job = editor.startTrim(source.path, current.edit);
        _job = job;
        _progress = 0;
        notifyListeners();
        job.progress.listen((value) {
          _progress = value;
          notifyListeners();
        });
        return await job.result;
      }
    } on TrimCancelled {
      return null;
    } on MediaEditException catch (failure) {
      _error = failure.message;
    } finally {
      _job = null;
      notifyListeners();
    }
    return null;
  }

  void cancelExport() => _job?.cancel();

  @override
  void dispose() {
    _job?.cancel();
    history.dispose();
    super.dispose();
  }
}
