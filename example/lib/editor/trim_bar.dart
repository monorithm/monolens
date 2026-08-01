import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

/// A filmstrip with draggable in and out points.
///
/// The strip comes from `MediaEditor.filmstrip` as plain JPEG bytes; the
/// handles, the scrim and the playhead are the host's. Scrubbing seeks the
/// preview, which is the only way to pick an in-point by eye.
class TrimBar extends StatefulWidget {
  const TrimBar({
    required this.frames,
    required this.trim,
    required this.sourceDuration,
    required this.playhead,
    required this.onTrimChanged,
    required this.onScrub,
    required this.onCommit,
    this.maxDuration,
    super.key,
  });

  final List<Uint8List> frames;
  final VideoTrim trim;
  final Duration sourceDuration;
  final Duration playhead;

  /// Fired with the new range and which handle moved, so the caller can hold
  /// the other one when a cap is hit.
  final void Function(VideoTrim trim, {required bool anchorStart})
  onTrimChanged;
  final ValueChanged<Duration> onScrub;
  final VoidCallback onCommit;
  final Duration? maxDuration;

  @override
  State<TrimBar> createState() => _TrimBarState();
}

class _TrimBarState extends State<TrimBar> {
  _Target? _target;

  static const double _handleWidth = 16;
  static const double _height = 64;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final selected = widget.trim.duration;
    final capped =
        widget.maxDuration != null && selected >= widget.maxDuration!;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${(selected.inMilliseconds / 1000).toStringAsFixed(1)}s',
                style: theme.typography.labelLarge.copyWith(
                  color: theme.colors.foreground,
                  fontWeight: FontWeight.w600,
                  // Without this the number's width changes as it counts, and
                  // the whole row twitches under the dragging finger.
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                ' of ${(widget.sourceDuration.inMilliseconds / 1000).toStringAsFixed(1)}s',
                style: theme.typography.labelLarge.copyWith(
                  color: theme.colors.foregroundMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (capped) ...[
                SizedBox(width: theme.spacing.sm),
                const MonoBadge(
                  variant: MonoBadgeVariant.warning,
                  size: MonoBadgeSize.sm,
                  child: Text('Max'),
                ),
              ],
            ],
          ),
        ),
        SizedBox(
          height: _height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => _start(d.localPosition.dx, width),
                onPanUpdate: (d) => _update(d.localPosition.dx, width),
                onPanEnd: (_) {
                  widget.onCommit();
                  setState(() => _target = null);
                },
                onTapDown: (d) =>
                    widget.onScrub(_at(d.localPosition.dx, width)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(theme.radii.md),
                      child: ColoredBox(
                        color: theme.colors.fill,
                        child: widget.frames.isEmpty
                            ? const SizedBox.expand()
                            : Row(
                                children: [
                                  for (final frame in widget.frames)
                                    Expanded(
                                      child: Image.memory(
                                        frame,
                                        fit: BoxFit.cover,
                                        height: _height,
                                        // The strip is a scrubbing aid, not
                                        // content; fading it in on rebuild
                                        // reads as flicker.
                                        gaplessPlayback: true,
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ),
                    CustomPaint(
                      painter: _TrimPainter(
                        trim: widget.trim,
                        sourceDuration: widget.sourceDuration,
                        playhead: widget.playhead,
                        // The bright accent, not `primary`: the handles sit on
                        // photographic frames, where the dark theme's deep
                        // primary would disappear into them.
                        accent: theme.colors.tint,
                        onAccent: theme.colors.canvas,
                        playheadColor: theme.colors.onMedia,
                        scrim: theme.colors.scrimStrong,
                        radius: Radius.circular(theme.radii.md),
                        handleWidth: _handleWidth,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Duration _at(double dx, double width) => Duration(
    milliseconds:
        (dx.clamp(0.0, width) /
                (width == 0 ? 1 : width) *
                widget.sourceDuration.inMilliseconds)
            .round(),
  );

  double _x(Duration at, double width) {
    final total = widget.sourceDuration.inMilliseconds;
    return total == 0 ? 0 : at.inMilliseconds / total * width;
  }

  void _start(double dx, double width) {
    final startX = _x(widget.trim.start, width);
    final endX = _x(widget.trim.end, width);

    final _Target target;
    if ((dx - startX).abs() <= 28 && (dx - startX).abs() <= (dx - endX).abs()) {
      target = _Target.start;
    } else if ((dx - endX).abs() <= 28) {
      target = _Target.end;
    } else {
      target = _Target.playhead;
    }
    setState(() => _target = target);
    _update(dx, width);
  }

  void _update(double dx, double width) {
    final at = _at(dx, width);
    switch (_target) {
      case _Target.start:
        // Moving the in-point pushes the out-point when they collide.
        widget.onTrimChanged(
          widget.trim.copyWith(start: at),
          anchorStart: false,
        );
        widget.onScrub(at);
      case _Target.end:
        widget.onTrimChanged(widget.trim.copyWith(end: at), anchorStart: true);
        widget.onScrub(at);
      case _Target.playhead:
      case null:
        widget.onScrub(at);
    }
  }
}

enum _Target { start, end, playhead }

class _TrimPainter extends CustomPainter {
  const _TrimPainter({
    required this.trim,
    required this.sourceDuration,
    required this.playhead,
    required this.accent,
    required this.onAccent,
    required this.playheadColor,
    required this.scrim,
    required this.radius,
    required this.handleWidth,
  });

  final VideoTrim trim;
  final Duration sourceDuration;
  final Duration playhead;
  final Color accent;
  final Color onAccent;
  final Color playheadColor;
  final Color scrim;
  final Radius radius;
  final double handleWidth;

  double _x(Duration at, double width) {
    final total = sourceDuration.inMilliseconds;
    return total == 0
        ? 0
        : (at.inMilliseconds / total * width).clamp(0.0, width);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final startX = _x(trim.start, size.width);
    final endX = _x(trim.end, size.width);
    final cutAway = Paint()..color = scrim;

    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(0, 0, startX, size.height),
        topLeft: radius,
        bottomLeft: radius,
      ),
      cutAway,
    );
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(endX, 0, size.width, size.height),
        topRight: radius,
        bottomRight: radius,
      ),
      cutAway,
    );

    // Rails along the top and bottom of the selection, plus the two grab bars.
    final chrome = Paint()..color = accent;
    final rail = math.min(3.0, size.height / 16);
    canvas.drawRect(Rect.fromLTRB(startX, 0, endX, rail), chrome);
    canvas.drawRect(
      Rect.fromLTRB(startX, size.height - rail, endX, size.height),
      chrome,
    );

    for (final (x, isStart) in [(startX, true), (endX, false)]) {
      // Inside the selection, not flanking it. Flanking overhangs the paint
      // bounds, and at full range that puts the grab bars outside the widget
      // entirely -- they bleed into whatever padding happens to be there, or
      // get clipped by whatever does not.
      final bar = RRect.fromRectAndCorners(
        Rect.fromLTWH(
          isStart ? x : x - handleWidth,
          0,
          handleWidth,
          size.height,
        ),
        topLeft: isStart ? radius : Radius.zero,
        bottomLeft: isStart ? radius : Radius.zero,
        topRight: isStart ? Radius.zero : radius,
        bottomRight: isStart ? Radius.zero : radius,
      );
      canvas.drawRRect(bar, chrome);

      // A grip line, so the bar reads as draggable rather than as a border.
      canvas.drawLine(
        Offset(bar.center.dx, size.height * 0.34),
        Offset(bar.center.dx, size.height * 0.66),
        Paint()
          ..color = onAccent
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round,
      );
    }

    // Held inside the strip by its own half-width, so it stays a full line at
    // either extreme rather than a half-clipped one.
    final head = _x(
      playhead,
      size.width,
    ).clamp(startX, endX).clamp(1.25, math.max(1.25, size.width - 1.25));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(head - 1.25, 2, 2.5, size.height - 4),
        const Radius.circular(2),
      ),
      Paint()..color = playheadColor,
    );
  }

  @override
  bool shouldRepaint(_TrimPainter old) =>
      old.trim != trim ||
      old.playhead != playhead ||
      old.sourceDuration != sourceDuration ||
      old.accent != accent;
}
