import AVFoundation
import UIKit

/// Trims clips with AVFoundation and pulls filmstrip frames.
///
/// Deliberately not passthrough: `AVAssetExportPresetPassthrough` only cuts on
/// sync samples, so an in-point between keyframes silently slides backwards by
/// up to a GOP — fine for a rough cut, wrong when the author has just placed a
/// handle on a specific frame. Re-encoding costs a second or two on a short
/// clip and puts the cut where they asked for it.
final class VideoExporter {

  /// In-flight exports, so `cancel(jobId:)` can reach one. Touched from the
  /// platform thread and from export callbacks — hence the queue.
  private var sessions: [String: AVAssetExportSession] = [:]
  private var cancelledJobs: Set<String> = []
  private let lock = DispatchQueue(label: "com.monorithm.monolens.exports")

  private let onProgress: (String, Double) -> Void

  init(onProgress: @escaping (String, Double) -> Void) {
    self.onProgress = onProgress
  }

  func trim(
    request: VideoTrimRequest,
    jobId: String,
    completion: @escaping (Result<MediaInfo, Error>) -> Void
  ) {
    let sourceURL = URL(fileURLWithPath: request.sourcePath)
    guard FileManager.default.fileExists(atPath: request.sourcePath) else {
      completion(.failure(MonolensError.notFound(request.sourcePath)))
      return
    }

    let asset = AVURLAsset(url: sourceURL)
    let durationMs = Int64((CMTimeGetSeconds(asset.duration) * 1000).rounded())
    let startMs = max(0, request.startMs)
    let endMs = min(request.endMs, durationMs)
    guard endMs > startMs else {
      completion(
        .failure(
          MonolensError.invalidRange(
            "Range \(request.startMs)-\(request.endMs) ms is empty for a \(durationMs) ms clip")))
      return
    }

    // Milliseconds against a 1000-tick timescale: exact for the integer values
    // the Dart side works in, so no drift creeps into the cut point.
    let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
    let end = CMTime(value: CMTimeValue(endMs), timescale: 1000)
    let range = CMTimeRange(start: start, end: end)

    let exportAsset: AVAsset
    let exportRange: CMTimeRange
    if request.muteAudio {
      // Muting means dropping the track, not exporting silence — a silent AAC
      // track is bytes the upload does not need.
      do {
        exportAsset = try videoOnlyComposition(from: asset, range: range)
        exportRange = CMTimeRange(start: .zero, duration: range.duration)
      } catch {
        completion(.failure(error))
        return
      }
    } else {
      exportAsset = asset
      exportRange = range
    }

    guard
      let session = AVAssetExportSession(
        asset: exportAsset, presetName: AVAssetExportPresetHighestQuality)
    else {
      completion(.failure(MonolensError.exportFailed("No exporter for this asset")))
      return
    }

    let outputURL = URL(fileURLWithPath: request.outputPath)
    try? FileManager.default.removeItem(at: outputURL)

    session.outputURL = outputURL
    session.outputFileType =
      session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
    session.timeRange = exportRange

    // Only build a composition when the frame actually changes. A plain trim
    // stays on the straight path, which is markedly faster.
    if request.crop != nil || request.rotation != .none || request.flipHorizontal
      || !request.annotations.isEmpty
    {
      session.videoComposition = Self.videoComposition(for: exportAsset, request: request)
    }
    // Lets the OS trim to the requested range rather than shipping the whole
    // source into the pipeline.
    session.shouldOptimizeForNetworkUse = true

    var alreadyCancelled = false
    lock.sync {
      if cancelledJobs.contains(jobId) {
        // cancel() beat us here — honour it rather than starting the work.
        cancelledJobs.remove(jobId)
        alreadyCancelled = true
      } else {
        sessions[jobId] = session
      }
    }
    if alreadyCancelled {
      completion(.failure(MonolensError.cancelled))
      return
    }

    let ticker = startTicking(jobId: jobId, session: session)

    session.exportAsynchronously { [weak self] in
      guard let self else { return }
      ticker.cancel()
      self.lock.sync { _ = self.sessions.removeValue(forKey: jobId) }

      switch session.status {
      case .completed:
        self.onProgress(jobId, 1.0)
        do {
          var info = try MediaProbe.probe(path: request.outputPath)
          // Report the range that was asked for: the container's own duration
          // can land a frame either side after a re-encode.
          info.durationMs = endMs - startMs
          completion(.success(info))
        } catch {
          completion(.failure(error))
        }
      case .cancelled:
        completion(.failure(MonolensError.cancelled))
      default:
        let message = session.error?.localizedDescription ?? "Export failed"
        completion(.failure(MonolensError.exportFailed(message)))
      }
    }
  }

