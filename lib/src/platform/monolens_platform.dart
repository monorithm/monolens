/// @docImport 'package:flutter/services.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import '../messages.g.dart';

/// The native seam every editing call crosses.
///
/// An interface rather than the generated [MonolensHostApi] directly so tests
/// run the editor, the crop view and the trim view against an in-memory fake
/// with no platform channel and no device — the same shape the create module
/// already uses for `CameraSession` and `VideoPreviewController`. It is also
/// the split point if the plugin is ever federated into per-platform packages.
abstract interface class MonolensPlatform {
  /// The implementation calls run against. Assign a fake in `setUp` and restore
  /// [PigeonMonolensPlatform] (or null) in `tearDown`.
  static MonolensPlatform get instance =>
      _instance ??= PigeonMonolensPlatform();
  static set instance(MonolensPlatform? value) => _instance = value;
  static MonolensPlatform? _instance;

  /// The app's cache directory — where exports are written.
  Future<String> cacheDirectory();

  Future<MediaInfo> probe(String path);

  Future<MediaInfo> editImage(ImageEditRequest request);

  /// Exports the trimmed range. Progress for [jobId] arrives on [progress]
  /// while this is in flight.
  Future<MediaInfo> trimVideo(VideoTrimRequest request, String jobId);

  /// Asks the platform to abandon [jobId]. The matching [trimVideo] future
  /// completes with a `monolens/cancelled` [PlatformException].
  Future<void> cancel(String jobId);

  Future<List<Uint8List>> videoThumbnails(
    String path,
    List<int> atMs,
    int maxDimension,
  );

  /// Export progress for every in-flight job, keyed by job id. Broadcast, so
  /// several concurrent exports can each be observed.
  Stream<TrimProgress> get progress;
}

/// A fractional progress tick for one export.
class TrimProgress {
  const TrimProgress(this.jobId, this.value);

  final String jobId;

  /// 0.0–1.0.
  final double value;
}

/// The default [MonolensPlatform] — the generated Pigeon host API, plus the
/// reverse channel the native exporters push progress over.
class PigeonMonolensPlatform implements MonolensPlatform, MonolensFlutterApi {
  PigeonMonolensPlatform({MonolensHostApi? api})
    : _api = api ?? MonolensHostApi() {
    MonolensFlutterApi.setUp(this);
  }

  final MonolensHostApi _api;
  final StreamController<TrimProgress> _progress =
      StreamController<TrimProgress>.broadcast();

  @override
  Stream<TrimProgress> get progress => _progress.stream;

  /// Called by the native side; not part of [MonolensPlatform].
  @override
  void onProgress(String jobId, double progress) {
    if (!_progress.isClosed) _progress.add(TrimProgress(jobId, progress));
  }

  @override
  Future<String> cacheDirectory() => _api.cacheDirectory();

  @override
  Future<MediaInfo> probe(String path) => _api.probe(path);

  @override
  Future<MediaInfo> editImage(ImageEditRequest request) =>
      _api.editImage(request);

  @override
  Future<MediaInfo> trimVideo(VideoTrimRequest request, String jobId) =>
      _api.trimVideo(request, jobId);

  @override
  Future<void> cancel(String jobId) => _api.cancel(jobId);

  @override
  Future<List<Uint8List>> videoThumbnails(
    String path,
    List<int> atMs,
    int maxDimension,
  ) => _api.videoThumbnails(path, atMs, maxDimension);
}
