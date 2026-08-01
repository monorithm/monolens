import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Paints annotations onto media.
///
/// Shared by the still and the clip paths, which is the point: an annotation
/// has to mean the same thing in a JPEG and in every frame of an MP4, and the
/// only way to guarantee that is one implementation of the geometry.
///
/// The split that matters is blur versus everything else.
/// Text, stickers and strokes never read the media, so they flatten into a
/// single transparent layer that is drawn once for a still and composited
/// per-frame for a clip. Blur samples the source, so it cannot be flattened —
/// it becomes a mask that Core Image blends a blurred copy through.
enum AnnotationRenderer {

  /// Everything except blur, rasterized to one transparent RGBA layer.
  /// Nil when there is nothing to draw.
  static func overlayLayer(
    _ annotations: [AnnotationSpec], size: CGSize
  ) -> CGImage? {
    let painted = annotations.filter { $0.kind != .blur }
    guard !painted.isEmpty, size.width >= 1, size.height >= 1 else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false

    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      for annotation in painted {
        switch annotation.kind {
        case .text: draw(text: annotation, in: context.cgContext, size: size)
        case .sticker: draw(sticker: annotation, in: context.cgContext, size: size)
        case .stroke: draw(stroke: annotation, in: context.cgContext, size: size)
        case .blur: break
        }
      }
    }
    return image.cgImage
  }

  /// White where the media should be blurred, black elsewhere. Nil when no blur
  /// was asked for.
  static func blurMask(_ annotations: [AnnotationSpec], size: CGSize) -> CGImage? {
    let regions = annotations.filter { $0.kind == .blur }
    guard !regions.isEmpty, size.width >= 1, size.height >= 1 else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.white.setFill()
      for region in regions {
        let rect = pixels(region.rect, in: size)
        let path = region.shape == .oval
          ? UIBezierPath(ovalIn: rect)
          : UIBezierPath(rect: rect)
        path.fill()
      }
    }.cgImage
  }

  /// The blur radius, in output pixels.
  ///
  /// Scaled against the *smallest* region rather than a constant, so a radius
  /// chosen for a face does not erase a small one entirely — and so `strength`
  /// means the same thing regardless of export resolution.
  static func blurRadius(_ annotations: [AnnotationSpec], size: CGSize) -> Double {
    let regions = annotations.filter { $0.kind == .blur }
    guard !regions.isEmpty else { return 0 }

    let smallest = regions.map { region -> Double in
      let rect = pixels(region.rect, in: size)
      return Double(min(rect.width, rect.height))
    }.min() ?? 0
    let strength = regions.map { $0.strength ?? 0.5 }.max() ?? 0.5
    // A quarter of the region's short edge at full strength is enough to
    // destroy detail without turning the region into a flat smear.
    return max(1, smallest * 0.25 * min(max(strength, 0), 1))
  }

  /// Blends a blurred copy of [image] through [mask]. Returns the input
  /// unchanged when there is nothing to blur.
  static func applyingBlur(
    to image: CIImage, mask: CGImage?, radius: Double
  ) -> CIImage {
    guard let mask, radius > 0 else { return image }

    let blur = CIFilter.gaussianBlur()
    blur.inputImage = image.clampedToExtent()
    blur.radius = Float(radius)
    guard let blurred = blur.outputImage?.cropped(to: image.extent) else {
      return image
    }

    let blend = CIFilter.blendWithMask()
    blend.inputImage = blurred
    blend.backgroundImage = image
    blend.maskImage = aligned(CIImage(cgImage: mask), to: image.extent)
    return blend.outputImage ?? image
  }

  /// Composites an overlay layer over [image].
  static func compositing(
    _ overlay: CGImage?, over image: CIImage
  ) -> CIImage {
    guard let overlay else { return image }
    let filter = CIFilter.sourceOverCompositing()
    filter.inputImage = aligned(CIImage(cgImage: overlay), to: image.extent)
    filter.backgroundImage = image
    return filter.outputImage ?? image
  }

  /// Moves a layer onto the target's origin.
  ///
  /// No vertical flip, deliberately. Core Graphics draws y-down and Core Image
  /// is y-up, but `CIImage(cgImage:)` already reconciles the two — the bitmap's
  /// top row becomes the top of the CI extent. Flipping here as well turns the
  /// layer over, which is invisible for anything symmetric about the middle and
  /// obvious for everything else.
  private static func aligned(_ image: CIImage, to extent: CGRect) -> CIImage {
    image.transformed(
      by: CGAffineTransform(
        translationX: extent.origin.x - image.extent.origin.x,
        y: extent.origin.y - image.extent.origin.y))
  }

  // MARK: - Individual annotations

  private static func pixels(_ rect: NormalizedRect?, in size: CGSize) -> CGRect {
    guard let rect else { return CGRect(origin: .zero, size: size) }
    return CGRect(
      x: CGFloat(rect.left) * size.width,
      y: CGFloat(rect.top) * size.height,
      width: max(1, CGFloat(rect.width) * size.width),
      height: max(1, CGFloat(rect.height) * size.height))
  }

  private static func color(_ argb: Int64?, fallback: UIColor = .white) -> UIColor {
    guard let argb else { return fallback }
    let value = UInt32(truncatingIfNeeded: argb)
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: CGFloat((value >> 24) & 0xFF) / 255)
  }

  private static func draw(text spec: AnnotationSpec, in context: CGContext, size: CGSize) {
    guard let text = spec.text, !text.isEmpty else { return }

    // Point size from a fraction of the output height, so the same annotation
    // looks identical on a 720p export and a 4K one. The system font is what
    // shapes emoji, which is why emoji needs no separate primitive.
    let pointSize = max(1, CGFloat(spec.heightFraction ?? 0.08) * size.height)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: pointSize, weight: .semibold),
      .foregroundColor: color(spec.colorArgb),
    ]
    let measured = (text as NSString).size(withAttributes: attributes)
    let center = CGPoint(
      x: CGFloat(spec.centerX ?? 0.5) * size.width,
      y: CGFloat(spec.centerY ?? 0.5) * size.height)

    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: CGFloat(spec.rotation))

    let origin = CGPoint(x: -measured.width / 2, y: -measured.height / 2)
    if let background = spec.backgroundArgb {
      let padding = pointSize * 0.2
      let box = CGRect(origin: origin, size: measured).insetBy(
        dx: -padding, dy: -padding * 0.6)
      color(background, fallback: .clear).setFill()
      UIBezierPath(roundedRect: box, cornerRadius: padding).fill()
    }
    (text as NSString).draw(at: origin, withAttributes: attributes)
    context.restoreGState()
  }

  private static func draw(sticker spec: AnnotationSpec, in context: CGContext, size: CGSize) {
    guard let path = spec.imagePath, let sticker = UIImage(contentsOfFile: path) else {
      // A missing sticker file should cost that sticker, not the whole export.
      return
    }
    let rect = pixels(spec.rect, in: size)

    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: CGFloat(spec.rotation))
    // The alpha goes on the draw call, not on the context: `draw(in:)` is
    // documented as `draw(in:blendMode:alpha:)` with alpha 1, so it overwrites
    // whatever `setAlpha` put there and a translucent sticker lands opaque.
    sticker.draw(
      in: CGRect(
        x: -rect.width / 2, y: -rect.height / 2,
        width: rect.width, height: rect.height),
      blendMode: .normal,
      alpha: CGFloat((spec.opacity ?? 1).clamped(to: 0...1)))
    context.restoreGState()
  }

  private static func draw(stroke spec: AnnotationSpec, in context: CGContext, size: CGSize) {
    guard let flat = spec.points, flat.count >= 2 else { return }

    // Width against the shorter edge, so a line keeps its weight whichever way
    // the frame is turned.
    let width = max(1, CGFloat(spec.widthFraction ?? 0.01) * min(size.width, size.height))
    context.saveGState()
    context.setStrokeColor(color(spec.colorArgb).cgColor)
    context.setFillColor(color(spec.colorArgb).cgColor)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    var points: [CGPoint] = []
    var index = 0
    while index + 1 < flat.count {
      points.append(
        CGPoint(x: CGFloat(flat[index]) * size.width, y: CGFloat(flat[index + 1]) * size.height))
      index += 2
    }

    if points.count == 1 {
      // A tap is a dot, not nothing.
      let dot = CGRect(
        x: points[0].x - width / 2, y: points[0].y - width / 2,
        width: width, height: width)
      context.fillEllipse(in: dot)
    } else {
      context.move(to: points[0])
      for point in points.dropFirst() { context.addLine(to: point) }
      context.strokePath()
    }
    context.restoreGState()
  }
}

private extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
