import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import '../media/captured_media.dart';
import '../messages.g.dart';
import '../platform/monolens_platform.dart';
import 'annotation_wire.dart';
import 'edit_specs.dart';

/// The native error code a cancelled export completes with.
const String kMonolensCancelled = 'monolens/cancelled';

/// Thrown when an export is cancelled through [TrimJob.cancel]. A distinct type
/// so a composer can drop it silently instead of showing the failure banner it
/// shows for a real export error.
class TrimCancelled implements Exception {
  const TrimCancelled(this.jobId);

  final String jobId;

  @override
  String toString() => 'TrimCancelled($jobId)';
}

/// Thrown when the platform could not read or write the media.
class MediaEditException implements Exception {
  const MediaEditException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'MediaEditException($code): $message';
}

/// A running video export.
///
/// A handle rather than a bare `Future` because an export is the one operation
/// here that is slow enough to need a progress bar and a cancel button — a
/// 15 s clip is a few hundred milliseconds of transcode on a recent phone, but
/// a minute of 4K on an old one is not.
class TrimJob {
  TrimJob._(this.id, this.result, this.progress, this._cancel);

  final String id;

  /// Completes with the exported clip, or throws [TrimCancelled] if this job
  /// was cancelled and [MediaEditException] if the export failed.
  final Future<CapturedVideo> result;

  /// 0.0–1.0 ticks while the export runs. Broadcast; closes on completion.
  final Stream<double> progress;

  final Future<void> Function() _cancel;

  /// Asks the platform to abandon the export. [result] then throws
  /// [TrimCancelled]. Safe to call after completion — it is a no-op.
  Future<void> cancel() => _cancel();
}

/// Builds the destination path for an export, given a file extension. Injected
/// so tests write into a temp dir they control rather than the app sandbox.
typedef OutputPathBuilder = Future<String> Function(String extension);

/// On-device media editing: crop/rotate a still, trim a clip, and pull frames
/// for a filmstrip.
///
/// An interface so a composer's widget tests exercise the real edit flow
/// against a fake — the same seam style the create module already uses for
/// `CameraSession` and `VideoPreviewController`. [MonolensEditor] is the
/// platform-backed implementation.
abstract interface class MediaEditor {
  /// Reads dimensions, duration and size. Cheap — no full decode.
  Future<MediaInfo> probe(String path);

  /// Applies [edit] to the still at [sourcePath], writing a new file.
  ///
  /// The source is never modified, so an edit can be re-applied to the
  /// original with different parameters and lose nothing to re-compression.
  ///
  /// One channel call and one decode: the crop travels normalized, so nothing
  /// has to probe the source first, and the platform decodes straight to the
  /// size the output needs rather than at full resolution.
  Future<CapturedImage> applyImageEdit(String sourcePath, ImageEdit edit);

  /// Starts an export of [edit] over the clip at [sourcePath]. Returns
  /// immediately with a handle; the work runs on a platform thread.
  ///
  /// Covers the trim range, the crop, the rotation, muting, and any
  /// annotations burned into every frame.
  TrimJob startTrim(String sourcePath, VideoEdit edit);

  /// Evenly spaced frames across [duration], for a trim filmstrip. Returns
  /// encoded JPEG bytes, one per frame, in time order.
  Future<List<Uint8List>> filmstrip(
    String sourcePath, {
    required Duration duration,
    int frames = 8,
    int maxDimension = 128,
  });
}

/// The platform-backed [MediaEditor].
///
/// Stateless apart from a memoised cache directory: every operation is a
/// request built here and resolved natively, so two editors are
/// interchangeable and a host never has to keep one alive.
class MonolensEditor implements MediaEditor {
  MonolensEditor({MonolensPlatform? platform, OutputPathBuilder? outputPath})
    : _platform = platform ?? MonolensPlatform.instance {
    _outputPath = outputPath ?? _cacheOutputPath;
  }

  final MonolensPlatform _platform;
  late final OutputPathBuilder _outputPath;

  static int _sequence = 0;

  /// Resolved once per editor — the cache path does not move under a running
  /// app, and every export would otherwise pay a channel round trip for it.
  Future<String>? _cacheDirectory;

  Future<String> _cacheOutputPath(String extension) async {
    final dir = await (_cacheDirectory ??= _platform.cacheDirectory());
    return '$dir/monolens_${_nextId()}.$extension';
  }

  static String _nextId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  @override
  Future<MediaInfo> probe(String path) => _guard(() => _platform.probe(path));

  @override
  Future<CapturedImage> applyImageEdit(
    String sourcePath,
    ImageEdit edit,
  ) async {
    final extension = edit.format == MonoImageFormat.png ? 'png' : 'jpg';
    final outputPath = await _outputPath(extension);
    final info = await _guard(
      () => _platform.editImage(
        ImageEditRequest(
          sourcePath: sourcePath,
          outputPath: outputPath,
          // Null means "whole frame", which lets the platform skip the crop
          // entirely rather than copying the image onto itself.
          crop: edit.crop.isFull ? null : edit.crop.toRequest(),
          rotation: edit.rotation,
          flipHorizontal: edit.flipHorizontal,
          format: edit.format,
          quality: edit.quality,
          maxDimension: edit.maxDimension,
          annotations: edit.annotations.toSpecs(),
        ),
      ),
    );
    return CapturedImage.fromInfo(info, origin: MediaOrigin.edit);
  }

  @override
  TrimJob startTrim(String sourcePath, VideoEdit edit) {
    final jobId = 'trim_${_nextId()}';
    final ticks = StreamController<double>.broadcast();
    final subscription = _platform.progress
        .where((event) => event.jobId == jobId)
        .listen((event) {
          if (!ticks.isClosed) ticks.add(event.value);
        });

    Future<CapturedVideo> run() async {
      try {
        final info = await _platform.trimVideo(
          VideoTrimRequest(
            sourcePath: sourcePath,
            outputPath: await _outputPath('mp4'),
            startMs: edit.trim.start.inMilliseconds,
            endMs: edit.trim.end.inMilliseconds,
            muteAudio: edit.muteAudio,
            crop: edit.crop.isFull ? null : edit.crop.toRequest(),
            rotation: edit.rotation,
            flipHorizontal: edit.flipHorizontal,
            annotations: edit.annotations.toSpecs(),
          ),
          jobId,
        );
        return CapturedVideo.fromInfo(info, origin: MediaOrigin.edit);
      } on PlatformException catch (error) {
        if (error.code == kMonolensCancelled) throw TrimCancelled(jobId);
        throw MediaEditException(error.code, error.message ?? 'Export failed');
      } finally {
        await subscription.cancel();
        await ticks.close();
      }
    }

    return TrimJob._(jobId, run(), ticks.stream, () => _platform.cancel(jobId));
  }

  @override
  Future<List<Uint8List>> filmstrip(
    String sourcePath, {
    required Duration duration,
    int frames = 8,
    int maxDimension = 128,
  }) {
    // Sample at frame centres, not edges: the first and last frames of a clip
    // are often a black lead-in or a motion-blurred stop, and a strip of those
    // reads as a broken decode.
    final step = duration.inMilliseconds / frames;
    final at = [for (var i = 0; i < frames; i++) (step * (i + 0.5)).round()];
    return _guard(
      () => _platform.videoThumbnails(sourcePath, at, maxDimension),
    );
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on PlatformException catch (error) {
      throw MediaEditException(error.code, error.message ?? 'Media op failed');
    }
  }
}
