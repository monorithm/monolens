/// Chrome for surfaces that sit *on* media.
///
/// Monokit carries a whole media register — `canvas`, `onMedia`, `mistFill`,
/// `mistLine`, `live`, `mediaTitle` — that exists precisely because chrome over
/// photography cannot follow the app theme: it has to stay legible over a white
/// sky and a black shadow in the same frame. These are the few compositions
/// this app needs on top of that register, kept here so the screens stay about
/// behaviour rather than about decoration.
library;

import 'dart:math' as math;

import 'package:monokit/monokit.dart';

/// A round control for use over media.
///
/// Deliberately not a [MonoButton]: a button is sized and coloured for a page,
/// and over a photograph it needs the mist pair and a circular target instead.
class LensChromeButton extends StatelessWidget {
  const LensChromeButton({
    required this.child,
    required this.onPressed,
    super.key,
    this.semanticLabel,
    this.isActive = false,
    this.tone = LensTone.neutral,
    this.diameter = 44,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  /// Filled rather than misted — the state is on, not merely available.
  final bool isActive;
  final LensTone tone;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final enabled = onPressed != null;

    final accent = switch (tone) {
      LensTone.neutral => colors.onMedia,
      LensTone.accent => colors.tint,
      LensTone.live => colors.live,
    };

    return MonoPressable(
      onPressed: onPressed,
      enabled: enabled,
      semanticLabel: semanticLabel,
      child: (context, states) {
        final pressed = states.contains(MonoState.pressed);
        return AnimatedContainer(
          duration: theme.motion.reduced(context, theme.motion.fast),
          curve: theme.motion.standard,
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? accent
                : (pressed ? colors.mistLine : colors.mistFill),
            border: Border.all(color: isActive ? accent : colors.mistLine),
          ),
          child: Center(
            child: Opacity(
              // Disabled has to read over arbitrary photography, where a
              // muted foreground colour would not reliably.
              opacity: enabled ? 1 : 0.35,
              child: DefaultTextStyle(
                style: theme.typography.labelMedium.copyWith(
                  color: isActive ? colors.canvas : colors.onMedia,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

enum LensTone { neutral, accent, live }

/// The colour a glyph should take inside a [LensChromeButton].
Color lensChromeForeground(BuildContext context, {required bool isActive}) {
  final colors = MonokitTheme.of(context).colors;
  return isActive ? colors.canvas : colors.onMedia;
}

/// A gradient that buys legibility for chrome floating over media.
///
/// A flat scrim would dim the picture uniformly; this only pays where the
/// controls actually are.
class LensScrim extends StatelessWidget {
  const LensScrim({super.key, this.fromTop = true, this.height = 140});

  final bool fromTop;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scrim = MonokitTheme.of(context).colors.scrim;
    return IgnorePointer(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
              end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [scrim, const Color(0x00000000)],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small tracked label, for section headings inside chrome.
class LensLabel extends StatelessWidget {
  const LensLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.typography.labelMedium.copyWith(
        color: color ?? theme.colors.onMediaMuted,
        fontSize: 10,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// One entry in a [LensRail].
@immutable
class LensRailItem<T> {
  const LensRailItem({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;

  /// Built with the colour the rail resolved for this item's state, so a glyph
  /// can invert on selection without the rail knowing how it is drawn.
  final Widget Function(Color color) icon;
}

/// The tool rail: a segmented control with a pill that slides between entries.
///
/// A row of filled-versus-ghost buttons communicates the same state, but the
/// selection appears to teleport. Moving one pill is what makes a toolbar feel
/// like a single control rather than a handful of adjacent ones.
class LensRail<T> extends StatefulWidget {
  const LensRail({
    required this.items,
    required this.value,
    required this.onChanged,
    super.key,
    this.itemExtent = 68,
    this.height = 62,
  });

  final List<LensRailItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double itemExtent;
  final double height;

  @override
  State<LensRail<T>> createState() => _LensRailState<T>();
}

class _LensRailState<T> extends State<LensRail<T>> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(LensRail<T> old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Keeps the selection on screen when the rail is wider than the viewport —
  /// otherwise picking the last tool scrolls it under the edge.
  void _reveal() {
    if (!_scroll.hasClients || !mounted) return;
    final index = widget.items.indexWhere((item) => item.value == widget.value);
    if (index < 0) return;

    final viewport = _scroll.position.viewportDimension;
    final target =
        (index * widget.itemExtent + widget.itemExtent / 2 - viewport / 2)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 1) return;

    final motion = MonokitTheme.of(context).motion;
    final duration = motion.reduced(context, motion.moderate);
    if (duration == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: duration, curve: motion.monoOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final index = math.max(
      0,
      widget.items.indexWhere((item) => item.value == widget.value),
    );
    final total = widget.items.length * widget.itemExtent;

    final content = SizedBox(
      width: total,
      height: widget.height,
      child: Stack(
        children: [
          AnimatedPositioned(
            duration: theme.motion.reduced(context, theme.motion.moderate),
            curve: theme.motion.monoOut,
            left: index * widget.itemExtent + 4,
            top: 0,
            width: widget.itemExtent - 8,
            height: widget.height,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colors.mistFill,
                border: Border.all(color: theme.colors.mistLine),
                borderRadius: BorderRadius.circular(theme.radii.xl),
              ),
            ),
          ),
          Row(
            children: [
              for (final item in widget.items)
                _RailEntry<T>(
                  item: item,
                  isSelected: item.value == widget.value,
                  extent: widget.itemExtent,
                  onPressed: () => widget.onChanged(item.value),
                ),
            ],
          ),
        ],
      ),
    );

    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Centred while it fits, scrollable once it does not. A rail that is
          // always scrollable looks off-centre for the common case.
          if (total <= constraints.maxWidth) {
            return Center(child: content);
          }
          return ListView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            // Breathing room at both ends, so the selection pill never sits
            // flush against the screen edge.
            padding: EdgeInsets.symmetric(horizontal: theme.spacing.sm),
            children: [content],
          );
        },
      ),
    );
  }
}

class _RailEntry<T> extends StatelessWidget {
  const _RailEntry({
    required this.item,
    required this.isSelected,
    required this.extent,
    required this.onPressed,
  });

  final LensRailItem<T> item;
  final bool isSelected;
  final double extent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final color = isSelected ? theme.colors.tint : theme.colors.onMediaMuted;

    return MonoPressable(
      onPressed: onPressed,
      semanticLabel: item.label,
      child: (context, states) => SizedBox(
        width: extent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              duration: theme.motion.reduced(context, theme.motion.fast),
              curve: theme.motion.standard,
              scale: states.contains(MonoState.pressed) ? 0.88 : 1,
              child: item.icon(color),
            ),
            SizedBox(height: theme.spacing.xs + 2),
            AnimatedDefaultTextStyle(
              duration: theme.motion.reduced(context, theme.motion.moderate),
              curve: theme.motion.standard,
              style: theme.typography.labelMedium.copyWith(
                color: color,
                fontSize: 10.5,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.2,
              ),
              child: Text(item.label),
            ),
          ],
        ),
      ),
    );
  }
}

/// The panel above the rail, holding whatever the active tool needs.
///
/// Height is driven by the content and animated, and the content itself
/// cross-fades. Switching tools should feel like one surface changing its mind,
/// not like two panels swapping places.
class LensTray extends StatelessWidget {
  const LensTray({required this.slot, required this.child, super.key});

  /// Identifies the content, so the switcher knows a real change from a
  /// rebuild of the same panel.
  final Object slot;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final motion = MonokitTheme.of(context).motion;
    return AnimatedSize(
      duration: motion.reduced(context, motion.moderate),
      curve: motion.monoOut,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: AnimatedSwitcher(
        duration: motion.reduced(context, motion.base),
        switchInCurve: motion.decelerate,
        switchOutCurve: motion.accelerate,
        // Sized by the incoming child alone; letting the switcher stack both
        // would make the tray jump to the taller of the two mid-transition.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [
            for (final child in previous)
              Positioned(left: 0, right: 0, top: 0, child: child),
            ?current,
          ],
        ),
        child: KeyedSubtree(key: ValueKey(slot), child: child),
      ),
    );
  }
}

/// The capture button: a ring, a morphing core, and the cap drawn as an arc.
///
/// The arc matters more than it looks. The session stops itself at the cap, so
/// without a visible countdown the recording appears to end on its own.
class LensShutter extends StatelessWidget {
  const LensShutter({
    required this.isRecording,
    required this.onPressed,
    super.key,
    this.progress = 0,
    this.diameter = 76,
  });

  final bool isRecording;
  final VoidCallback? onPressed;

  /// Elapsed fraction of the cap, 0 when not recording.
  final double progress;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return MonoPressable(
      onPressed: onPressed,
      enabled: onPressed != null,
      semanticLabel: isRecording ? 'Stop recording' : 'Capture',
      child: (context, states) => AnimatedScale(
        duration: theme.motion.reduced(context, theme.motion.fast),
        curve: theme.motion.standard,
        scale: states.contains(MonoState.pressed) ? 0.93 : 1,
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: CustomPaint(
            painter: _ShutterRingPainter(
              track: colors.mistLine,
              progressColor: colors.live,
              progress: isRecording ? progress.clamp(0.0, 1.0) : 0,
            ),
            child: Center(
              child: AnimatedContainer(
                duration: theme.motion.reduced(context, theme.motion.base),
                curve: theme.motion.monoOut,
                width: isRecording ? diameter * 0.34 : diameter * 0.78,
                height: isRecording ? diameter * 0.34 : diameter * 0.78,
                decoration: BoxDecoration(
                  color: isRecording ? colors.live : colors.onMedia,
                  borderRadius: BorderRadius.circular(
                    isRecording ? theme.radii.sm : diameter,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterRingPainter extends CustomPainter {
  const _ShutterRingPainter({
    required this.track,
    required this.progressColor,
    required this.progress,
  });

  final Color track;
  final Color progressColor;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2 - 2;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      progress * 2 * math.pi,
      false,
      Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ShutterRingPainter old) =>
      old.progress != progress ||
      old.track != track ||
      old.progressColor != progressColor;
}

/// A labelled value, for reading an export's numbers back.
class LensStat extends StatelessWidget {
  const LensStat({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.typography.labelMedium.copyWith(
            color: theme.colors.foregroundSubtle,
            fontSize: 10,
            letterSpacing: 1,
            fontWeight: FontWeight.w600,
          ),
        ),
        SizedBox(height: theme.spacing.xs),
        Text(
          value,
          style: theme.typography.titleMedium.copyWith(
            color: theme.colors.foreground,
          ),
        ),
      ],
    );
  }
}

/// A route that arrives instead of appearing.
///
/// `PageRouteBuilder` with no `transitionsBuilder` cuts straight to the new
/// screen, which is the single cheapest-looking thing an app can do.
class LensRoute<T> extends PageRouteBuilder<T> {
  LensRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) {
          if (MonokitMotion.noAnimation(context)) return child;
          final motion = MonokitTheme.of(context).motion;

          final enter = CurvedAnimation(
            parent: animation,
            curve: motion.monoOut,
            reverseCurve: motion.accelerate,
          );
          // The outgoing screen settles back rather than sliding off, so the
          // two read as depth instead of as a carousel.
          final exit = CurvedAnimation(
            parent: secondary,
            curve: motion.standard,
          );

          return FadeTransition(
            opacity: enter,
            child: ScaleTransition(
              scale: Tween<double>(begin: 1.03, end: 1).animate(enter),
              child: ScaleTransition(
                scale: Tween<double>(begin: 1, end: 0.97).animate(exit),
                child: child,
              ),
            ),
          );
        },
      );
}
