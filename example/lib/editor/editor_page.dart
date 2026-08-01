import 'dart:io';

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';
import 'package:video_player/video_player.dart';

import '../ui/lens_chrome.dart';
import '../ui/lens_icons.dart';
import 'crop_overlay.dart';
import 'editor_controller.dart';
import 'editor_draft.dart';
import 'media_canvas.dart';
import 'tool_panels.dart';
import 'trim_bar.dart';

/// The editor.
///
/// One screen for stills and clips alike: the canvas shows the export, one rail
/// chooses the active tool, and every control writes through the same undo
/// stack. That the two media types share this at all is a property of the API —
/// an edit is a value, and both kinds of value carry a crop, a rotation and
/// annotations.
///
/// The rail is deliberately flat. Mode and tool are two concepts in the
/// controller because crop changes what the canvas *shows* and nothing else
/// does, but that distinction is the controller's business: to the author there
/// is one row of tools, and cropping is one of them.
class EditorPage extends StatefulWidget {
  const EditorPage({
    required this.media,
    required this.editor,
    this.maxClipDuration,
    super.key,
  });

  final CapturedMedia media;
  final MediaEditor editor;
  final Duration? maxClipDuration;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

/// One entry on the rail, mapped onto the controller's mode/tool pair.
enum _Tool {
  move,
  crop,
  trim,
  text,
  emoji,
  sticker,
  blur,
  draw;

  String get label => switch (this) {
    _Tool.move => 'Move',
    _Tool.crop => 'Crop',
    _Tool.trim => 'Trim',
    _Tool.text => 'Text',
    _Tool.emoji => 'Emoji',
    _Tool.sticker => 'Sticker',
    _Tool.blur => 'Blur',
    _Tool.draw => 'Draw',
  };

  LensGlyph get glyph => switch (this) {
    _Tool.move => LensGlyph.move,
    _Tool.crop => LensGlyph.crop,
    _Tool.trim => LensGlyph.trim,
    _Tool.text => LensGlyph.text,
    _Tool.emoji => LensGlyph.emoji,
    _Tool.sticker => LensGlyph.sticker,
    _Tool.blur => LensGlyph.blur,
    _Tool.draw => LensGlyph.pen,
  };

  EditorMode get mode => switch (this) {
    _Tool.crop => EditorMode.crop,
    _Tool.trim => EditorMode.trim,
    _ => EditorMode.annotate,
  };

  EditorTool get tool => switch (this) {
    _Tool.text => EditorTool.text,
    _Tool.emoji => EditorTool.emoji,
    _Tool.sticker => EditorTool.sticker,
    _Tool.blur => EditorTool.blur,
    _Tool.draw => EditorTool.draw,
    _ => EditorTool.select,
  };
}

class _EditorPageState extends State<EditorPage> {
  /// The floating header's height: a 44pt control plus its padding.
  static const double _headerExtent = 60;

  late final EditorController _controller;
  VideoPlayerController? _player;
  double? _aspectLock;
  bool _isExporting = false;
  bool _wasPlaying = false;

  /// Derived, never stored.
  ///
  /// The controller moves the tool on its own — placing an annotation switches
  /// to select so the thing just added can be dragged — and a rail holding its
  /// own copy of the selection would go on highlighting Sticker while taps on
  /// the picture had stopped placing stickers.
  _Tool get _active => switch (_controller.mode) {
    EditorMode.crop => _Tool.crop,
    EditorMode.trim => _Tool.trim,
    EditorMode.annotate => switch (_controller.tool) {
      EditorTool.select => _Tool.move,
      EditorTool.text => _Tool.text,
      EditorTool.emoji => _Tool.emoji,
      EditorTool.sticker => _Tool.sticker,
      EditorTool.blur => _Tool.blur,
      EditorTool.draw => _Tool.draw,
    },
  };

  CapturedVideo? get _video =>
      widget.media is CapturedVideo ? widget.media as CapturedVideo : null;

  @override
  void initState() {
    super.initState();
    final clip = _video;
    _controller = EditorController(
      source: widget.media,
      editor: widget.editor,
      maxClipDuration: widget.maxClipDuration,
      initial: clip == null
          ? const ImageDraft(ImageEdit.none)
          : VideoDraft(_initialVideoEdit(clip), sourceDuration: clip.duration),
    );

    if (clip != null) {
      _player = VideoPlayerController.file(File(clip.path))
        ..initialize().then((_) {
          if (mounted) setState(() {});
        })
        ..setLooping(true)
        ..addListener(_onPlayerTick);
      _controller.loadFilmstrip();
    }
  }

