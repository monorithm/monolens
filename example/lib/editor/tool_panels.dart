import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

import '../ui/lens_icons.dart';
import 'editor_controller.dart';
import 'stickers.dart';

/// A line of guidance with an optional action, shared by the trays that have
/// nothing to configure until something is selected.
class ToolHint extends StatelessWidget {
  const ToolHint({required this.text, super.key, this.action});

  final String text;
  final ToolAction? action;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final action = this.action;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: theme.typography.bodyMedium.copyWith(
                  color: theme.colors.foregroundMuted,
                ),
              ),
            ),
            if (action != null) ...[
              SizedBox(width: theme.spacing.md),
              MonoButton(
                size: MonoButtonSize.sm,
                variant: action.isDestructive
                    ? MonoButtonVariant.destructive
                    : MonoButtonVariant.secondary,
                onPressed: action.onPressed,
                child: Text(action.label),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

@immutable
class ToolAction {
  const ToolAction({
    required this.label,
    required this.onPressed,
    this.glyph,
    this.isDestructive = false,
  });

  final String label;
  final VoidCallback onPressed;
  final LensGlyph? glyph;
  final bool isDestructive;
}

/// The palette every colour-bearing tool shares.
class ColorStrip extends StatelessWidget {
  const ColorStrip({required this.value, required this.onChanged, super.key});

  final int value;
  final ValueChanged<int> onChanged;

  static const List<int> swatches = [
    0xFFFFFFFF,
    0xFF111111,
    0xFF10B981,
    0xFF3E63DD,
    0xFFE5484D,
    0xFFFFC53D,
    0xFFEC4899,
    0xFF8B5CF6,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
        itemCount: swatches.length,
        separatorBuilder: (_, _) => SizedBox(width: theme.spacing.md),
        itemBuilder: (context, index) {
          final swatch = swatches[index];
          final selected = swatch == value;
          return MonoPressable(
            onPressed: () => onChanged(swatch),
            semanticLabel: 'Colour ${index + 1}',
            child: (context, states) => Center(
              child: AnimatedContainer(
                duration: theme.motion.reduced(context, theme.motion.base),
                curve: theme.motion.monoOut,
                width: 30,
                height: 30,
                padding: EdgeInsets.all(selected ? 3 : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // A ring set off from the swatch, rather than a thicker
                  // border: white-on-white needs the gap to read at all.
                  border: Border.all(
                    color: selected
                        ? theme.colors.tint
                        : theme.colors.separator,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(swatch),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Composes a caption and drops it onto the canvas.
class TextComposer extends StatefulWidget {
  const TextComposer({required this.controller, super.key});

  final EditorController controller;

  @override
  State<TextComposer> createState() => _TextComposerState();
}

class _TextComposerState extends State<TextComposer> {
  final TextEditingController _field = TextEditingController();
  bool _plate = true;

  @override
  void initState() {
    super.initState();
    // Editing the selection rather than always creating: tapping a caption then
    // the text tool should change that caption.
    final selected = widget.controller.selected;
    if (selected is TextAnnotation) {
      _field.text = selected.text;
      _plate = selected.backgroundArgb != null;
    }
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _field.text.trim();
    if (text.isEmpty) return;

    final selected = widget.controller.selected;
    final background = _plate ? 0x99000000 : null;
    if (selected is TextAnnotation) {
      widget.controller.update(
        selected.copyWith(
          text: text,
          colorArgb: widget.controller.color,
          backgroundArgb: background,
        ),
      );
    } else {
      widget.controller.add(
        TextAnnotation(
          text: text,
          center: const Offset(0.5, 0.5),
          colorArgb: widget.controller.color,
          backgroundArgb: background,
        ),
      );
    }
    _field.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final isEditing = widget.controller.selected is TextAnnotation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColorStrip(
          value: widget.controller.color,
          onChanged: widget.controller.setColor,
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.spacing.lg,
            theme.spacing.md,
            theme.spacing.lg,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: MonoInput(
                  controller: _field,
                  placeholder: 'Add a caption',
                  autofocus: true,
                  onSubmitted: (_) => _commit(),
                ),
              ),
              SizedBox(width: theme.spacing.sm),
              MonoButton(
                onPressed: _commit,
                child: Text(isEditing ? 'Update' : 'Add'),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.spacing.lg,
            theme.spacing.md,
            theme.spacing.lg,
            0,
          ),
          child: MonoSwitch(
            value: _plate,
            label: const Text('Plate behind text'),
            onChanged: (value) => setState(() => _plate = value),
          ),
        ),
      ],
    );
  }
}

/// Emoji are text, so this picker produces a [TextAnnotation] like any other.
/// There is no emoji asset table to keep current — the platform already shapes
/// the glyph.
class EmojiGrid extends StatelessWidget {
  const EmojiGrid({required this.controller, super.key});

  final EditorController controller;

  static const List<String> emoji = [
    '😀',
    '😍',
    '🤣',
    '🔥',
    '🎉',
    '💯',
    '👀',
    '👏',
    '❤️',
    '⭐',
    '✨',
    '🙌',
    '😎',
    '🥳',
    '💡',
    '🚀',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return SizedBox(
      height: 108,
      child: GridView.count(
        crossAxisCount: 8,
        padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
        children: [
          for (final glyph in emoji)
            MonoPressable(
              onPressed: () => controller.add(
                AnnotationFactories.emoji(
                  glyph,
                  center: const Offset(0.5, 0.5),
                ),
              ),
              semanticLabel: 'Add $glyph',
              child: (context, states) => AnimatedScale(
                duration: theme.motion.reduced(context, theme.motion.fast),
                curve: theme.motion.standard,
                scale: states.contains(MonoState.pressed) ? 0.82 : 1,
                child: Center(
                  child: Text(glyph, style: const TextStyle(fontSize: 27)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The sticker sheet. Stickers are files, so these are painted and written to
/// the cache on first use rather than shipped as assets.
class StickerGrid extends StatefulWidget {
  const StickerGrid({required this.controller, super.key});

  final EditorController controller;

  @override
  State<StickerGrid> createState() => _StickerGridState();
}

class _StickerGridState extends State<StickerGrid> {
  StickerSheet? _sheet;

  @override
  void initState() {
    super.initState();
    StickerSheet.load().then((sheet) {
      if (!mounted) return;
      setState(() => _sheet = sheet);

      // Arm the tool with the first sticker. Without this the sticker tool is
      // the one tool whose canvas taps do nothing until the sheet has been
      // touched — a dead tap with no feedback, which reads as a broken editor
      // rather than as a missing choice.
      if (widget.controller.stickerPath == null && sheet.stickers.isNotEmpty) {
        widget.controller.setStickerPath(sheet.stickers.first.path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final sheet = _sheet;
    if (sheet == null) {
      return const SizedBox(height: 96, child: Center(child: MonoSpinner()));
    }

    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
        itemCount: sheet.stickers.length,
        separatorBuilder: (_, _) => SizedBox(width: theme.spacing.md),
        itemBuilder: (context, index) {
          final sticker = sheet.stickers[index];
          final armed = widget.controller.stickerPath == sticker.path;
          return MonoPressable(
            onPressed: () {
              widget.controller.setStickerPath(sticker.path);
              widget.controller.add(
                StickerAnnotation(
                  imagePath: sticker.path,
                  rect: widget.controller.squareAt(const Offset(0.5, 0.5)),
                ),
              );
            },
            semanticLabel: 'Add sticker ${index + 1}',
            child: (context, states) => AnimatedScale(
              duration: theme.motion.reduced(context, theme.motion.fast),
              curve: theme.motion.standard,
              scale: states.contains(MonoState.pressed) ? 0.92 : 1,
              child: AnimatedContainer(
                duration: theme.motion.reduced(context, theme.motion.base),
                curve: theme.motion.standard,
                width: 76,
                padding: EdgeInsets.all(theme.spacing.md),
                decoration: BoxDecoration(
                  color: theme.colors.fill,
                  borderRadius: BorderRadius.circular(theme.radii.xl),
                  // The armed sticker is the one a tap on the picture will
                  // place, so it has to be visible which that is.
                  border: Border.all(
                    color: armed ? theme.colors.tint : const Color(0x00000000),
                    width: 1.5,
                  ),
                ),
                child: Center(child: sticker.preview()),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Shape and strength for the selected blur, or for the next one placed.
class BlurControls extends StatelessWidget {
  const BlurControls({required this.controller, super.key});

  final EditorController controller;

  static const List<(String, double)> _strengths = [
    ('Light', 0.25),
    ('Medium', 0.5),
    ('Heavy', 0.85),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final selected = controller.selected;
    final blur = selected is BlurAnnotation ? selected : null;

    if (blur == null) {
      return const ToolHint(text: 'Tap the picture to place a blur over it.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
          child: Row(
            children: [
              _Segmented(
                options: [
                  for (final (label, shape) in const [
                    ('Oval', BlurShape.oval),
                    ('Rectangle', BlurShape.rectangle),
                  ])
                    _SegmentOption(
                      label: label,
                      isSelected: blur.shape == shape,
                      onPressed: () =>
                          controller.update(blur.copyWith(shape: shape)),
                    ),
                ],
              ),
              const Spacer(),
              MonoButton.icon(
                size: MonoButtonSize.sm,
                variant: MonoButtonVariant.ghost,
                icon: LensIcon(
                  LensGlyph.trash,
                  size: 17,
                  color: theme.colors.danger,
                ),
                semanticLabel: 'Remove blur',
                onPressed: () => controller.remove(blur.id),
              ),
            ],
          ),
        ),
        SizedBox(height: theme.spacing.md),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: theme.spacing.lg),
          child: Row(
            children: [
              Text(
                'Strength',
                style: theme.typography.labelMedium.copyWith(
                  color: theme.colors.foregroundMuted,
                ),
              ),
              SizedBox(width: theme.spacing.md),
              Expanded(
                child: _Segmented(
                  options: [
                    for (final (label, strength) in _strengths)
                      _SegmentOption(
                        label: label,
                        // The nearest step, so an annotation carrying some
                        // other value still shows a selection.
                        isSelected: _nearest(blur.strength) == strength,
                        onPressed: () => controller.update(
                          blur.copyWith(strength: strength),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static double _nearest(double value) {
    var best = _strengths.first.$2;
    for (final (_, strength) in _strengths) {
      if ((strength - value).abs() < (best - value).abs()) best = strength;
    }
    return best;
  }
}

/// Colour and weight for the pen.
class StrokeControls extends StatelessWidget {
  const StrokeControls({required this.controller, super.key});

  final EditorController controller;

  static const List<double> widths = [0.006, 0.012, 0.022, 0.04];

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColorStrip(value: controller.color, onChanged: controller.setColor),
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.spacing.lg,
            theme.spacing.md,
            theme.spacing.lg,
            0,
          ),
          child: Row(
            children: [
              for (final width in widths)
                Padding(
                  padding: EdgeInsets.only(right: theme.spacing.md),
                  child: MonoPressable(
                    onPressed: () => controller.setStrokeWidth(width),
                    semanticLabel: 'Line weight',
                    child: (context, states) => AnimatedContainer(
                      duration: theme.motion.reduced(
                        context,
                        theme.motion.base,
                      ),
                      curve: theme.motion.standard,
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: controller.strokeWidth == width
                            ? theme.colors.fill
                            : null,
                        borderRadius: BorderRadius.circular(theme.radii.lg),
                        border: Border.all(
                          color: controller.strokeWidth == width
                              ? theme.colors.tint
                              : const Color(0x00000000),
                        ),
                      ),
                      // The dot is the line's actual weight against the frame's
                      // short side, so the choice is made by eye rather than by
                      // reading a number.
                      child: Container(
                        width: width * 700,
                        height: width * 700,
                        decoration: BoxDecoration(
                          color: Color(controller.color),
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.colors.separator),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A compact segmented control, for the two- and three-way choices inside a
/// tray where a row of buttons would carry more weight than the choice does.
class _Segmented extends StatelessWidget {
  const _Segmented({required this.options});

  final List<_SegmentOption> options;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colors.fill,
        borderRadius: BorderRadius.circular(theme.radii.lg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in options)
            MonoPressable(
              onPressed: option.onPressed,
              semanticLabel: option.label,
              child: (context, states) => AnimatedContainer(
                duration: theme.motion.reduced(context, theme.motion.base),
                curve: theme.motion.standard,
                padding: EdgeInsets.symmetric(
                  horizontal: theme.spacing.md,
                  vertical: theme.spacing.sm - 1,
                ),
                decoration: BoxDecoration(
                  color: option.isSelected ? theme.colors.elevated : null,
                  borderRadius: BorderRadius.circular(theme.radii.md),
                ),
                child: Text(
                  option.label,
                  style: theme.typography.labelMedium.copyWith(
                    color: option.isSelected
                        ? theme.colors.foreground
                        : theme.colors.foregroundMuted,
                    fontWeight: option.isSelected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

@immutable
class _SegmentOption {
  const _SegmentOption({
    required this.label,
    required this.isSelected,
    required this.onPressed,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onPressed;
}
