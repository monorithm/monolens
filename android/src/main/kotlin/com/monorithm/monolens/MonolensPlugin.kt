package com.monorithm.monolens

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The Android end of the Pigeon bridge.
 *
 * Nothing here does real work: it routes onto a background executor and hands
 * off to [MediaProbe], [ImageTransformer] and [VideoExporter]. Decoding a 12 MP
 * still on the platform thread would stall the very viewfinder the author is
 * looking at. Trimming is the exception — Media3's Transformer wants a looper
 * thread and manages its own workers, so [VideoExporter] hops to main itself.
 */
class MonolensPlugin : FlutterPlugin, MonolensHostApi {

    private lateinit var context: Context
    private lateinit var exporter: VideoExporter
    private lateinit var progress: MonolensFlutterApi
    private lateinit var worker: ExecutorService

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        worker = Executors.newCachedThreadPool()
        progress = MonolensFlutterApi(binding.binaryMessenger)
        exporter = VideoExporter(context) { jobId, value ->
            // Progress may arrive off the platform thread; the channel wants main.
            mainHandler.post { progress.onProgress(jobId, value) { } }
        }
        MonolensHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        MonolensHostApi.setUp(binding.binaryMessenger, null)
        worker.shutdown()
    }

    // MonolensHostApi

    override fun cacheDirectory(): String = context.cacheDir.absolutePath

    override fun probe(path: String, callback: (Result<MediaInfo>) -> Unit) {
        worker.execute { reply(callback) { MediaProbe.probe(path) } }
    }

    override fun editImage(
        request: ImageEditRequest,
        callback: (Result<MediaInfo>) -> Unit,
    ) {
        worker.execute { reply(callback) { ImageTransformer.apply(request) } }
    }

    override fun trimVideo(
        request: VideoTrimRequest,
        jobId: String,
        callback: (Result<MediaInfo>) -> Unit,
    ) {
        exporter.trim(request, jobId) { result ->
            mainHandler.post { callback(result.mapFailure()) }
        }
    }

    override fun cancel(jobId: String) {
        exporter.cancel(jobId)
    }

    override fun videoThumbnails(
        path: String,
        atMs: List<Long>,
        maxDimension: Long,
        callback: (Result<List<ByteArray>>) -> Unit,
    ) {
        worker.execute {
            reply(callback) { exporter.thumbnails(path, atMs, maxDimension) }
        }
    }

    // Plumbing

    /**
     * Runs [body] and posts its outcome back on the main thread, which is where
     * Pigeon's reply handlers expect to be called.
     */
    private fun <T> reply(callback: (Result<T>) -> Unit, body: () -> T) {
        val result = runCatching(body).mapFailure()
        mainHandler.post { callback(result) }
    }

    /**
     * Turns a [MonolensException] into the [FlutterError] whose code Dart
     * branches on (`monolens/cancelled` in particular). Anything else passes
     * through as-is.
     */
    private fun <T> Result<T>.mapFailure(): Result<T> {
        val error = exceptionOrNull() ?: return this
        return if (error is MonolensException) {
            Result.failure(error.toFlutterError())
        } else {
            this
        }
    }
}
