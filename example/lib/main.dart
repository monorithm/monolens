// Monokit re-exports `package:flutter/widgets.dart`, so this one import is the
// whole UI layer. Material is not used anywhere in this app, which is the point:
// monolens ships no widgets, so a host is free to bring any design system.
import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

import 'capture_page.dart';
import 'editor/editor_page.dart';
import 'result_page.dart';
import 'ui/lens_chrome.dart';
import 'ui/lens_icons.dart';

/// The cap this demo enforces. A longer clip opens pre-trimmed.
const Duration kMaxClipDuration = Duration(seconds: 15);

void main() => runApp(const MonolensExampleApp());

class MonolensExampleApp extends StatelessWidget {
  const MonolensExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Monokit wires haptics through every pressable but leaves them off until
    // the host asks for them, since a haptic is a product decision rather than
    // a component one. An editor is exactly the case for turning them on: the
    // controls are small, they sit over the picture, and a tap that lands has
    // to be felt as well as seen.
    const haptics = MonokitHaptics(enabled: true);

    return MonokitApp(
      title: 'monolens',
      theme: MonokitThemeData.light().copyWith(haptics: haptics),
      darkTheme: MonokitThemeData.dark().copyWith(haptics: haptics),
      themeMode: MonokitThemeMode.dark,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MediaEditor _editor = MonolensEditor();
  final MediaPicker _picker = SystemMediaPicker();

  String? _error;
  bool _isPicking = false;

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _error = null);
    try {
      await body();
    } on MediaEditException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on TrimCancelled {
      // The author backed out of an export; nothing to report.
    }
  }

  Future<void> _capture(CameraCaptureMode mode) => _run(() async {
    final captured = await Navigator.of(
      context,
    ).push<CapturedMedia>(LensRoute(builder: (_) => CapturePage(mode: mode)));
    if (captured != null && mounted) await _edit(captured);
  });

  Future<void> _pick(CameraCaptureMode kind) => _run(() async {
    // The system picker takes a moment to appear; without this the tile gives
    // no sign that the tap landed.
    setState(() => _isPicking = true);
    try {
      final media = kind == CameraCaptureMode.photo
          ? await _picker.pickImage()
          : await _picker.pickVideo();
      if (media != null && mounted) await _edit(media);
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  });

  Future<void> _edit(CapturedMedia media) async {
    final edited = await Navigator.of(context).push<CapturedMedia>(
      LensRoute(
        builder: (_) => EditorPage(
          media: media,
          editor: _editor,
          maxClipDuration: kMaxClipDuration,
        ),
      ),
    );
    if (edited == null || !mounted) return;
    await Navigator.of(
      context,
    ).push(LensRoute(builder: (_) => ResultPage(media: edited)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    // Centred rather than stacked from the top: there is not enough here to
    // fill a phone, and content crammed under the status bar with a void
    // beneath it reads as unfinished rather than as composed. It still scrolls
    // if the text scale or a short screen needs it to.
    return MonoScreen(
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacing.xl,
            vertical: theme.spacing.xxl,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - theme.spacing.xxl * 2).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Hero(),
                SizedBox(height: theme.spacing.xxxl),
                Row(
                  children: [
                    Expanded(
                      child: _CaptureTile(
                        icon: MonoIcons.image,
                        title: 'Photo',
                        caption: 'Shoot a still',
                        isPrimary: true,
                        onPressed: () => _capture(CameraCaptureMode.photo),
                      ),
                    ),
                    SizedBox(width: theme.spacing.md),
                    Expanded(
                      child: _CaptureTile(
                        icon: MonoIcons.video,
                        title: 'Video',
                        caption: 'Up to ${kMaxClipDuration.inSeconds}s',
                        onPressed: () => _capture(CameraCaptureMode.video),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: theme.spacing.md),
                MonoSurface(
                  padding: EdgeInsets.symmetric(vertical: theme.spacing.xs),
                  child: Column(
                    children: [
                      _ImportRow(
                        icon: MonoIcons.grid,
                        label: 'Import an image',
                        busy: _isPicking,
                        onPressed: () => _pick(CameraCaptureMode.photo),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: theme.spacing.lg,
                        ),
                        child: const MonoSeparator(),
                      ),
                      _ImportRow(
                        icon: MonoIcons.play,
                        label: 'Import a video',
                        busy: _isPicking,
                        onPressed: () => _pick(CameraCaptureMode.video),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: theme.spacing.xxxl),
                Text(
                  'IN THE EDITOR',
                  style: theme.typography.labelMedium.copyWith(
                    color: colors.foregroundSubtle,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: theme.spacing.md),
                const _CapabilityCloud(),
                if (_error != null) ...[
                  SizedBox(height: theme.spacing.xl),
                  MonoAlert(
                    variant: MonoAlertVariant.destructive,
                    title: const Text('Edit failed'),
                    description: Text(_error!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.tint,
                borderRadius: BorderRadius.circular(theme.radii.md),
              ),
              child: Center(
                child: LensIcon(
                  LensGlyph.crop,
                  size: 20,
                  color: colors.canvas,
                  semanticLabel: 'monolens',
                ),
              ),
            ),
            SizedBox(width: theme.spacing.md),
            Text(
              'monolens',
              style: theme.typography.headlineLarge.copyWith(
                color: colors.foreground,
              ),
            ),
            const Spacer(),
            const MonoBadge(
              variant: MonoBadgeVariant.outline,
              size: MonoBadgeSize.sm,
              child: Text('0.3.0'),
            ),
          ],
        ),
        SizedBox(height: theme.spacing.lg),
        Text(
          'Headless capture and on-device editing.\n'
          'Every pixel of this app is host code.',
          style: theme.typography.bodyLarge.copyWith(
            color: colors.foregroundMuted,
          ),
        ),
      ],
    );
  }
}

/// The two ways in. Sized as tiles rather than listed as buttons because these
/// are the screen's subject, not a menu of options.
class _CaptureTile extends StatelessWidget {
  const _CaptureTile({
    required this.icon,
    required this.title,
    required this.caption,
    required this.onPressed,
    this.isPrimary = false,
  });

  final MonoIconData icon;
  final String title;
  final String caption;
  final VoidCallback onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final foreground = isPrimary ? colors.onPrimary : colors.foreground;

    return MonoPressable(
      onPressed: onPressed,
      semanticLabel: title,
      child: (context, states) => AnimatedScale(
        duration: theme.motion.reduced(context, theme.motion.fast),
        curve: theme.motion.standard,
        scale: states.contains(MonoState.pressed) ? 0.97 : 1,
        child: Container(
          height: 148,
          padding: EdgeInsets.all(theme.spacing.lg),
          decoration: BoxDecoration(
            color: isPrimary ? colors.primary : colors.card,
            borderRadius: BorderRadius.circular(theme.radii.xxl),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonoIcon(icon, size: 22, color: foreground),
              const Spacer(),
              Text(
                title,
                style: theme.typography.titleLarge.copyWith(color: foreground),
              ),
              SizedBox(height: theme.spacing.xs),
              Text(
                caption,
                style: theme.typography.bodyMedium.copyWith(
                  color: isPrimary
                      ? colors.onPrimary.withValues(alpha: 0.7)
                      : colors.foregroundMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportRow extends StatelessWidget {
  const _ImportRow({
    required this.icon,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final MonoIconData icon;
  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return MonoPressable(
      onPressed: busy ? null : onPressed,
      enabled: !busy,
      semanticLabel: label,
      child: (context, states) => Container(
        color: states.contains(MonoState.pressed) ? colors.fill : null,
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacing.lg,
          vertical: theme.spacing.md + 2,
        ),
        child: Row(
          children: [
            MonoIcon(icon, size: 18, color: colors.foregroundMuted),
            SizedBox(width: theme.spacing.md),
            Expanded(
              child: Text(
                label,
                style: theme.typography.bodyLarge.copyWith(
                  color: colors.foreground,
                ),
              ),
            ),
            if (busy)
              const MonoSpinner(size: 16)
            else
              MonoIcon(
                MonoIcons.chevronRight,
                size: 16,
                color: colors.foregroundSubtle,
              ),
          ],
        ),
      ),
    );
  }
}

/// What the editor can do, stated once so the front door is not silent about
/// the actual surface area.
class _CapabilityCloud extends StatelessWidget {
  const _CapabilityCloud();

  static const List<(LensGlyph, String)> _items = [
    (LensGlyph.crop, 'Crop'),
    (LensGlyph.rotate, 'Rotate'),
    (LensGlyph.flip, 'Flip'),
    (LensGlyph.blur, 'Blur'),
    (LensGlyph.text, 'Text'),
    (LensGlyph.emoji, 'Emoji'),
    (LensGlyph.sticker, 'Stickers'),
    (LensGlyph.pen, 'Draw'),
    (LensGlyph.soundOff, 'Mute'),
    (LensGlyph.undo, 'Undo'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return Wrap(
      spacing: theme.spacing.sm,
      runSpacing: theme.spacing.sm,
      children: [
        for (final (glyph, label) in _items)
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: theme.spacing.md,
              vertical: theme.spacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.fill,
              borderRadius: BorderRadius.circular(theme.radii.full),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LensIcon(glyph, size: 15, color: colors.foregroundMuted),
                SizedBox(width: theme.spacing.sm - 2),
                Text(
                  label,
                  style: theme.typography.labelMedium.copyWith(
                    color: colors.foregroundMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
