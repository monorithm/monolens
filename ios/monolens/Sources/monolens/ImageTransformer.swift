import ImageIO
import UIKit

/// Crop, rotate, flip, downscale and re-encode a still.
///
/// One decode and at most one redraw. The output size is worked out first, from
/// metadata alone, and the decode is then asked for only as many pixels as that
/// output needs — cropping a 12 MP photo down to a 1080 px square never
/// materialises the 12 MP bitmap. Cropping itself is free (`CGImage.cropping`
/// returns a view, not a copy), and the rotate/flip/scale that used to be three
/// separate full-size redraws are folded into a single composite draw, skipped
/// entirely when the crop already is the answer.
enum ImageTransformer {

  static func apply(_ request: ImageEditRequest) throws -> MediaInfo {
    let url = URL(fileURLWithPath: request.sourcePath)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(source) > 0
    else {
      throw MonolensError.decodeFailed("Could not read \(request.sourcePath)")
    }

    let full = try uprightSize(of: source)
    let crop = cropRect(request.crop, in: full)
    let output = outputSize(
      crop: crop, rotation: request.rotation, cap: request.maxDimension)

    // Ask the decoder for the smallest image that still covers the crop at the
    // output's resolution. Whole frame : kept region :: what we decode : output.
    let cropLongest = max(crop.width, crop.height)
    let fullLongest = max(full.width, full.height)
    let outputLongest = max(output.width, output.height)
    let wanted = cropLongest <= 0
      ? fullLongest
      : Int((Double(outputLongest) * Double(fullLongest) / Double(cropLongest)).rounded(.up))

    let decoded = try decodeUpright(source, maxPixelSize: min(fullLongest, wanted))

    // The decode is approximate, so rescale the crop into whatever came back
    // rather than assuming it honoured the request exactly.
    let cropped = try cut(decoded, to: crop, of: full)

    let needsRedraw =
      request.rotation != .none || request.flipHorizontal
      || cropped.width != output.width || cropped.height != output.height

    var image = needsRedraw
      ? try render(
        cropped, to: output, rotation: request.rotation,
        flipHorizontal: request.flipHorizontal, opaque: request.format == .jpeg)
      : cropped

    if !request.annotations.isEmpty {
      image = try annotate(image, with: request.annotations, size: output)
    }

    let byteSize = try encode(image, request: request)
    return MediaInfo(
      path: request.outputPath,
      width: Int64(image.width),
      height: Int64(image.height),
      durationMs: nil,
      byteSize: byteSize
    )
  }

  // MARK: - Geometry
  //
  // All of it in full-resolution upright pixels, so the output dimensions are
  // exact and independent of how much the decoder chose to downsample.

  private static func uprightSize(of source: CGImageSource) throws -> (
    width: Int, height: Int
  ) {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { throw MonolensError.decodeFailed("No dimensions in image metadata") }

    let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let turned = orientation >= 5 && orientation <= 8
    return (turned ? height : width, turned ? width : height)
  }

  private static func cropRect(_ rect: NormalizedRect?, in full: (width: Int, height: Int))
    -> (x: Int, y: Int, width: Int, height: Int)
  {
    guard let rect else { return (0, 0, full.width, full.height) }
    let x = min(max(0, Int((rect.left * Double(full.width)).rounded())), full.width - 1)
    let y = min(max(0, Int((rect.top * Double(full.height)).rounded())), full.height - 1)
    let width = min(max(1, Int((rect.width * Double(full.width)).rounded())), full.width - x)
    let height = min(max(1, Int((rect.height * Double(full.height)).rounded())), full.height - y)
    return (x, y, width, height)
  }

  private static func outputSize(
    crop: (x: Int, y: Int, width: Int, height: Int), rotation: MonoRotation, cap: Int64?
  ) -> (width: Int, height: Int) {
    let turned = rotation == .quarterTurn || rotation == .threeQuarterTurns
    var width = turned ? crop.height : crop.width
    var height = turned ? crop.width : crop.height

    if let cap = cap.map(Int.init), cap >= 1, max(width, height) > cap {
      let factor = Double(cap) / Double(max(width, height))
      width = max(1, Int((Double(width) * factor).rounded()))
      height = max(1, Int((Double(height) * factor).rounded()))
    }
    return (width, height)
  }

  // MARK: - Pixels

  /// Decodes at most [maxPixelSize] on the longest edge, with the EXIF
  /// orientation already baked in — one pass instead of a full decode followed
  /// by a full-size redraw to straighten it.
  private static func decodeUpright(_ source: CGImageSource, maxPixelSize: Int) throws
    -> CGImage
  {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { throw MonolensError.decodeFailed("Could not decode image") }
    return image
  }

