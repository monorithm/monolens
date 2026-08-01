import 'dart:async';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../media/captured_media.dart';
import '../platform/monolens_platform.dart';
import 'camera_contract.dart';

/// The `camera`-plugin [CameraSession].
///
/// Owns exactly one [CameraController] at a time and rebuilds it whenever the
/// lens or the capture mode changes — the plugin has no way to add an audio
/// track or swap the sensor on a live controller.
class MonolensCameraSession implements CameraSession {
  MonolensCameraSession({
    this.resolution = ResolutionPreset.high,
    MonolensPlatform? platform,
    Future<List<CameraDescription>> Function()? camerasProvider,
  }) : _platform = platform ?? MonolensPlatform.instance,
       _camerasProvider = camerasProvider ?? availableCameras;

  final ResolutionPreset resolution;
  final MonolensPlatform _platform;
  final Future<List<CameraDescription>> Function() _camerasProvider;

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];

  CameraCaptureMode _mode = CameraCaptureMode.photo;
  CameraFacing _facing = CameraFacing.back;
  CameraFlash _flash = CameraFlash.off;

  final ValueNotifier<bool> _isRecording = ValueNotifier<bool>(false);
  final ValueNotifier<Duration> _recordedDuration = ValueNotifier<Duration>(
    Duration.zero,
  );

  Timer? _ticker;
  Timer? _autoStop;
  final Stopwatch _elapsed = Stopwatch();
  bool _disposed = false;

  @override
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  @override
  CameraCaptureMode get mode => _mode;

  @override
  CameraFacing get facing => _facing;

  @override
  CameraFlash get flash => _flash;

  @override
  ValueListenable<bool> get isRecording => _isRecording;

  @override
  ValueListenable<Duration> get recordedDuration => _recordedDuration;

  @override
  Future<CameraAccess> initialize(CameraCaptureMode mode) async {
    _mode = mode;
    try {
      if (_cameras.isEmpty) _cameras = await _camerasProvider();
      if (_cameras.isEmpty) return CameraAccess.unavailable;

      await _controller?.dispose();
      _controller = null;
      if (_disposed) return CameraAccess.unavailable;

      final controller = CameraController(
        _descriptionFor(_facing),
        resolution,
        // Only claim the microphone for video. A photo-only author should never
        // see a mic prompt.
        enableAudio: mode == CameraCaptureMode.video,
      );
      await controller.initialize();

      // dispose() may have landed while initialize() was in flight.
      if (_disposed) {
        await controller.dispose();
        return CameraAccess.unavailable;
      }

      _controller = controller;
      await _applyFlash();
      return CameraAccess.granted;
    } on CameraException catch (error) {
      return _accessFor(error);
    }
  }

  CameraDescription _descriptionFor(CameraFacing facing) {
    final wanted = facing == CameraFacing.front
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    return _cameras.firstWhere(
      (camera) => camera.lensDirection == wanted,
      orElse: () => _cameras.first,
    );
  }

  static CameraAccess _accessFor(CameraException error) => switch (error.code) {
    'CameraAccessDenied' || 'AudioAccessDenied' => CameraAccess.denied,
    'CameraAccessDeniedWithoutPrompt' ||
    'AudioAccessDeniedWithoutPrompt' ||
    'CameraAccessRestricted' ||
    'AudioAccessRestricted' => CameraAccess.permanentlyDenied,
    _ => CameraAccess.unavailable,
  };

  @override
  PreviewTexture? get preview {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    return PreviewTexture(
      // The camera plugin's id *is* the texture id on both platforms — its own
      // buildPreview is `Texture(textureId: cameraId)` plus, on Android, the
      // rotation the host now owns.
      textureId: controller.cameraId,
      size: controller.value.previewSize ?? Size.zero,
      sensorOrientation: controller.description.sensorOrientation,
      facing: _facing,
    );
  }

  @override
  Future<void> flip() async {
    if (_isRecording.value) return;
    _facing = _facing == CameraFacing.back
        ? CameraFacing.front
        : CameraFacing.back;
    await initialize(_mode);
  }

  @override
  Future<void> cycleFlash() async {
    _flash = switch (_flash) {
      CameraFlash.off => CameraFlash.auto,
      CameraFlash.auto => CameraFlash.on,
      CameraFlash.on => CameraFlash.off,
    };
    await _applyFlash();
  }

  Future<void> _applyFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // Video has no "auto" — a clip either has the torch on for its whole length
    // or it does not, so auto and on both mean torch.
    final mode = switch ((_mode, _flash)) {
      (CameraCaptureMode.video, CameraFlash.off) => FlashMode.off,
      (CameraCaptureMode.video, _) => FlashMode.torch,
      (_, CameraFlash.off) => FlashMode.off,
      (_, CameraFlash.auto) => FlashMode.auto,
      (_, CameraFlash.on) => FlashMode.always,
    };
    try {
      await controller.setFlashMode(mode);
    } on CameraException {
      // A front lens usually has no flash unit; leave the requested state
      // showing in the UI rather than fighting the device over it.
    }
  }

  @override
  Future<CapturedImage> capturePhoto() async {
    final controller = _requireController();
    final file = await controller.takePicture();
    final info = await _platform.probe(file.path);
    return CapturedImage.fromInfo(info, origin: MediaOrigin.camera);
  }

  @override
  Future<void> startVideoRecording({Duration? maxDuration}) async {
    final controller = _requireController();
    if (_isRecording.value) return;

    await controller.startVideoRecording();
    _isRecording.value = true;
    _recordedDuration.value = Duration.zero;
    _elapsed
      ..reset()
      ..start();

    // Read off a stopwatch rather than accumulated by the tick. A periodic
    // timer is not paid on time under load, so adding its nominal period every
    // fire drifts away from the real take -- and the number beside a cap is the
    // one number an author checks against it.
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final elapsed = _elapsed.elapsed;
      _recordedDuration.value = maxDuration != null && elapsed > maxDuration
          ? maxDuration
          : elapsed;
    });

    if (maxDuration != null) {
      // The cap is enforced at the shutter, not after the fact, so a capped
      // composer never has to reject its own recording.
      _autoStop = Timer(maxDuration, () {
        // Stop counting as well as flagging. Leaving the ticker running past
        // the cap runs the on-screen timer past it too, and leaks a periodic
        // timer for any host that does not collect the take immediately.
        _stopTiming();
        _recordedDuration.value = maxDuration;
        _isRecording.value = false;
      });
    }
  }

  void _stopTiming() {
    _ticker?.cancel();
    _autoStop?.cancel();
    _ticker = null;
    _autoStop = null;
    _elapsed.stop();
  }

  @override
  Future<CapturedVideo> stopVideoRecording() async {
    final controller = _requireController();
    _stopTiming();
    _isRecording.value = false;

    final file = await controller.stopVideoRecording();
    _recordedDuration.value = Duration.zero;
    final info = await _platform.probe(file.path);
    return CapturedVideo.fromInfo(info, origin: MediaOrigin.camera);
  }

  @override
  Future<void> pausePreview() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.pausePreview();
  }

  @override
  Future<void> resumePreview() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    await controller.resumePreview();
  }

  @override
  Future<void> dispose() async {
    // Idempotent: a host that disposes in both a lifecycle callback and its
    // State.dispose is doing something reasonable, and disposing a
    // ChangeNotifier twice throws.
    if (_disposed) return;
    _disposed = true;
    _stopTiming();
    await _controller?.dispose();
    _controller = null;
    _isRecording.dispose();
    _recordedDuration.dispose();
  }

  CameraController _requireController() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError(
        'CameraSession.initialize() must complete before capturing.',
      );
    }
    return controller;
  }
}
