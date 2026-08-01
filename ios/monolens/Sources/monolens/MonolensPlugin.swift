import Flutter
import UIKit

/// The iOS end of the Pigeon bridge.
///
/// Nothing here does real work: it routes onto a background queue and hands off
/// to `MediaProbe`, `ImageTransformer` and `VideoExporter`. Decoding a 12 MP
/// still or exporting a clip on the platform thread would stall the very
/// viewfinder the author is looking at.
public class MonolensPlugin: NSObject, FlutterPlugin, MonolensHostApi {

  private var exporter: VideoExporter!
  private let queue = DispatchQueue(
    label: "com.monorithm.monolens.work", qos: .userInitiated, attributes: .concurrent)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MonolensPlugin()
    let messenger = registrar.messenger()

    let progress = MonolensFlutterApi(binaryMessenger: messenger)
    instance.exporter = VideoExporter { jobId, value in
      // Progress arrives on an export queue; the channel wants the main thread.
      DispatchQueue.main.async {
        progress.onProgress(jobId: jobId, progress: value) { _ in }
      }
    }

    MonolensHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    registrar.publish(instance)
  }

  // MARK: - MonolensHostApi

  func cacheDirectory() throws -> String {
    // Trailing-slash-free, because Dart joins with an explicit separator.
    (NSTemporaryDirectory() as NSString).standardizingPath
  }

  func probe(path: String, completion: @escaping (Result<MediaInfo, Error>) -> Void) {
    queue.async {
      do {
        Self.reply(completion, .success(try MediaProbe.probe(path: path)))
      } catch {
        Self.reply(completion, .failure(Self.mapped(error)))
      }
    }
  }

  func editImage(
    request: ImageEditRequest, completion: @escaping (Result<MediaInfo, Error>) -> Void
  ) {
    queue.async {
      do {
        Self.reply(completion, .success(try ImageTransformer.apply(request)))
      } catch {
        Self.reply(completion, .failure(Self.mapped(error)))
      }
    }
  }

  func trimVideo(
    request: VideoTrimRequest, jobId: String,
    completion: @escaping (Result<MediaInfo, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.exporter.trim(request: request, jobId: jobId) { result in
        Self.reply(completion, result.mapError(Self.mapped))
      }
    }
  }

  func cancel(jobId: String) throws {
    exporter.cancel(jobId: jobId)
  }

  func videoThumbnails(
    path: String, atMs: [Int64], maxDimension: Int64,
    completion: @escaping (Result<[FlutterStandardTypedData], Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let frames = try self.exporter.thumbnails(
          path: path, atMs: atMs, maxDimension: maxDimension)
        Self.reply(completion, .success(frames.map { FlutterStandardTypedData(bytes: $0) }))
      } catch {
        Self.reply(completion, .failure(Self.mapped(error)))
      }
    }
  }

  // MARK: - Plumbing

  /// Pigeon's reply handlers post onto the platform channel, which expects the
  /// main thread.
  private static func reply<T>(
    _ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>
  ) {
    DispatchQueue.main.async { completion(result) }
  }

  /// Turns a `MonolensError` into the `PigeonError` whose code Dart branches on
  /// (`monolens/cancelled` in particular). Anything else passes through.
  private static func mapped(_ error: Error) -> Error {
    (error as? MonolensError)?.pigeonError ?? error
  }
}
