// The single source of truth for the native bridge. Regenerate the Dart, Swift
// and Kotlin bindings after editing:
//
//   dart run pigeon --input pigeons/monolens_api.dart
//
// The generated files are committed (`lib/src/messages.g.dart` and the two
// `Messages.g.*` under ios/ and android/) so a consumer never needs pigeon.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/monorithm/monolens/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.monorithm.monolens'),
    swiftOut: 'ios/monolens/Sources/monolens/Messages.g.swift',
    dartPackageName: 'monolens',
  ),
)
/// A crop as fractions of the frame, 0–1.
///
/// Normalized all the way to the platform rather than resolved to pixels in
/// Dart. That removes a probe round trip per edit — the native side is opening
/// the file anyway and already knows its dimensions — and it removes the chance
/// of the two sides disagreeing about what those dimensions are.
class NormalizedRect {
  NormalizedRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double left;
  double top;
  double width;
  double height;
}

/// Clockwise quarter turns applied after cropping.
enum MonoRotation { none, quarterTurn, halfTurn, threeQuarterTurns }

/// How a still is re-encoded on export.
enum MonoImageFormat { jpeg, png }

class ImageEditRequest {
  ImageEditRequest({
    required this.sourcePath,
    required this.outputPath,
    required this.rotation,
    required this.flipHorizontal,
    required this.format,
    required this.quality,
    required this.annotations,
    this.crop,
    this.maxDimension,
  });

  String sourcePath;
  String outputPath;

  /// Null crops nothing — the full frame is re-encoded.
  NormalizedRect? crop;
  MonoRotation rotation;
  bool flipHorizontal;
  MonoImageFormat format;

  /// 1–100. Ignored for [MonoImageFormat.png].
  int quality;

  /// Downscales so the longest edge is at most this many pixels. Null keeps the
  /// cropped size. Applied after crop and rotation.
  int? maxDimension;

  /// Painted over the result, back to front, after every transform.
  List<AnnotationSpec> annotations;
}

/// Which kind of overlay an [AnnotationSpec] describes.
enum AnnotationKind { text, sticker, blur, stroke }

enum BlurShapeSpec { rectangle, oval }

/// One annotation, flattened.
///
/// Deliberately a single struct with nullable fields rather than a sealed
/// hierarchy: the wire crosses three languages, and a flat record with a kind
/// tag is trivial for each native side to switch on. Dart keeps the sealed,
/// typed version and converts here, so only this one struct is ugly.
///
/// All geometry is normalized against the *output* frame — after crop and
/// rotation — because that is the frame the author placed it against.
class AnnotationSpec {
  AnnotationSpec({
    required this.kind,
    required this.rotation,
    this.text,
    this.centerX,
    this.centerY,
    this.heightFraction,
    this.colorArgb,
    this.backgroundArgb,
    this.imagePath,
    this.rect,
    this.opacity,
    this.strength,
    this.shape,
    this.points,
    this.widthFraction,
  });

  AnnotationKind kind;

  /// Clockwise radians. Applies to text and stickers.
  double rotation;

  // Text (and emoji, which is text with an emoji in it).
  String? text;
  double? centerX;
  double? centerY;

  /// Cap height as a fraction of the output's height.
  double? heightFraction;
  int? colorArgb;
  int? backgroundArgb;

  // Sticker.
  String? imagePath;
  NormalizedRect? rect;
  double? opacity;

  // Blur.
  double? strength;
  BlurShapeSpec? shape;

  /// Stroke points, flattened as x, y, x, y — a flat list survives every
  /// codec without a nested type.
  List<double>? points;

  /// Stroke width as a fraction of the output's shorter edge.
  double? widthFraction;
}

class VideoTrimRequest {
  VideoTrimRequest({
    required this.sourcePath,
    required this.outputPath,
    required this.startMs,
    required this.endMs,
    required this.muteAudio,
    required this.rotation,
    required this.flipHorizontal,
    required this.annotations,
    this.crop,
  });

  String sourcePath;
  String outputPath;
  int startMs;
  int endMs;

  /// Drops the audio track entirely rather than exporting a silent one.
  bool muteAudio;

  /// Null crops nothing.
  NormalizedRect? crop;
  MonoRotation rotation;

  /// Mirrors the *rotated* frame, matching the still path exactly.
  bool flipHorizontal;

  /// Burned into every frame, back to front.
  List<AnnotationSpec> annotations;
}

/// What a probe or an export reports back about a file on disk.
class MediaInfo {
  MediaInfo({
    required this.path,
    required this.width,
    required this.height,
    required this.byteSize,
    this.durationMs,
  });

  String path;

  /// Display dimensions — already rotation-corrected, so a portrait clip
  /// recorded on a sensor-landscape device reports portrait here.
  int width;
  int height;

  /// Null for stills.
  int? durationMs;
  int byteSize;
}

@HostApi()
abstract class MonolensHostApi {
  /// The app's cache directory, where exports are written.
  ///
  /// Asked of the platform rather than taken from `path_provider`, so the
  /// plugin carries no dependency for one string the native side already knows
  /// (`NSTemporaryDirectory()` / `context.cacheDir`). Contents are the OS's to
  /// evict — a caller keeping an export must copy it somewhere durable.
  String cacheDirectory();

  /// Reads dimensions, duration and size without decoding the whole file.
  @async
  MediaInfo probe(String path);

  @async
  MediaInfo editImage(ImageEditRequest request);

  /// Re-encodes [request]'s range to a new file. [jobId] addresses the export
  /// for [cancel] and for progress delivered over [MonolensFlutterApi].
  @async
  MediaInfo trimVideo(VideoTrimRequest request, String jobId);

  /// Requests cancellation of an in-flight [trimVideo]. A cancelled export
  /// completes with a `monolens/cancelled` error rather than a result.
  void cancel(String jobId);

  /// Decodes frames at [atMs] for the trim filmstrip, each scaled so its
  /// longest edge is at most [maxDimension]. Returned as encoded JPEG bytes in
  /// the same order as the requested timestamps.
  @async
  List<Uint8List> videoThumbnails(
    String path,
    List<int> atMs,
    int maxDimension,
  );
}

@FlutterApi()
abstract class MonolensFlutterApi {
  /// Fractional export progress in 0.0–1.0 for the job identified by [jobId].
  void onProgress(String jobId, double progress);
}