  func cancel(jobId: String) {
    lock.sync {
      if let session = sessions[jobId] {
        session.cancelExport()
      } else {
        // The export has not started yet; remember so trim() refuses to start.
        cancelledJobs.insert(jobId)
      }
    }
  }

  /// Polls `progress` on a timer. The property is a plain float with no KVO
  /// contract worth relying on, so a 10 Hz poll is the honest way to drive a
  /// progress bar.
  private func startTicking(jobId: String, session: AVAssetExportSession)
    -> DispatchSourceTimer
  {
    let timer = DispatchSource.makeTimerSource(queue: lock)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler { [weak self, weak session] in
      guard let self, let session else { return }
      self.onProgress(jobId, Double(session.progress))
    }
    timer.resume()
    return timer
  }

  /// Crop, rotate, blur and overlay, as one Core Image pass per frame.
  ///
  /// Core Image rather than layer instructions plus `AVVideoCompositionCoreAnimationTool`:
  /// blur has to sample the frame, which a CALayer overlay cannot do, and doing
  /// half the work in one mechanism and half in the other means two coordinate
  /// systems to keep in agreement. One pipeline, one set of rules.
  private static func videoComposition(
    for asset: AVAsset, request: VideoTrimRequest
  ) -> AVVideoComposition? {
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }

    let natural = track.naturalSize
    let transformed = natural.applying(track.preferredTransform)
    let display = CGSize(width: abs(transformed.width), height: abs(transformed.height))
    guard display.width >= 1, display.height >= 1 else { return nil }

    // Crop in display space. Core Image is y-up and the normalized rect is
    // measured from the top, so the origin flips.
    let crop: CGRect
    if let rect = request.crop {
      crop = CGRect(
        x: CGFloat(rect.left) * display.width,
        y: CGFloat(1 - rect.top - rect.height) * display.height,
        width: max(1, CGFloat(rect.width) * display.width),
        height: max(1, CGFloat(rect.height) * display.height))
    } else {
      crop = CGRect(origin: .zero, size: display)
    }

    let turned = request.rotation == .quarterTurn || request.rotation == .threeQuarterTurns
    let output = turned
      ? CGSize(width: crop.height, height: crop.width)
      : crop.size
    // Encoders reject odd dimensions on some profiles; round to even.
    let renderSize = CGSize(
      width: max(2, (output.width / 2).rounded() * 2),
      height: max(2, (output.height / 2).rounded() * 2))

    let mask = AnnotationRenderer.blurMask(request.annotations, size: renderSize)
    let radius = AnnotationRenderer.blurRadius(request.annotations, size: renderSize)
    let overlay = AnnotationRenderer.overlayLayer(request.annotations, size: renderSize)
    let rotation = request.rotation
    let flipHorizontal = request.flipHorizontal
    let preferred = track.preferredTransform

    let composition = AVVideoComposition(asset: asset) { requestFrame in
      var image = requestFrame.sourceImage

      // Whether the source arrives already oriented is version-dependent, so
      // measure rather than assume: if the extent still matches the encoded
      // size while the display size differs, the transform is ours to apply.
      if abs(image.extent.width - natural.width) < 1,
        abs(image.extent.height - natural.height) < 1,
        display != natural
      {
        image = image.transformed(by: preferred)
      }
      image = Self.movedToOrigin(image)

      image = image.cropped(to: crop)
      image = Self.movedToOrigin(image)

      image = Self.rotated(image, by: rotation)
      image = Self.movedToOrigin(image)

      // After the rotation, so the mirror is about the *output's* vertical
      // axis — the same order the still path composes in, which is what makes
      // a rotate-and-flip land identically on a JPEG and on every frame here.
      if flipHorizontal {
        image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        image = Self.movedToOrigin(image)
      }

      // renderSize was rounded to even for the encoder, so nudge the frame onto
      // it exactly — the mask and the overlay were rasterized at that size and
      // a one-pixel disagreement shows up as a seam.
      let scaleX = renderSize.width / max(1, image.extent.width)
      let scaleY = renderSize.height / max(1, image.extent.height)
      if abs(scaleX - 1) > 0.0001 || abs(scaleY - 1) > 0.0001 {
        image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        image = Self.movedToOrigin(image)
      }

      image = AnnotationRenderer.applyingBlur(to: image, mask: mask, radius: radius)
      image = AnnotationRenderer.compositing(overlay, over: image)

      requestFrame.finish(with: image, context: nil)
    }

