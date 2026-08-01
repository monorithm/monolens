import AVFoundation
import ImageIO
import UIKit

/// Reads dimensions, duration and size off a file without decoding it.
///
/// Both branches report *display* dimensions rather than stored ones: a still
/// carries an EXIF orientation and a clip carries a preferred transform, and in
/// both cases the stored buffer is often sideways relative to what the author
/// saw. Dart's `CropRect` resolves against these numbers, so the croppers below
/// have to work in the same upright space.
enum MediaProbe {

  static func probe(path: String) throws -> MediaInfo {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      throw MonolensError.notFound(path)
    }
    let byteSize = fileSize(at: path)

    if let image = probeImage(url: url, byteSize: byteSize) {
      return image
    }
    if let video = probeVideo(url: url, byteSize: byteSize) {
      return video
    }
    throw MonolensError.unsupported(path)
  }

  private static func probeImage(url: URL, byteSize: Int64) -> MediaInfo? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }

    // EXIF orientations 5–8 are the quarter-turned ones, where the stored
    // buffer's width is the displayed height.
    let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let turned = orientation >= 5 && orientation <= 8

    return MediaInfo(
      path: url.path,
      width: Int64(turned ? height : width),
      height: Int64(turned ? width : height),
      durationMs: nil,
      byteSize: byteSize
    )
  }

  private static func probeVideo(url: URL, byteSize: Int64) -> MediaInfo? {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }

    // naturalSize is the encoded size; preferredTransform is the rotation the
    // player applies. Multiplying gives what the author actually sees.
    let transformed = track.naturalSize.applying(track.preferredTransform)
    let width = abs(transformed.width)
    let height = abs(transformed.height)

    let seconds = CMTimeGetSeconds(asset.duration)
    let durationMs = seconds.isFinite ? Int64((seconds * 1000).rounded()) : 0

    return MediaInfo(
      path: url.path,
      width: Int64(width.rounded()),
      height: Int64(height.rounded()),
      durationMs: durationMs,
      byteSize: byteSize
    )
  }

  static func fileSize(at path: String) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
  }
}

/// The failures the host API reports back to Dart. The codes are what
/// `MediaEditException.code` carries, so Dart can branch on them.
enum MonolensError: Error {
  case notFound(String)
  case unsupported(String)
  case decodeFailed(String)
  case encodeFailed(String)
  case invalidRange(String)
  case exportFailed(String)
  case cancelled

  var pigeonError: PigeonError {
    switch self {
    case .notFound(let path):
      return PigeonError(code: "monolens/not-found", message: "No file at \(path)", details: nil)
    case .unsupported(let path):
      return PigeonError(
        code: "monolens/unsupported", message: "Unsupported media at \(path)", details: nil)
    case .decodeFailed(let message):
      return PigeonError(code: "monolens/decode-failed", message: message, details: nil)
    case .encodeFailed(let message):
      return PigeonError(code: "monolens/encode-failed", message: message, details: nil)
    case .invalidRange(let message):
      return PigeonError(code: "monolens/invalid-range", message: message, details: nil)
    case .exportFailed(let message):
      return PigeonError(code: "monolens/export-failed", message: message, details: nil)
    case .cancelled:
      return PigeonError(code: "monolens/cancelled", message: "Export cancelled", details: nil)
    }
  }
}
