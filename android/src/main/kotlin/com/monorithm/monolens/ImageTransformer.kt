package com.monorithm.monolens

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import java.io.File
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Crop, rotate, flip, downscale and re-encode a still.
 *
 * One decode and one bitmap op. The output size is worked out first, from
 * bounds metadata alone, and the decode then subsamples to just past what that
 * output needs — cropping a 12 MP photo to a 1080 px square never allocates the
 * 12 MP bitmap, which is also what keeps this off the OOM killer's radar.
 * `createBitmap` takes a sub-rectangle *and* a matrix, so the crop, rotation,
 * mirror and final scale all happen in that single call rather than in the
 * three chained allocations this used to do.
 */
internal object ImageTransformer {

    private data class Rect(val x: Int, val y: Int, val width: Int, val height: Int)

    fun apply(request: ImageEditRequest): MediaInfo {
        if (!File(request.sourcePath).exists()) {
            throw MonolensException.notFound(request.sourcePath)
        }

        val orientation = orientationOf(request.sourcePath)
        val full = uprightSize(request.sourcePath, orientation)
        val crop = cropRect(request.crop, full)
        val output = outputSize(crop, request.rotation, request.maxDimension)

        // Whole frame : kept region :: what we decode : output.
        val cropLongest = max(crop.width, crop.height)
        val fullLongest = max(full.width, full.height)
        val wanted = if (cropLongest <= 0) {
            fullLongest
        } else {
            ceil(
                max(output.width, output.height).toDouble() * fullLongest / cropLongest,
            ).toInt()
        }

        var bitmap = decode(request.sourcePath, sampleSize(fullLongest, wanted))
        try {
            // Only when the tag says so — most captures are already upright and
            // skip this pass entirely.
            bitmap = bitmap.uprighted(orientation)
            bitmap = bitmap.transformed(crop, full, output, request)

            if (request.annotations.isNotEmpty()) {
                // Blur first: it samples the picture, so it belongs to it. Text,
                // stickers and strokes then go over the result, which is what
                // keeps a caption across a blurred face legible.
                bitmap = AnnotationRenderer.applyBlur(bitmap, request.annotations)
                bitmap = bitmap.withOverlay(
                    AnnotationRenderer.overlayLayer(
                        request.annotations,
                        bitmap.width,
                        bitmap.height,
                    ),
                )
            }

            val format = when (request.format) {
                MonoImageFormat.PNG -> Bitmap.CompressFormat.PNG
                MonoImageFormat.JPEG -> Bitmap.CompressFormat.JPEG
            }
            val file = File(request.outputPath)
            file.parentFile?.mkdirs()
            file.outputStream().use { stream ->
                if (!bitmap.compress(format, request.quality.toInt().coerceIn(1, 100), stream)) {
                    throw MonolensException.encodeFailed("Could not encode to ${request.format}")
                }
            }

            return MediaInfo(
                path = request.outputPath,
                width = bitmap.width.toLong(),
                height = bitmap.height.toLong(),
                durationMs = null,
                byteSize = file.length(),
            )
        } finally {
            bitmap.recycle()
        }
    }

    // Geometry — all in full-resolution upright pixels, so the output dimensions
    // are exact and independent of how far the decoder subsampled.

    private fun orientationOf(path: String): Int = runCatching {
        ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)

