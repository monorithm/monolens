import 'dart:io';
import 'dart:typed_data';

import '../messages.g.dart';

/// Where a piece of media came from — worth keeping because the two paths have
/// different trust properties: a camera clip is length-capped at the shutter,
/// a gallery import is whatever the author's library holds and has to be
/// re-checked against the caller's limits.
enum MediaOrigin {
  camera,
  gallery,

  /// The output of an edit — the result of a crop or a trim.
  edit,
}

/// A still or a clip sitting on disk.
///
/// Path-first, not bytes-first: a 25 MB clip should not be resident in the Dart
/// heap just to be previewed, and every native op reads and writes files
/// anyway. Call [readBytes] at the point of upload, where the bytes are
/// actually needed.
sealed class CapturedMedia {
  const CapturedMedia({
    required this.path,
    required this.contentType,
    required this.byteSize,
    required this.width,
    required this.height,
    required this.origin,
  });

  /// Absolute path to the file. Files produced by monolens live in the app's
  /// temporary directory — copy anything that has to outlive the session.
  final String path;
  final String contentType;
  final int byteSize;

  /// Display dimensions, already rotation-corrected: a clip recorded in
  /// portrait reports portrait here even though its track is landscape with a
  /// 90° transform.
  final int width;
  final int height;

  final MediaOrigin origin;

  File get file => File(path);

  /// Reads the whole file into memory. The call an upload makes.
  Future<Uint8List> readBytes() => file.readAsBytes();

  double get aspectRatio => height == 0 ? 1 : width / height;
}

final class CapturedImage extends CapturedMedia {
  const CapturedImage({
    required super.path,
    required super.contentType,
    required super.byteSize,
    required super.width,
    required super.height,
    required super.origin,
  });

  factory CapturedImage.fromInfo(
    MediaInfo info, {
    required MediaOrigin origin,
    String? contentType,
  }) => CapturedImage(
    path: info.path,
    contentType: contentType ?? _imageContentTypeFor(info.path),
    byteSize: info.byteSize,
    width: info.width,
    height: info.height,
    origin: origin,
  );
}

final class CapturedVideo extends CapturedMedia {
  const CapturedVideo({
    required super.path,
    required super.contentType,
    required super.byteSize,
    required super.width,
    required super.height,
    required super.origin,
    required this.duration,
  });

  factory CapturedVideo.fromInfo(
    MediaInfo info, {
    required MediaOrigin origin,
    String? contentType,
  }) => CapturedVideo(
    path: info.path,
    contentType: contentType ?? 'video/mp4',
    byteSize: info.byteSize,
    width: info.width,
    height: info.height,
    origin: origin,
    duration: Duration(milliseconds: info.durationMs ?? 0),
  );

  final Duration duration;
}

String _imageContentTypeFor(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}