  /// Keeps playback inside the cut, and the trim playhead on the playback.
  ///
  /// Previewing is for seeing what the export will be, so it loops the trimmed
  /// range rather than the whole source — otherwise the one thing the preview
  /// is for is the one thing it does not show.
  void _onPlayerTick() {
    final player = _player;
    if (player == null || !player.value.isInitialized) return;

    final draft = _controller.draft;
    final playing = player.value.isPlaying;

    if (playing && draft is VideoDraft) {
      final trim = draft.edit.trim;
      final at = player.value.position;
      if (at >= trim.end ||
          at < trim.start - const Duration(milliseconds: 60)) {
        player.seekTo(trim.start);
      } else {
        _controller.setPlayhead(at);
      }
    }

    // Only when it actually flips: the player notifies on every frame, and
    // rebuilding the whole editor that often for an icon that did not change
    // is wasted work.
    if (playing != _wasPlaying) {
      _wasPlaying = playing;
      if (mounted) setState(() {});
    }
  }

  Future<void> _togglePlayback() async {
    final player = _player;
    final draft = _controller.draft;
    if (player == null || !player.value.isInitialized) return;

    if (player.value.isPlaying) {
      await player.pause();
    } else {
      if (draft is VideoDraft) {
        final trim = draft.edit.trim;
        final at = player.value.position;
        // Resume where it was left, unless that is outside the cut.
        if (at < trim.start || at >= trim.end) await player.seekTo(trim.start);
      }
      await player.play();
    }
    if (mounted) setState(() {});
  }

  VideoEdit _initialVideoEdit(CapturedVideo clip) {
    final full = VideoEdit.full(clip.duration);
    final cap = widget.maxClipDuration;
    // Over the cap opens pre-trimmed rather than opening invalid.
    if (cap != null && full.duration > cap) {
      return full.copyWith(
        trim: VideoTrim(start: Duration.zero, end: cap),
      );
    }
    return full;
  }

  @override
  void dispose() {
    _player?.removeListener(_onPlayerTick);
    _player?.dispose();
    _controller.dispose();
    super.dispose();
  }

  double get _sourceAspect => widget.media.aspectRatio;

  List<_Tool> get _tools => [
    _Tool.move,
    _Tool.crop,
    if (_video != null) _Tool.trim,
    _Tool.text,
    _Tool.emoji,
    _Tool.sticker,
    _Tool.blur,
    _Tool.draw,
  ];

  void _select(_Tool tool) {
    _controller.setMode(tool.mode);
    _controller.setTool(tool.tool);
  }