    // The CI-filter initializer hands back an immutable composition, and
    // renderSize is the one thing we must set.
    guard let mutable = composition.mutableCopy() as? AVMutableVideoComposition else {
      return composition
    }
    mutable.renderSize = renderSize
    return mutable
  }

  private static func movedToOrigin(_ image: CIImage) -> CIImage {
    image.transformed(
      by: CGAffineTransform(
        translationX: -image.extent.origin.x, y: -image.extent.origin.y))
  }

  /// Core Image is y-up, so a clockwise turn on screen is a negative angle.
  private static func rotated(_ image: CIImage, by rotation: MonoRotation) -> CIImage {
    let radians: CGFloat
    switch rotation {
    case .none: return image
    case .quarterTurn: radians = -.pi / 2
    case .halfTurn: radians = .pi
    case .threeQuarterTurns: radians = .pi / 2
    }
    return image.transformed(by: CGAffineTransform(rotationAngle: radians))
  }

  private func videoOnlyComposition(from asset: AVAsset, range: CMTimeRange) throws
    -> AVComposition
  {
    let composition = AVMutableComposition()
    guard let sourceTrack = asset.tracks(withMediaType: .video).first,
      let track = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw MonolensError.exportFailed("No video track to export")
    }
    try track.insertTimeRange(range, of: sourceTrack, at: .zero)
    // Carry the rotation across, or a portrait clip exports on its side.
    track.preferredTransform = sourceTrack.preferredTransform
    return composition
  }

  // MARK: - Filmstrip

  /// Decodes every requested frame in one batch.
  ///
  /// `generateCGImagesAsynchronously` hands the whole time list to AVFoundation
  /// at once, so it walks the file in order and reuses one decode session;
  /// `copyCGImage` per frame re-seeks from scratch each time, which on a long
  /// clip is most of the cost of drawing a filmstrip.
  func thumbnails(path: String, atMs: [Int64], maxDimension: Int64) throws -> [Data] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard asset.tracks(withMediaType: .video).first != nil else {
      throw MonolensError.unsupported(path)
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: CGFloat(maxDimension), height: CGFloat(maxDimension))
    // A filmstrip is a scrubbing aid — half a second of slop buys a large speed
    // win over frame-exact seeking, which would decode from the last keyframe
    // for every thumbnail.
    generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
    generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)

    // Callbacks arrive out of order, keyed only by the time that was asked for,
    // so keep a queue of destination slots per timestamp — duplicated
    // timestamps then still land somewhere sensible.
    var slots: [CMTimeValue: [Int]] = [:]
    var times: [NSValue] = []
    for (index, milliseconds) in atMs.enumerated() {
      let value = CMTimeValue(max(0, milliseconds))
      slots[value, default: []].append(index)
      times.append(NSValue(time: CMTime(value: value, timescale: 1000)))
    }

    // One unreadable frame should not fail the strip; an empty entry is the
    // caller's cue to draw a placeholder.
    var frames = [Data](repeating: Data(), count: atMs.count)
    let lock = NSLock()
    let group = DispatchGroup()
    times.forEach { _ in group.enter() }

    generator.generateCGImagesAsynchronously(forTimes: times) {
      requested, image, _, _, _ in
      defer { group.leave() }
      guard let image,
        let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
      else { return }

      lock.lock()
      defer { lock.unlock() }
      if let index = slots[requested.value]?.first {
        slots[requested.value]?.removeFirst()
        frames[index] = data
      }
    }

    group.wait()
    return frames
  }
}
