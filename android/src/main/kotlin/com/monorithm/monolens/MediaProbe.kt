package com.monorithm.monolens

import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import androidx.exifinterface.media.ExifInterface
import java.io.File

/**
 * Reads dimensions, duration and size off a file without decoding it.
 *
 * Both branches report *display* dimensions rather than stored ones: a still
 * carries an EXIF orientation tag and a clip carries a rotation hint, and in
 * both cases the stored buffer is often sideways relative to what the author
 * saw. Dart's `CropRect` resolves against these numbers, so the transformers
 * below have to work in the same upright space.
 */
internal object MediaProbe {

    fun probe(path: String): MediaInfo {
        val file = File(path)
        if (!file.exists()) throw MonolensException.notFound(path)
        val byteSize = file.length()

        return probeImage(path, byteSize)
            ?: probeVideo(path, byteSize)
            ?: throw MonolensException.unsupported(path)
    }

    private fun probeImage(path: String, byteSize: Long): MediaInfo? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null

        val quarterTurned = runCatching {
            when (ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )) {
                ExifInterface.ORIENTATION_ROTATE_90,
                ExifInterface.ORIENTATION_ROTATE_270,
                ExifInterface.ORIENTATION_TRANSPOSE,
                ExifInterface.ORIENTATION_TRANSVERSE,
                -> true

                else -> false
            }
        }.getOrDefault(false)

        return MediaInfo(
            path = path,
            width = (if (quarterTurned) options.outHeight else options.outWidth).toLong(),
            height = (if (quarterTurned) options.outWidth else options.outHeight).toLong(),
            durationMs = null,
            byteSize = byteSize,
        )
    }

    private fun probeVideo(path: String, byteSize: Long): MediaInfo? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val width = retriever.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val height = retriever.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            if (width == null || height == null) return null

            // The rotation hint is metadata, not pixels: a portrait recording is
            // stored landscape with a 90 tag, and the player swaps it back.
            val rotation = retriever.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: 0
            val quarterTurned = rotation == 90 || rotation == 270

            MediaInfo(
                path = path,
                width = (if (quarterTurned) height else width).toLong(),
                height = (if (quarterTurned) width else height).toLong(),
                durationMs = retriever.int(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong()
                    ?: 0L,
                byteSize = byteSize,
            )
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun MediaMetadataRetriever.int(key: Int): Int? =
        extractMetadata(key)?.toIntOrNull()
}

/**
 * The failures the host API reports back to Dart. The codes are what
 * `MediaEditException.code` carries, so Dart can branch on them — most
 * importantly `monolens/cancelled`, which the composer swallows rather than
 * surfacing as a failure.
 */
internal class MonolensException(
    val code: String,
    override val message: String,
) : Exception(message) {

    fun toFlutterError(): FlutterError = FlutterError(code, message, null)

    companion object {
        fun notFound(path: String) = MonolensException("monolens/not-found", "No file at $path")

        fun unsupported(path: String) =
            MonolensException("monolens/unsupported", "Unsupported media at $path")

        fun decodeFailed(message: String) =
            MonolensException("monolens/decode-failed", message)

        fun encodeFailed(message: String) =
            MonolensException("monolens/encode-failed", message)

        fun invalidRange(message: String) =
            MonolensException("monolens/invalid-range", message)

        fun exportFailed(message: String) =
            MonolensException("monolens/export-failed", message)

        fun cancelled() = MonolensException("monolens/cancelled", "Export cancelled")
    }
}