    private fun uprightSize(path: String, orientation: Int): Rect {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) {
            throw MonolensException.decodeFailed("Could not read $path")
        }
        val turned = orientation == ExifInterface.ORIENTATION_ROTATE_90 ||
            orientation == ExifInterface.ORIENTATION_ROTATE_270 ||
            orientation == ExifInterface.ORIENTATION_TRANSPOSE ||
            orientation == ExifInterface.ORIENTATION_TRANSVERSE
        return Rect(
            0,
            0,
            if (turned) options.outHeight else options.outWidth,
            if (turned) options.outWidth else options.outHeight,
        )
    }

    private fun cropRect(rect: NormalizedRect?, full: Rect): Rect {
        if (rect == null) return full
        val x = (rect.left * full.width).roundToInt().coerceIn(0, full.width - 1)
        val y = (rect.top * full.height).roundToInt().coerceIn(0, full.height - 1)
        return Rect(
            x,
            y,
            (rect.width * full.width).roundToInt().coerceIn(1, full.width - x),
            (rect.height * full.height).roundToInt().coerceIn(1, full.height - y),
        )
    }

    private fun outputSize(crop: Rect, rotation: MonoRotation, cap: Long?): Rect {
        val turned = rotation == MonoRotation.QUARTER_TURN ||
            rotation == MonoRotation.THREE_QUARTER_TURNS
        var width = if (turned) crop.height else crop.width
        var height = if (turned) crop.width else crop.height

        val limit = cap?.toInt()
        if (limit != null && limit >= 1 && max(width, height) > limit) {
            val factor = limit.toDouble() / max(width, height)
            width = (width * factor).roundToInt().coerceAtLeast(1)
            height = (height * factor).roundToInt().coerceAtLeast(1)
        }
        return Rect(0, 0, width, height)
    }

    /** The largest power-of-two subsample that still leaves [wanted] pixels. */
    private fun sampleSize(fullLongest: Int, wanted: Int): Int {
        if (wanted <= 0) return 1
        var sample = 1
        while (fullLongest / (sample * 2) >= wanted) sample *= 2
        return sample
    }

    // Pixels

    private fun decode(path: String, sampleSize: Int): Bitmap {
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            // The transform below reads every pixel exactly once, so there is
            // nothing to gain from a mutable or higher-precision config.
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(path, options)
            ?: throw MonolensException.decodeFailed("Could not decode $path")
    }

    /** Draws [layer] over this bitmap, making it mutable first if it is not. */
    private fun Bitmap.withOverlay(layer: Bitmap?): Bitmap {
        if (layer == null) return this
        val target = if (isMutable) this else copy(Bitmap.Config.ARGB_8888, true)
        if (target !== this) recycle()
        Canvas(target).drawBitmap(layer, 0f, 0f, null)
        layer.recycle()
        return target
    }

    private fun Bitmap.uprighted(orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }

            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }

            else -> return this
        }
        val result = Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
        if (result != this) recycle()
        return result
    }

    /** Crop, scale, rotate and mirror in one allocation. */
    private fun Bitmap.transformed(
        crop: Rect,
        full: Rect,
        output: Rect,
        request: ImageEditRequest,
    ): Bitmap {
        // The decode was approximate, so map the crop into whatever came back
        // rather than assuming it honoured the request exactly.
        val scaleX = width.toDouble() / full.width
        val scaleY = height.toDouble() / full.height
        val x = (crop.x * scaleX).toInt().coerceIn(0, width - 1)
        val y = (crop.y * scaleY).toInt().coerceIn(0, height - 1)
        val w = (crop.width * scaleX).roundToInt().coerceIn(1, width - x)
        val h = (crop.height * scaleY).roundToInt().coerceIn(1, height - y)

        val turned = request.rotation == MonoRotation.QUARTER_TURN ||
            request.rotation == MonoRotation.THREE_QUARTER_TURNS
        // What the region must measure *before* the rotation swaps its axes.
        val preWidth = if (turned) output.height else output.width
        val preHeight = if (turned) output.width else output.height

        val degrees = when (request.rotation) {
            MonoRotation.NONE -> 0f
            MonoRotation.QUARTER_TURN -> 90f
            MonoRotation.HALF_TURN -> 180f
            MonoRotation.THREE_QUARTER_TURNS -> 270f
        }

        // post* appends, so these apply in written order: scale, then rotate,
        // then mirror about the output's vertical axis. iOS composes the same
        // order, so a rotate-and-flip lands identically on both platforms.
        val matrix = Matrix()
        matrix.postScale(preWidth.toFloat() / w, preHeight.toFloat() / h)
        matrix.postRotate(degrees)
        if (request.flipHorizontal) matrix.postScale(-1f, 1f)

        var result = Bitmap.createBitmap(this, x, y, w, h, matrix, true)
        if (result != this) recycle()

        // Rounding inside createBitmap can land a pixel either side; the API
        // contract promises exact dimensions, so settle it here. Rarely runs.
        if (result.width != output.width || result.height != output.height) {
            val exact = Bitmap.createScaledBitmap(result, output.width, output.height, true)
            if (exact != result) result.recycle()
            result = exact
        }
        return result
    }
}
