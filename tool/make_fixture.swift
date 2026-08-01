// Generates the integration-test fixture: a 5 s H.264 clip with an AAC tone,
// plus a still. Run from the repo root:
//
//   swift tool/make_fixture.swift
//
// Written rather than committed so the repo carries no third-party media, and
// so the fixture's exact duration and dimensions are what the tests assert
// against. Output lands in example/assets/.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 640
let height = 360
let fps: Int32 = 30
let seconds = 5
let sampleRate: Double = 44100

let assetsDirectory = URL(fileURLWithPath: "example/assets")
try? FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

let videoURL = assetsDirectory.appendingPathComponent("fixture.mp4")
let imageURL = assetsDirectory.appendingPathComponent("fixture.jpg")
let stickerURL = assetsDirectory.appendingPathComponent("fixture_sticker.png")
try? FileManager.default.removeItem(at: videoURL)
try? FileManager.default.removeItem(at: imageURL)
try? FileManager.default.removeItem(at: stickerURL)

// MARK: - Still

func makeStill() {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
  else { fatalError("no context") }

  // A quartered frame, so a crop test can assert which quadrant it kept.
  let quadrants: [(CGRect, CGColor)] = [
    (CGRect(x: 0, y: 300, width: 400, height: 300), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
    (CGRect(x: 400, y: 300, width: 400, height: 300), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
    (CGRect(x: 0, y: 0, width: 400, height: 300), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
    (CGRect(x: 400, y: 0, width: 400, height: 300), CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
  ]
  for (rect, color) in quadrants {
    context.setFillColor(color)
    context.fill(rect)
  }

  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
  else { fatalError("no destination") }
  CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
  CGImageDestinationFinalize(destination)
  print("wrote \(imageURL.path) (800x600)")
}

// MARK: - Sticker

/// A flat magenta square, opaque edge to edge.
///
/// Magenta because none of the still's four quadrants is magenta, so a sampled
/// pixel says unambiguously whether the sticker reached it. Edge to edge
/// because that is what makes it possible to assert the *shape* of the
/// composite: both platforms stretch a sticker to fill its rect, so a
/// non-square rect should come back magenta right into its corners rather than
/// letterboxed.
func makeSticker() {
  let side = 128
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fatalError("no context") }

  context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: side, height: side))

  guard let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      stickerURL as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("no destination") }
  CGImageDestinationAddImage(destination, image, nil)
  CGImageDestinationFinalize(destination)
  print("wrote \(stickerURL.path) (\(side)x\(side) magenta)")
}

// MARK: - Clip

func makeClip() {
  let writer = try! AVAssetWriter(outputURL: videoURL, fileType: .mp4)

  let videoInput = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 1_200_000,
        // A keyframe every second, so a mid-GOP trim is genuinely exercised:
        // a cut at 1.5 s cannot be served by snapping to a sync sample.
        AVVideoMaxKeyFrameIntervalKey: Int(fps),
      ],
    ])
  videoInput.expectsMediaDataInRealTime = false

  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoInput,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ])

  let audioInput = AVAssetWriterInput(
    mediaType: .audio,
    outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64000,
    ])
  audioInput.expectsMediaDataInRealTime = false

  writer.add(videoInput)
  writer.add(audioInput)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)

  // Video: a sweeping hue plus a per-second counter block, so a trimmed clip's
  // first frame visibly identifies where the cut landed.
  let totalFrames = Int(fps) * seconds
  let queue = DispatchQueue(label: "fixture.video")
  let videoDone = DispatchSemaphore(value: 0)
  var frame = 0

  videoInput.requestMediaDataWhenReady(on: queue) {
    while videoInput.isReadyForMoreMediaData {
      if frame >= totalFrames {
        videoInput.markAsFinished()
        videoDone.signal()
        return
      }
      guard let pool = adaptor.pixelBufferPool else { continue }
      var buffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
      guard let pixelBuffer = buffer else { continue }

      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!

      let progress = CGFloat(frame) / CGFloat(totalFrames)
      context.setFillColor(
        CGColor(red: progress, green: 1 - progress, blue: 0.5, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))

      let second = frame / Int(fps)
      context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      context.fill(CGRect(x: 20 + second * 60, y: 20, width: 50, height: 50))

      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      adaptor.append(
        pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
      frame += 1
    }
  }

  // Audio: a 440 Hz tone in one-second blocks.
  let audioQueue = DispatchQueue(label: "fixture.audio")
  let audioDone = DispatchSemaphore(value: 0)
  var block = 0

  var streamDescription = AudioStreamBasicDescription(
    mSampleRate: sampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
    mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
  var format: CMAudioFormatDescription?
  CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault, asbd: &streamDescription, layoutSize: 0, layout: nil,
    magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

  audioInput.requestMediaDataWhenReady(on: audioQueue) {
    while audioInput.isReadyForMoreMediaData {
      if block >= seconds {
        audioInput.markAsFinished()
        audioDone.signal()
        return
      }
      let frames = Int(sampleRate)
      var samples = [Int16](repeating: 0, count: frames)
      for i in 0..<frames {
        let t = Double(block * frames + i) / sampleRate
        samples[i] = Int16(sin(2 * .pi * 440 * t) * 8000)
      }

      var blockBuffer: CMBlockBuffer?
      let byteCount = frames * 2
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer)
      guard let blockBuffer else { continue }
      _ = samples.withUnsafeBytes { pointer in
        CMBlockBufferReplaceDataBytes(
          with: pointer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0,
          dataLength: byteCount)
      }

      var sampleBuffer: CMSampleBuffer?
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: CMTime(
          value: CMTimeValue(block * frames), timescale: CMTimeScale(sampleRate)),
        decodeTimeStamp: .invalid)
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sampleBuffer)
      if let sampleBuffer { audioInput.append(sampleBuffer) }
      block += 1
    }
  }

  videoDone.wait()
  audioDone.wait()

  let finished = DispatchSemaphore(value: 0)
  writer.finishWriting { finished.signal() }
  finished.wait()

  if writer.status != .completed {
    fatalError("writer failed: \(writer.error?.localizedDescription ?? "unknown")")
  }
  let size = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size]) as? Int64
  print("wrote \(videoURL.path) (\(width)x\(height), \(seconds)s, \(size ?? 0) bytes)")
}

makeStill()
makeSticker()
makeClip()
