/// Test doubles for hosts that build on monolens.
///
/// A composer's widget tests cannot host a camera or a platform channel, so
/// every seam monolens exposes has a fake here. Import this from `test/` only —
/// it is deliberately not part of `package:monolens/monolens.dart`.
library;

import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'monolens.dart';

/// An in-memory [MonolensPlatform].
///
/// Records what it was asked to do and answers from [files], so a test asserts
/// on the *request* — the crop rectangle in pixels, the trim range in
/// milliseconds — rather than on bytes it would have to decode.
class FakeMonolensPlatform implements MonolensPlatform {
  FakeMonolensPlatform({this.exportDuration = Duration.zero});

  /// Canned probe answers, keyed by path. Unknown paths get [defaultInfo].
  final Map<String, MediaInfo> files = {};

  /// What an unregistered path probes as.
  MediaInfo Function(String path) defaultInfo = (path) => MediaInfo(
    path: path,
    width: 1920,
    height: 1080,
    durationMs: 10000,
    byteSize: 1024,
  );

  final List<ImageEditRequest> imageEdits = [];
  final List<VideoTrimRequest> trims = [];
  final List<String> cancellations = [];
  final List<String> probes = [];

  /// How long a fake export takes. Zero completes on the next microtask; a
  /// non-zero value gives a test room to cancel mid-flight.
  Duration exportDuration;

  /// Progress values emitted during an export, before it completes.
  List<double> progressTicks = const [0.25, 0.5, 0.75];

  /// When set, the next call of the matching kind throws this instead.
  Object? nextImageEditError;
  Object? nextTrimError;

  final StreamController<TrimProgress> _progress =
      StreamController<TrimProgress>.broadcast();
  final Set<String> _cancelled = {};

  @override
  Stream<TrimProgress> get progress => _progress.stream;

  @override
  Future<String> cacheDirectory() async => '/tmp/monolens-test';

  @override
  Future<MediaInfo> probe(String path) async {
    probes.add(path);
    return files[path] ?? defaultInfo(path);
  }

  @override
  Future<MediaInfo> editImage(ImageEditRequest request) async {
    imageEdits.add(request);
    final error = nextImageEditError;
    if (error != null) {
      nextImageEditError = null;
      throw error;
    }

    // Mirror the real ordering so a test can assert on output dimensions:
    // crop, then rotate, then scale.
    final source = files[request.sourcePath] ?? defaultInfo(request.sourcePath);
    final crop = request.crop;
    var width = crop == null
        ? source.width
        : (crop.width * source.width).round();
    var height = crop == null
        ? source.height
        : (crop.height * source.height).round();
    if (request.rotation == MonoRotation.quarterTurn ||
        request.rotation == MonoRotation.threeQuarterTurns) {
      (width, height) = (height, width);
    }
    final cap = request.maxDimension;
    if (cap != null && (width > cap || height > cap)) {
      final factor = cap / (width > height ? width : height);
      width = (width * factor).round();
      height = (height * factor).round();
    }

    return MediaInfo(
      path: request.outputPath,
      width: width,
      height: height,
      byteSize: 2048,
    );
  }

  @override
  Future<MediaInfo> trimVideo(VideoTrimRequest request, String jobId) async {
    trims.add(request);
    final error = nextTrimError;
    if (error != null) {
      nextTrimError = null;
      throw error;
    }

    for (final tick in progressTicks) {
      // Yield between ticks. A real export delivers progress over a channel,
      // never in the same microtask as its result — emitting synchronously
      // would let the result outrun the ticks and drop them.
      await Future<void>.delayed(Duration.zero);
      if (_cancelled.contains(jobId)) break;
      _progress.add(TrimProgress(jobId, tick));
    }
    if (exportDuration > Duration.zero) {
      await Future<void>.delayed(exportDuration);
    }
    // Let the last tick reach its listeners before the result completes and
    // the editor tears the subscription down.
    await Future<void>.delayed(Duration.zero);
    if (_cancelled.remove(jobId)) {
      throw PlatformException(
        code: kMonolensCancelled,
        message: 'Export cancelled',
      );
    }

    final source = files[request.sourcePath] ?? defaultInfo(request.sourcePath);
    return MediaInfo(
      path: request.outputPath,
      width: source.width,
      height: source.height,
      durationMs: request.endMs - request.startMs,
      byteSize: 4096,
    );
  }

  @override
  Future<void> cancel(String jobId) async {
    cancellations.add(jobId);
    _cancelled.add(jobId);
  }

