import 'dart:io' show Platform;

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';

import 'ui/lens_chrome.dart';
import 'ui/lens_icons.dart';

/// The viewfinder — built here, not by monolens.
///
/// This is the whole headless contract in practice: the session hands back a
/// texture id and the geometry to orient it, and the app draws whatever chrome
/// it likes around a plain `Texture`. Everything below the preview — the
/// shutter, the cap countdown, the permission state — is host code, and none of
/// it had to be negotiated with the plugin.
class CapturePage extends StatefulWidget {
  const CapturePage({
    required this.mode,
    super.key,
    this.maxDuration = const Duration(seconds: 15),
  });

  final CameraCaptureMode mode;

  /// The cap the shutter enforces, and what the countdown arc is drawn against.
  ///
  /// A parameter rather than a constant reached out of `main.dart`: a page that
  /// imports the app's entry point to find one number cannot be pumped on its
  /// own, which is exactly what a test of this chrome has to do.
  final Duration maxDuration;

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  final CameraSession _session = MonolensCameraSession();

  CameraAccess? _access;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The session drops this flag on its own at the cap; that is the cue to
    // collect the file without a second tap.
    _session.isRecording.addListener(_onRecordingChanged);
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session.isRecording.removeListener(_onRecordingChanged);
    _session.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Holding a camera in the background is a fast way to get killed by the OS.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _session.pausePreview();
    } else if (state == AppLifecycleState.resumed) {
      _session.resumePreview();
    }
  }

  Future<void> _open() async {
    final access = await _session.initialize(widget.mode);
    if (mounted) setState(() => _access = access);
  }

  void _onRecordingChanged() {
    if (!_session.isRecording.value && !_isBusy) {
      _finish();
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _trigger() async {
    if (_isBusy) return;
    if (widget.mode == CameraCaptureMode.photo) {
      setState(() => _isBusy = true);
      final photo = await _session.capturePhoto();
      if (mounted) Navigator.of(context).pop(photo);
      return;
    }
    if (_session.isRecording.value) {
      await _finish();
    } else {
      await _session.startVideoRecording(maxDuration: widget.maxDuration);
      if (mounted) setState(() {});
    }
  }

  Future<void> _finish() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    final clip = await _session.stopVideoRecording();
    if (mounted) Navigator.of(context).pop(clip);
  }

  bool get _isDenied => _access != null && _access != CameraAccess.granted;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return MonoScreen(
      background: theme.colors.canvas,
      // The preview owns the full pane; only the chrome insets itself.
      safeArea: const MonoSafeArea.none(),
      body: ValueListenableBuilder<Duration>(
        valueListenable: _session.recordedDuration,
        builder: (context, recorded, _) {
          final isRecording = _session.isRecording.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              Center(child: _preview()),
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LensScrim(height: 160),
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: LensScrim(fromTop: false, height: 220),
              ),
              SafeArea(
                child: Column(
                  children: [
                    _topBar(isRecording, recorded),
                    const Spacer(),
                    if (!_isDenied) _captureBar(isRecording, recorded),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _preview() {
    if (_isDenied) return _accessState();

    final preview = _session.preview;
    // Test for a null preview rather than a falsy id: zero is a valid texture
    // id, and an iPhone reports exactly that for its first session.
    if (preview == null) return const MonoSpinner();

    Widget texture = Texture(textureId: preview.textureId);

    // iOS delivers frames already oriented; Android streams them in sensor
    // orientation, so the host turns them. A production app would also fold in
    // the current device orientation — this example is portrait-only.
    if (Platform.isAndroid && preview.sensorOrientation % 360 != 0) {
      texture = RotatedBox(
        quarterTurns: (preview.sensorOrientation ~/ 90) % 4,
        child: texture,
      );
    }

    // Mirroring the front lens is a presentation choice, so it lives here too.
    if (preview.facing == CameraFacing.front) {
      texture = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: texture,
      );
    }

    return AspectRatio(aspectRatio: preview.aspectRatio, child: texture);
  }

  /// A denial is a state worth designing, not a sentence in the middle of a
  /// black screen — it is the one screen a first run is most likely to hit.
  Widget _accessState() {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    final (title, detail) = switch (_access!) {
      CameraAccess.denied => (
        'Camera access is off',
        'This app asked and was declined. Nothing else here needs the camera.',
      ),
      CameraAccess.permanentlyDenied => (
        'Camera access is off',
        'Turn it back on in Settings to shoot from here. Importing still works.',
      ),
      CameraAccess.unavailable => (
        'No camera available',
        'The device has none, or another app is holding it.',
      ),
      CameraAccess.granted => ('', ''),
    };

    return Padding(
      padding: EdgeInsets.all(theme.spacing.xxl),
      child: MonoMediaChrome(
        padding: EdgeInsets.all(theme.spacing.xxl),
        radius: BorderRadius.circular(theme.radii.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A camera body, not the switch-camera arrows: this state is about
            // there being no camera, not about changing which one.
            MonoIcon(MonoIcons.video, size: 28, color: colors.onMediaMuted),
            SizedBox(height: theme.spacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.typography.mediaTitle.copyWith(
                color: colors.onMedia,
              ),
            ),
            SizedBox(height: theme.spacing.sm),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.typography.mediaCaption.copyWith(
                color: colors.onMediaMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(bool isRecording, Duration recorded) {
    final theme = MonokitTheme.of(context);

    return Padding(
      padding: EdgeInsets.all(theme.spacing.lg),
      child: Row(
        children: [
          LensChromeButton(
            semanticLabel: 'Close',
            onPressed: isRecording ? null : () => Navigator.of(context).pop(),
            child: MonoIcon(
              MonoIcons.close,
              size: 18,
              color: theme.colors.onMedia,
            ),
          ),
          const Spacer(),
          if (isRecording)
            _RecordingPill(elapsed: recorded, cap: widget.maxDuration)
          else
            _ModePill(mode: widget.mode),
          const Spacer(),
          LensChromeButton(
            semanticLabel: 'Flash: ${_session.flash.name}',
            isActive: _session.flash != CameraFlash.off,
            onPressed: _isDenied
                ? null
                : () async {
                    await _session.cycleFlash();
                    if (mounted) setState(() {});
                  },
            child: LensIcon(
              switch (_session.flash) {
                CameraFlash.off => LensGlyph.flashOff,
                CameraFlash.auto => LensGlyph.flashAuto,
                CameraFlash.on => LensGlyph.flashOn,
              },
              size: 19,
              color: lensChromeForeground(
                context,
                isActive: _session.flash != CameraFlash.off,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _captureBar(bool isRecording, Duration recorded) {
    final theme = MonokitTheme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.spacing.xxxl,
        theme.spacing.lg,
        theme.spacing.xxxl,
        theme.spacing.xxxl,
      ),
      child: MonoCaptureBar(
        // Nothing on the left, but the bar still reserves the width so the
        // shutter stays on the screen's centre line rather than drifting.
        leading: const SizedBox(width: 44),
        shutter: LensShutter(
          isRecording: isRecording,
          progress: widget.maxDuration.inMilliseconds == 0
              ? 0
              : recorded.inMilliseconds / widget.maxDuration.inMilliseconds,
          onPressed: _isBusy ? null : _trigger,
        ),
        trailing: LensChromeButton(
          semanticLabel: 'Switch camera',
          // Flipping mid-take would splice two different lenses into one file.
          onPressed: isRecording || _isBusy
              ? null
              : () async {
                  await _session.flip();
                  if (mounted) setState(() {});
                },
          child: LensIcon(
            LensGlyph.cameraFlip,
            size: 20,
            color: theme.colors.onMedia,
          ),
        ),
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({required this.mode});

  final CameraCaptureMode mode;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacing.md,
        vertical: theme.spacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: theme.colors.mistFill,
        border: Border.all(color: theme.colors.mistLine),
        borderRadius: BorderRadius.circular(theme.radii.full),
      ),
      child: LensLabel(
        mode == CameraCaptureMode.photo ? 'Photo' : 'Video',
        color: theme.colors.onMedia,
      ),
    );
  }
}

/// Elapsed against the cap, with the live dot the system reserves for exactly
/// this: a state, not decoration.
class _RecordingPill extends StatelessWidget {
  const _RecordingPill({required this.elapsed, required this.cap});

  final Duration elapsed;
  final Duration cap;

  static String _clock(Duration value) {
    final seconds = value.inSeconds % 60;
    return '${value.inMinutes}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacing.md,
        vertical: theme.spacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: theme.colors.mistFill,
        border: Border.all(color: theme.colors.mistLine),
        borderRadius: BorderRadius.circular(theme.radii.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: theme.colors.live,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: theme.spacing.sm),
          Text(
            '${_clock(elapsed)} / ${_clock(cap)}',
            style: theme.typography.labelMedium.copyWith(
              color: theme.colors.onMedia,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