  private static func cut(
    _ image: CGImage, to crop: (x: Int, y: Int, width: Int, height: Int),
    of full: (width: Int, height: Int)
  ) throws -> CGImage {
    if crop.x == 0, crop.y == 0, crop.width == full.width, crop.height == full.height {
      return image
    }
    let scaleX = Double(image.width) / Double(full.width)
    let scaleY = Double(image.height) / Double(full.height)
    let rect = CGRect(
      x: (Double(crop.x) * scaleX).rounded(.down),
      y: (Double(crop.y) * scaleY).rounded(.down),
      width: max(1, (Double(crop.width) * scaleX).rounded()),
      height: max(1, (Double(crop.height) * scaleY).rounded())
    ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

    guard !rect.isNull, let cropped = image.cropping(to: rect) else {
      throw MonolensError.invalidRange("Crop lies outside the image")
    }
    return cropped
  }

  /// The single composite pass: rotation, mirroring and the final scale at once.
  private static func render(
    _ image: CGImage, to output: (width: Int, height: Int), rotation: MonoRotation,
    flipHorizontal: Bool, opaque: Bool
  ) throws -> CGImage {
    let radians: CGFloat
    switch rotation {
    case .none: radians = 0
    case .quarterTurn: radians = .pi / 2
    case .halfTurn: radians = .pi
    case .threeQuarterTurns: radians = 3 * .pi / 2
    }
    let turned = rotation == .quarterTurn || rotation == .threeQuarterTurns

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = opaque
    let size = CGSize(width: output.width, height: output.height)

    // UIKit's context is y-down, so a positive rotation reads clockwise — the
    // direction MonoRotation names.
    //
    // The CTM applies right-to-left, so `flip` written *before* `rotate` is the
    // one applied *after* it: the mirror is about the output's vertical axis,
    // which is what "flip horizontally" means to someone looking at the result.
    // Android composes the same order.
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let cgContext = context.cgContext
      cgContext.translateBy(x: size.width / 2, y: size.height / 2)
      if flipHorizontal { cgContext.scaleBy(x: -1, y: 1) }
      cgContext.rotate(by: radians)

      // Pre-rotation extent: swapped when the turn is a quarter, so the drawn
      // image lands exactly on the output box.
      let drawWidth = turned ? size.height : size.width
      let drawHeight = turned ? size.width : size.height
      UIImage(cgImage: image).draw(
        in: CGRect(
          x: -drawWidth / 2, y: -drawHeight / 2, width: drawWidth, height: drawHeight))
    }

    guard let result = rendered.cgImage else {
      throw MonolensError.encodeFailed("Render produced no bitmap")
    }
    return result
  }

  /// Blur first, then everything else on top.
  ///
  /// Blur samples the media, so it belongs to the picture; text, stickers and
  /// strokes are drawn over the result. That ordering also means a caption
  /// placed across a blurred face stays legible, which is what an author
  /// expects and the reverse of what a naive back-to-front pass would give.
  private static func annotate(
    _ image: CGImage, with annotations: [AnnotationSpec], size: (width: Int, height: Int)
  ) throws -> CGImage {
    let canvas = CGSize(width: size.width, height: size.height)
    var working = CIImage(cgImage: image)

    working = AnnotationRenderer.applyingBlur(
      to: working,
      mask: AnnotationRenderer.blurMask(annotations, size: canvas),
      radius: AnnotationRenderer.blurRadius(annotations, size: canvas))

    working = AnnotationRenderer.compositing(
      AnnotationRenderer.overlayLayer(annotations, size: canvas), over: working)

    let context = CIContext(options: [.useSoftwareRenderer: false])
    guard let rendered = context.createCGImage(working, from: working.extent) else {
      throw MonolensError.encodeFailed("Could not flatten annotations")
    }
    return rendered
  }

  /// Straight to a file through ImageIO — no UIImage round trip and no
  /// intermediate `Data` held in memory.
  private static func encode(_ image: CGImage, request: ImageEditRequest) throws -> Int64 {
    // The raw UTIs rather than `UTType`, which needs iOS 14 — these strings are
    // stable and keep the deployment target at 13.
    let type = request.format == .png ? "public.png" : "public.jpeg"
    let url = URL(fileURLWithPath: request.outputPath)
    try? FileManager.default.removeItem(at: url)

    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, type as CFString, 1, nil)
    else { throw MonolensError.encodeFailed("Could not open \(request.outputPath)") }

    var options: [CFString: Any] = [:]
    if request.format == .jpeg {
      options[kCGImageDestinationLossyCompressionQuality] =
        min(max(Double(request.quality), 1), 100) / 100
    }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw MonolensError.encodeFailed("Could not write \(request.outputPath)")
    }
    return MediaProbe.fileSize(at: request.outputPath)
  }
}
