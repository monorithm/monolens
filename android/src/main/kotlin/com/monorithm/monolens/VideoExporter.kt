package com.monorithm.monolens

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.Crop
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.Effects
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Trims clips with Media3 Transformer and pulls filmstrip frames.
 *
 * Transformer is the ffmpeg-free path: it drives the platform's own MediaCodec
 * encoders, so there is no bundled native binary, no per-ABI APK cost, and the
 * work lands on hardware. `ffmpeg_kit` being retired is what makes this the
 * only maintained option on Android, and it is the better one anyway.
 *
 * Every Transformer call goes through [mainHandler]: the class is single-
 * threaded on the looper it was built on, and cancelling from another thread
 * throws. [jobs] is therefore main-thread-confined and needs no lock.
 */
@OptIn(UnstableApi::class)
internal class VideoExporter(
    private val context: Context,
    private val onProgress: (String, Double) -> Unit,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    private val jobs = mutableMapOf<String, Job>()

    /** Cancels that arrived before their export started. */
    private val cancelledBeforeStart = mutableSetOf<String>()

    private class Job(
        val callback: (Result<MediaInfo>) -> Unit,
    ) {
        var transformer: Transformer? = null
        var ticker: Runnable? = null
        var settled = false
    }

    fun trim(
        request: VideoTrimRequest,
        jobId: String,
        callback: (Result<MediaInfo>) -> Unit,
    ) {
        mainHandler.post {
            val job = Job(callback)
            jobs[jobId] = job
            try {
                start(request, jobId, job)
            } catch (error: MonolensException) {
                settle(jobId, Result.failure(error))
            } catch (error: Exception) {
                settle(
                    jobId,
                    Result.failure(
                        MonolensException.exportFailed(error.message ?: "Export failed"),
                    ),
                )
            }
        }
    }

    private fun start(request: VideoTrimRequest, jobId: String, job: Job) {
        val source = File(request.sourcePath)
        if (!source.exists()) throw MonolensException.notFound(request.sourcePath)

        if (cancelledBeforeStart.remove(jobId)) {
            // cancel() beat us here — honour it rather than starting the work.
            throw MonolensException.cancelled()
        }

        val durationMs = MediaProbe.probe(request.sourcePath).durationMs ?: 0L
        val startMs = max(0L, request.startMs)
        val endMs = if (durationMs > 0) minOf(request.endMs, durationMs) else request.endMs
        if (endMs <= startMs) {
            throw MonolensException.invalidRange(
                "Range ${request.startMs}-${request.endMs} ms is empty for a $durationMs ms clip",
            )
        }

        val output = File(request.outputPath)
        output.parentFile?.mkdirs()
        if (output.exists()) output.delete()

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(source))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(startMs)
                    .setEndPositionMs(endMs)
                    // Leaving this false forces a re-encode so the cut lands on
                    // the requested frame. Snapping to a sync sample would slide
                    // the in-point backwards by up to a GOP, which is wrong when
                    // the author has just placed a handle by eye.
                    .setStartsAtKeyFrame(false)
                    .build(),
            )
            .build()

        val editedMediaItem = EditedMediaItem.Builder(mediaItem)
            // Dropping the track, not exporting silence — a silent AAC track is
            // bytes the upload does not need.
            .setRemoveAudio(request.muteAudio)
            .setEffects(Effects(emptyList(), videoEffects(request)))
            .build()

        val transformer = Transformer.Builder(context)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    onProgress(jobId, 1.0)
                    settle(
                        jobId,
                        runCatching {
                            // Report the range that was asked for: the container's
                            // own duration can land a frame either side after a
                            // re-encode.
                            MediaProbe.probe(request.outputPath)
                                .copy(durationMs = endMs - startMs)
                        },
                    )
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    settle(
                        jobId,
                        Result.failure(
                            MonolensException.exportFailed(describe(exportException)),
                        ),
                    )
                }
            })
            .build()

        val ticker = object : Runnable {
            private val holder = ProgressHolder()

            override fun run() {
                val current = jobs[jobId]?.transformer ?: return
                if (current.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                    onProgress(jobId, holder.progress / 100.0)
                }
                mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
            }
        }

        job.transformer = transformer
        job.ticker = ticker
        transformer.start(editedMediaItem, request.outputPath)
        mainHandler.postDelayed(ticker, PROGRESS_INTERVAL_MS)
    }

    /**
     * Flattens an exception's cause chain into the message.
     *
     * Media3 reports the top of the chain, which for anything in the frame
     * pipeline is the useless "Video frame processing error" -- the actual
     * reason, such as a shader that failed to compile, is two causes down.
     */
    private fun describe(error: Throwable): String {
        val parts = mutableListOf<String>()
        var current: Throwable? = error
        var depth = 0
        while (current != null && depth < 5) {
            current.message?.takeIf { it.isNotBlank() }?.let(parts::add)
            current = current.cause
            depth++
        }
        return parts.distinct().joinToString(": ").ifBlank { "Export failed" }
    }

    /**
     * The frame pipeline: crop, then rotate, then the flattened overlay.
     *
     * Order matters and mirrors the still path exactly, because an annotation
     * placed against the output frame has to land in the same place on both.
     * Media3 applies effects in list order, so this reads as it runs.
     */
    private fun videoEffects(request: VideoTrimRequest): List<Effect> {
        val effects = mutableListOf<Effect>()

        request.crop?.let { rect ->
            // Crop takes normalized device coordinates: -1..1, origin centre,
            // y up. The wire rect is 0..1 from the top-left.
            effects += Crop(
                (2 * rect.left - 1).toFloat(),
                (2 * (rect.left + rect.width) - 1).toFloat(),
                (1 - 2 * (rect.top + rect.height)).toFloat(),
                (1 - 2 * rect.top).toFloat(),
            )
        }

        val degrees = when (request.rotation) {
            MonoRotation.NONE -> 0f
            MonoRotation.QUARTER_TURN -> 90f
            MonoRotation.HALF_TURN -> 180f
            MonoRotation.THREE_QUARTER_TURNS -> 270f
        }
        if (degrees != 0f) {
            // Media3 rotates counter-clockwise for a positive angle; MonoRotation
            // names a clockwise turn.
            effects += ScaleAndRotateTransformation.Builder()
                .setRotationDegrees(-degrees)
                .build()
        }

        // Blur before the overlay and after the geometry: it samples the frame,
        // so it belongs to the picture, and its regions are normalized against
        // the cropped and rotated output. A caption drawn over a blurred face
        // then stays legible, matching the still path.
        val blurred = request.annotations.filter { it.kind == AnnotationKind.BLUR }
        if (blurred.isNotEmpty()) {
            effects += MaskedBlurEffect(blurred)
        }

        if (request.flipHorizontal) {
            // A separate effect rather than setScale on the rotation above:
            // Media3 applies a list in order, so this mirrors the already
            // rotated frame. Folding both into one transformation would scale
            // first and mirror the *source*, which is the opposite convention
            // to the still path.
            effects += ScaleAndRotateTransformation.Builder()
                .setScale(-1f, 1f)
                .build()
        }

        val painted = request.annotations.filter { it.kind != AnnotationKind.BLUR }
        if (painted.isNotEmpty()) {
            val size = outputSize(request)
            AnnotationRenderer.overlayLayer(request.annotations, size.first, size.second)
                ?.let { layer ->
                    effects += OverlayEffect(
                        ImmutableList.of<TextureOverlay>(
                            BitmapOverlay.createStaticBitmapOverlay(layer),
                        ),
                    )
                }
        }

        return effects
    }

    /**
     * The frame size the overlay has to be rasterized at — the source's display
     * size with the crop and the rotation applied, which is what the annotation
     * coordinates were normalized against.
     */
    private fun outputSize(request: VideoTrimRequest): Pair<Int, Int> {
        val info = runCatching { MediaProbe.probe(request.sourcePath) }.getOrNull()
        var width = (info?.width ?: 1080L).toInt()
        var height = (info?.height ?: 1920L).toInt()

        request.crop?.let { rect ->
            width = max(1, (width * rect.width).roundToInt())
            height = max(1, (height * rect.height).roundToInt())
        }
        val turned = request.rotation == MonoRotation.QUARTER_TURN ||
            request.rotation == MonoRotation.THREE_QUARTER_TURNS
        return if (turned) height to width else width to height
    }

    /**
     * `Transformer.cancel()` fires no listener callback, so the Dart future
     * waiting on this job would hang forever if cancel did not settle it here.
     */
    fun cancel(jobId: String) {
        mainHandler.post {
            val job = jobs[jobId]
            if (job == null) {
                // The export has not started yet; remember so start() refuses to.
                cancelledBeforeStart.add(jobId)
                return@post
            }
            runCatching { job.transformer?.cancel() }
            settle(jobId, Result.failure(MonolensException.cancelled()))
        }
    }

    /** Completes a job exactly once — a second completion would throw in Dart. */
    private fun settle(jobId: String, result: Result<MediaInfo>) {
        val job = jobs[jobId] ?: return
        if (job.settled) return
        job.settled = true
        jobs.remove(jobId)
        job.ticker?.let(mainHandler::removeCallbacks)
        job.callback(result)
    }

    // Filmstrip

    fun thumbnails(path: String, atMs: List<Long>, maxDimension: Long): List<ByteArray> {
        if (!File(path).exists()) throw MonolensException.notFound(path)

        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val size = maxDimension.toInt().coerceAtLeast(1)

            atMs.map { milliseconds ->
                // OPTION_CLOSEST_SYNC decodes from the nearest keyframe rather
                // than walking forward to an exact frame. A filmstrip is a
                // scrubbing aid, and exact seeking here is an order of magnitude
                // slower for no visible gain.
                val timeUs = max(0L, milliseconds) * 1000
                val frame = runCatching {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                        // Decodes straight to the thumbnail size. The fallback
                        // below decodes the frame at full resolution and then
                        // throws most of it away.
                        retriever.getScaledFrameAtTime(
                            timeUs,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                            size,
                            size,
                        )
                    } else {
                        retriever.getFrameAtTime(
                            timeUs,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                        )
                    }
                }.getOrNull()

                // One unreadable frame should not fail the strip; an empty entry
                // is the caller's cue to draw a placeholder.
                frame?.let { encode(it, size) } ?: ByteArray(0)
            }
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun encode(frame: Bitmap, maxDimension: Int): ByteArray {
        val longest = max(frame.width, frame.height)
        val scaled = if (maxDimension in 1 until longest) {
            val factor = maxDimension.toFloat() / longest
            Bitmap.createScaledBitmap(
                frame,
                (frame.width * factor).toInt().coerceAtLeast(1),
                (frame.height * factor).toInt().coerceAtLeast(1),
                true,
            )
        } else {
            frame
        }

        return ByteArrayOutputStream().use { stream ->
            scaled.compress(Bitmap.CompressFormat.JPEG, 70, stream)
            if (scaled != frame) scaled.recycle()
            frame.recycle()
            stream.toByteArray()
        }
    }

    private companion object {
        const val PROGRESS_INTERVAL_MS = 100L
    }
}