  Future<void> _done() async {
    setState(() => _isExporting = true);
    final result = await _controller.export();
    if (!mounted) return;
    setState(() => _isExporting = false);
    if (result != null) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return MonoScreen(
      background: theme.colors.canvas,
      // The media owns its whole pane, edge to edge; the chrome insets itself.
      safeArea: const MonoSafeArea.none(),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _canvas(),
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LensScrim(height: 150),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(bottom: false, child: _header()),
                  ),
                  // Playback belongs to the whole editor, not to the trim tool.
                  // Checking a caption against the moving picture is the most
                  // ordinary thing an author does, and burying it one tool away
                  // makes it a chore.
                  if (_video != null)
                    Positioned(
                      right: theme.spacing.lg,
                      bottom: theme.spacing.lg,
                      child: _playButton(),
                    ),
                  if (_controller.job != null)
                    Positioned.fill(child: _exportOverlay()),
                ],
              ),
            ),
            _chrome(),
          ],
        ),
      ),
    );
  }

  // The media

  Widget _canvas() {
    final media = _video == null
        ? Image.file(File(widget.media.path), fit: BoxFit.fill)
        : (_player?.value.isInitialized ?? false)
        ? VideoPlayer(_player!)
        : const SizedBox.shrink();

    return Padding(
      // The header floats over this pane, so centring against the raw pane
      // would sit the media under it and leave the slack below. Insetting by
      // the header's own height centres it in the space actually free.
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + _headerExtent,
        bottom: 12,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: MediaCanvas(
              controller: _controller,
              media: media,
              sourceAspectRatio: _sourceAspect,
            ),
          ),
          if (_controller.mode == EditorMode.crop)
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: _sourceAspect,
                  child: CropOverlay(
                    crop: _controller.draft.crop,
                    aspectRatio: _aspectLock,
                    sourceAspectRatio: _sourceAspect,
                    onChanged: (crop) => _controller.push(
                      _controller.draft.withCrop(crop),
                      coalesceKey: 'crop',
                    ),
                    onCommit: _controller.endGesture,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playButton() {
    final theme = MonokitTheme.of(context);
    final ready = _player?.value.isInitialized ?? false;
    final playing = _player?.value.isPlaying ?? false;

    return LensChromeButton(
      semanticLabel: playing ? 'Pause' : 'Play',
      onPressed: ready ? _togglePlayback : null,
      child: MonoIcon(
        playing ? MonoIcons.pause : MonoIcons.play,
        size: 18,
        color: theme.colors.onMedia,
      ),
    );
  }

  // Floating chrome

  Widget _header() {
    final theme = MonokitTheme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacing.md,
        vertical: theme.spacing.sm,
      ),
      child: Row(
        children: [
          LensChromeButton(
            semanticLabel: 'Discard',
            onPressed: () => Navigator.of(context).pop(),
            child: MonoIcon(
              MonoIcons.close,
              size: 18,
              color: theme.colors.onMedia,
            ),
          ),
          const Spacer(),
          LensChromeButton(
            semanticLabel: 'Undo',
            diameter: 40,
            onPressed: _controller.history.canUndo ? _controller.undo : null,
            child: LensIcon(
              LensGlyph.undo,
              size: 18,
              color: theme.colors.onMedia,
            ),
          ),
          SizedBox(width: theme.spacing.sm),
          LensChromeButton(
            semanticLabel: 'Redo',
            diameter: 40,
            onPressed: _controller.history.canRedo ? _controller.redo : null,
            child: LensIcon(
              LensGlyph.redo,
              size: 18,
              color: theme.colors.onMedia,
            ),
          ),
          SizedBox(width: theme.spacing.md),
          MonoButton(
            isLoading: _isExporting,
            size: MonoButtonSize.sm,
            onPressed: _isExporting ? null : _done,
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _exportOverlay() {
    final theme = MonokitTheme.of(context);
    final percent = (_controller.progress * 100).round();

    return MonoScrim(
      strong: true,
      child: Center(
        child: MonoSurface(
          role: MonoSurfaceRole.elevated,
          elevation: MonoElevation.floating,
          padding: EdgeInsets.all(theme.spacing.xl),
          radius: BorderRadius.circular(theme.radii.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Exporting',
                style: theme.typography.titleMedium.copyWith(
                  color: theme.colors.foreground,
                ),
              ),
              SizedBox(height: theme.spacing.xs),
              Text(
                '$percent%',
                style: theme.typography.labelMedium.copyWith(
                  color: theme.colors.foregroundMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              SizedBox(height: theme.spacing.lg),
              SizedBox(
                width: 200,
                child: MonoProgress(value: _controller.progress),
              ),
              SizedBox(height: theme.spacing.md),
              MonoButton(
                size: MonoButtonSize.sm,
                variant: MonoButtonVariant.ghost,
                onPressed: _controller.cancelExport,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // The tool surface

  Widget _chrome() {
    final theme = MonokitTheme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colors.page,
        border: Border(top: BorderSide(color: theme.colors.separator)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_controller.error != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  theme.spacing.lg,
                  theme.spacing.md,
                  theme.spacing.lg,
                  0,
                ),
                child: MonoAlert(
                  variant: MonoAlertVariant.destructive,
                  title: const Text('Export failed'),
                  description: Text(_controller.error!),
                ),
              ),
            LensTray(slot: _active, child: _tray()),
            LensRail<_Tool>(
              items: [
                for (final tool in _tools)
                  LensRailItem(
                    value: tool,
                    label: tool.label,
                    icon: (color) =>
                        LensIcon(tool.glyph, size: 21, color: color),
                  ),
              ],
              value: _active,
              onChanged: _select,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tray() {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: MonokitTheme.of(context).spacing.md,
      ),
      child: switch (_active) {
        _Tool.move => _movePanel(),
        _Tool.crop => _cropPanel(),
        _Tool.trim => _trimPanel(),
        _Tool.text => TextComposer(
          key: ValueKey(_controller.selectedId ?? 'new'),
          controller: _controller,
        ),
        _Tool.emoji => EmojiGrid(controller: _controller),
        _Tool.sticker => StickerGrid(controller: _controller),
        _Tool.blur => BlurControls(controller: _controller),
        _Tool.draw => StrokeControls(controller: _controller),
      },
    );
  }

  Widget _movePanel() {
    final selected = _controller.selected;
    return ToolHint(
      text: selected == null
          ? 'Tap anything on the picture to select it.'
          : 'Drag to move. The corner handle scales and rotates.',
      action: selected == null
          ? (_controller.draft.annotations.isEmpty
                ? null
                : ToolAction(
                    label: 'Clear all',
                    onPressed: _controller.clearAnnotations,
                  ))
          : ToolAction(
              label: 'Delete',
              glyph: LensGlyph.trash,
              isDestructive: true,
              onPressed: () => _controller.remove(selected.id),
            ),
    );
  }

  Widget _cropPanel() {
    const ratios = <(String, double?)>[
      ('Free', null),
      ('1:1', 1),
      ('4:5', 4 / 5),
      ('16:9', 16 / 9),
      ('9:16', 9 / 16),
    ];
    final theme = MonokitTheme.of(context);

    return Column(
      children: [
        SizedBox(
          height: 58,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
            children: [
              for (final (label, ratio) in ratios)
                Padding(
                  padding: EdgeInsets.only(right: theme.spacing.sm),
                  child: _RatioChip(
                    label: label,
                    aspectRatio: ratio,
                    isSelected: _aspectLock == ratio,
                    onPressed: () {
                      setState(() => _aspectLock = ratio);
                      if (ratio != null) {
                        _controller.push(
                          _controller.draft.withCrop(
                            CropRect.centered(
                              aspectRatio: ratio,
                              sourceAspectRatio: _sourceAspect,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        SizedBox(height: theme.spacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _TrayAction(
              glyph: LensGlyph.rotate,
              label: 'Rotate',
              onPressed: () =>
                  _controller.push(_controller.draft.rotatedClockwise()),
            ),
            SizedBox(width: theme.spacing.xxl),
            _TrayAction(
              glyph: LensGlyph.flip,
              label: 'Flip',
              isActive: _controller.draft.flipHorizontal,
              onPressed: () =>
                  _controller.push(_controller.draft.toggledFlip()),
            ),
            SizedBox(width: theme.spacing.xxl),
            _TrayAction(
              glyph: LensGlyph.crop,
              label: 'Reset',
              onPressed: () {
                setState(() => _aspectLock = null);
                _controller.push(
                  _controller.draft.withCrop(const CropRect.full()),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _trimPanel() {
    final draft = _controller.draft;
    if (draft is! VideoDraft) return const SizedBox.shrink();
    final theme = MonokitTheme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
      child: Column(
        children: [
          TrimBar(
            frames: _controller.filmstrip,
            trim: draft.edit.trim,
            sourceDuration: draft.sourceDuration,
            playhead: _controller.playhead,
            maxDuration: widget.maxClipDuration,
            onTrimChanged: (trim, {required anchorStart}) =>
                _controller.setTrim(trim, anchorStart: anchorStart),
            onScrub: (at) {
              _controller.setPlayhead(at, scrubbing: true);
              _player?.seekTo(at);
            },
            onCommit: _controller.endGesture,
          ),
          SizedBox(height: theme.spacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // No play control here: the floating one sits directly above this
              // tray and is available in every tool, so a second copy would
              // only be a second thing to keep in sync.
              _TrayAction(
                glyph: draft.edit.muteAudio
                    ? LensGlyph.soundOff
                    : LensGlyph.soundOn,
                label: draft.edit.muteAudio ? 'Muted' : 'Sound',
                isActive: draft.edit.muteAudio,
                onPressed: () => _controller.push(draft.toggledMute()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A crop preset, showing the shape rather than only naming it.
class _RatioChip extends StatelessWidget {
  const _RatioChip({
    required this.label,
    required this.aspectRatio,
    required this.isSelected,
    required this.onPressed,
  });

  final String label;
  final double? aspectRatio;
  final bool isSelected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final foreground = isSelected ? colors.tint : colors.foregroundMuted;

    return MonoPressable(
      onPressed: onPressed,
      semanticLabel: label,
      child: (context, states) => AnimatedContainer(
        duration: theme.motion.reduced(context, theme.motion.base),
        curve: theme.motion.standard,
        width: 58,
        decoration: BoxDecoration(
          color: isSelected ? colors.primarySoft : colors.fill,
          borderRadius: BorderRadius.circular(theme.radii.lg),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LensRatioGlyph(
              aspectRatio: aspectRatio,
              color: foreground,
              size: 22,
            ),
            SizedBox(height: theme.spacing.xs),
            Text(
              label,
              style: theme.typography.labelMedium.copyWith(
                color: foreground,
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled action inside a tray.
class _TrayAction extends StatelessWidget {
  const _TrayAction({
    required this.label,
    required this.onPressed,
    this.glyph,
    this.icon,
    this.isActive = false,
  }) : assert(glyph != null || icon != null);

  final String label;
  final VoidCallback onPressed;
  final LensGlyph? glyph;
  final MonoIconData? icon;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final foreground = isActive ? colors.canvas : colors.foreground;

    return MonoPressable(
      onPressed: onPressed,
      semanticLabel: label,
      child: (context, states) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedScale(
            duration: theme.motion.reduced(context, theme.motion.fast),
            curve: theme.motion.standard,
            scale: states.contains(MonoState.pressed) ? 0.9 : 1,
            child: AnimatedContainer(
              duration: theme.motion.reduced(context, theme.motion.base),
              curve: theme.motion.standard,
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: isActive ? colors.tint : colors.fill,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: glyph != null
                    ? LensIcon(glyph!, size: 21, color: foreground)
                    : MonoIcon(icon!, size: 20, color: foreground),
              ),
            ),
          ),
          SizedBox(height: theme.spacing.sm - 2),
          Text(
            label,
            style: theme.typography.labelMedium.copyWith(
              color: colors.foregroundMuted,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}