  @override
  Future<List<Uint8List>> videoThumbnails(
    String path,
    List<int> atMs,
    int maxDimension,
  ) async => [
    // A JPEG SOI header, so a caller that sniffs the bytes sees a plausible
    // image rather than zeros.
    for (var i = 0; i < atMs.length; i++)
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, i]),
  ];

  /// Installs this as the platform and restores the default on teardown.
  void install() => MonolensPlatform.instance = this;

  static void uninstall() => MonolensPlatform.instance = null;

  void dispose() => _progress.close();
}

/// A [CameraSession] that never touches a device.
///
/// Drives the same state a real session does — recording flag, elapsed timer,
/// facing and flash — so a composer's viewfinder chrome can be exercised in a
/// widget test, including the auto-stop at the cap.
class FakeCameraSession implements CameraSession {
  FakeCameraSession({
    this.access = CameraAccess.granted,
    CapturedImage? photo,
    CapturedVideo? video,
  }) : _photo =
           photo ??
           const CapturedImage(
             path: '/tmp/fake-photo.jpg',
             contentType: 'image/jpeg',
             byteSize: 1024,
             width: 1920,
             height: 1080,
             origin: MediaOrigin.camera,
           ),
       _video =
           video ??
           const CapturedVideo(
             path: '/tmp/fake-video.mp4',
             contentType: 'video/mp4',
             byteSize: 4096,
             width: 1080,
             height: 1920,
             origin: MediaOrigin.camera,
             duration: Duration(seconds: 3),
           );

  /// What [initialize] reports. Set to a denial to render a permission state.
  CameraAccess access;

  final CapturedImage _photo;
  final CapturedVideo _video;

  int initializeCount = 0;
  int photoCount = 0;
  int flipCount = 0;
  bool isDisposed = false;
  Duration? lastMaxDuration;

  final ValueNotifier<bool> _isRecording = ValueNotifier<bool>(false);
  final ValueNotifier<Duration> _recordedDuration = ValueNotifier<Duration>(
    Duration.zero,
  );

  CameraCaptureMode _mode = CameraCaptureMode.photo;
  CameraFacing _facing = CameraFacing.back;
  CameraFlash _flash = CameraFlash.off;
  bool _isInitialized = false;

  @override
  bool get isInitialized => _isInitialized;

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
    initializeCount++;
    _mode = mode;
    _isInitialized = access == CameraAccess.granted;
    return access;
  }

  @override
  PreviewTexture? get preview => _isInitialized
      ? const PreviewTexture(
          textureId: 7,
          size: Size(1920, 1080),
          sensorOrientation: 90,
          facing: CameraFacing.back,
        )
      : null;

  @override
  Future<void> flip() async {
    flipCount++;
    _facing = _facing == CameraFacing.back
        ? CameraFacing.front
        : CameraFacing.back;
  }

  @override
  Future<void> cycleFlash() async {
    _flash = switch (_flash) {
      CameraFlash.off => CameraFlash.auto,
      CameraFlash.auto => CameraFlash.on,
      CameraFlash.on => CameraFlash.off,
    };
  }

  @override
  Future<CapturedImage> capturePhoto() async {
    photoCount++;
    return _photo;
  }

  @override
  Future<void> startVideoRecording({Duration? maxDuration}) async {
    lastMaxDuration = maxDuration;
    _isRecording.value = true;
    _recordedDuration.value = Duration.zero;
  }

  @override
  Future<CapturedVideo> stopVideoRecording() async {
    _isRecording.value = false;
    _recordedDuration.value = Duration.zero;
    return _video;
  }

  /// Advances the on-screen timer without a real clock, and fires the auto-stop
  /// once the cap is reached — the same signal the real session sends.
  void tick(Duration elapsed) {
    final cap = lastMaxDuration;
    final next = _recordedDuration.value + elapsed;
    // Held at the cap, as the real session holds it. A fake that counts past
    // the cap lets a host's test pass on a number production never reports.
    _recordedDuration.value = cap != null && next > cap ? cap : next;
    if (cap != null && _recordedDuration.value >= cap) {
      _isRecording.value = false;
    }
  }

  @override
  Future<void> pausePreview() async {}

  @override
  Future<void> resumePreview() async {}

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    isDisposed = true;
    _isRecording.dispose();
    _recordedDuration.dispose();
  }
}

/// A [MediaPicker] that returns canned media, or null for a cancelled pick.
class FakeMediaPicker implements MediaPicker {
  FakeMediaPicker({this.image, this.video});

  CapturedImage? image;
  CapturedVideo? video;

  int imagePickCount = 0;
  int videoPickCount = 0;

  @override
  Future<CapturedImage?> pickImage() async {
    imagePickCount++;
    return image;
  }

  @override
  Future<CapturedVideo?> pickVideo() async {
    videoPickCount++;
    return video;
  }
}
