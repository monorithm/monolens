package com.monorithm.monolens

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Paints annotations onto media.
 *
 * Shared by the still and the clip paths on purpose: an annotation has to mean
 * the same thing in a JPEG and in every frame of an MP4, and one implementation
 * of the geometry is the only way to guarantee that.
 *
 * The split that matters is blur versus everything else. Text, stickers and
 * strokes never read the media, so they flatten into one transparent layer --
 * drawn once for a still, handed to Media3 as a `BitmapOverlay` for a clip.
 * Blur samples the source and so cannot be flattened.
 */
internal object AnnotationRenderer {

    /** Everything except blur, on one transparent layer. Null when empty. */
    fun overlayLayer(annotations: List<AnnotationSpec>, width: Int, height: Int): Bitmap? {
        val painted = annotations.filter { it.kind != AnnotationKind.BLUR }
        if (painted.isEmpty() || width < 1 || height < 1) return null

        val layer = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(layer)
        painted.forEach { spec ->
            when (spec.kind) {
                AnnotationKind.TEXT -> drawText(canvas, spec, width, height)
                AnnotationKind.STICKER -> drawSticker(canvas, spec, width, height)
                AnnotationKind.STROKE -> drawStroke(canvas, spec, width, height)
                AnnotationKind.BLUR -> Unit
            }
        }
        return layer
    }

    /**
     * White where the media should be blurred, black elsewhere. Null when no
     * blur was asked for.
     *
     * Used by the video path, which uploads this as a texture the shader
     * samples rather than passing regions as uniforms. That keeps the shader
     * free of array uniforms — which GLES reports under the name `uName[0]`
     * and are easy to fail to bind — and it means the oval geometry is decided
     * once here, in the same code the still path uses.
     */
    fun blurMask(annotations: List<AnnotationSpec>, width: Int, height: Int): Bitmap? {
        val regions = annotations.filter { it.kind == AnnotationKind.BLUR }
        if (regions.isEmpty() || width < 1 || height < 1) return null

        val mask = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(mask)
        canvas.drawColor(Color.BLACK)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

        regions.forEach { spec ->
            val rect = RectF(pixels(spec.rect, width, height))
            if (spec.shape == BlurShapeSpec.OVAL) {
                canvas.drawOval(rect, paint)
            } else {
                canvas.drawRect(rect, paint)
            }
        }
        return mask
    }

    /**
     * Blurs the regions of [bitmap] the spec names, in place on a copy.
     *
     * Each region is blurred on its own rather than the whole frame being
     * blurred and masked back: the regions are small, and blurring only what
     * was asked for is both faster and free of edge bleed from the surrounding
     * picture.
     */
    fun applyBlur(bitmap: Bitmap, annotations: List<AnnotationSpec>): Bitmap {
        val regions = annotations.filter { it.kind == AnnotationKind.BLUR }
        if (regions.isEmpty()) return bitmap

        val target = if (bitmap.isMutable) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, true)
        if (target !== bitmap) bitmap.recycle()

        val canvas = Canvas(target)
        regions.forEach { spec ->
            val rect = pixels(spec.rect, target.width, target.height)
            if (rect.width() < 2 || rect.height() < 2) return@forEach

            val patch = Bitmap.createBitmap(target, rect.left, rect.top, rect.width(), rect.height())
            val radius = blurRadius(spec, rect)
            val blurred = boxBlur(patch, radius)
            if (blurred !== patch) patch.recycle()

            if (spec.shape == BlurShapeSpec.OVAL) {
                // Feathered so an oval over a face does not read as a sticker
                // with a hard edge.
                val paint = Paint(Paint.ANTI_ALIAS_FLAG)
                val saved = canvas.save()
                val path = Path().apply { addOval(RectF(rect), Path.Direction.CW) }
                canvas.clipPath(path)
                canvas.drawBitmap(blurred, null, RectF(rect), paint)
                canvas.restoreToCount(saved)
            } else {
                canvas.drawBitmap(blurred, null, RectF(rect), null)
            }
            blurred.recycle()
        }
        return target
    }

    /**
     * A two-pass box blur.
     *
     * Deliberately not RenderScript (removed) and not RenderEffect (API 31 and
     * tied to a RenderNode). Two separable passes over a region that is a small
     * fraction of the frame is quick, predictable, and works on every supported
     * API level.
     */
    private fun boxBlur(source: Bitmap, radius: Int): Bitmap {
        if (radius < 1) return source
        val width = source.width
        val height = source.height

        val pixels = IntArray(width * height)
        source.getPixels(pixels, 0, width, 0, 0, width, height)
        val horizontal = IntArray(width * height)
        val vertical = IntArray(width * height)

        // Separable: a 2D box blur is a horizontal pass followed by a vertical
        // one, which is O(radius) per pixel instead of O(radius squared).
        for (y in 0 until height) {
            for (x in 0 until width) {
                horizontal[y * width + x] = average(pixels, width, height, x, y, radius, true)
            }
        }
        for (y in 0 until height) {
            for (x in 0 until width) {
                vertical[y * width + x] = average(horizontal, width, height, x, y, radius, false)
            }
        }

        return Bitmap.createBitmap(vertical, width, height, Bitmap.Config.ARGB_8888)
    }

    /** Mean of the window centred on (x, y), clipped at the edges. */
    private fun average(
        pixels: IntArray,
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        radius: Int,
        horizontal: Boolean,
    ): Int {
        var a = 0
        var r = 0
        var g = 0
        var b = 0
        var count = 0

        for (offset in -radius..radius) {
            val sampleX = if (horizontal) x + offset else x
            val sampleY = if (horizontal) y else y + offset
            if (sampleX < 0 || sampleX >= width || sampleY < 0 || sampleY >= height) continue

            val pixel = pixels[sampleY * width + sampleX]
            a += (pixel ushr 24) and 0xFF
            r += (pixel ushr 16) and 0xFF
            g += (pixel ushr 8) and 0xFF
            b += pixel and 0xFF
            count++
        }

        if (count == 0) return pixels[y * width + x]
        return ((a / count) shl 24) or ((r / count) shl 16) or ((g / count) shl 8) or (b / count)
    }

    /**
     * Scaled against the region's shorter edge rather than a constant, so a
     * radius chosen for a large region does not erase a small one -- and so
     * `strength` means the same thing at any export resolution.
     */
    private fun blurRadius(spec: AnnotationSpec, rect: Rect): Int {
        val strength = (spec.strength ?: 0.5).coerceIn(0.0, 1.0)
        val shorter = min(rect.width(), rect.height())
        return max(1, (shorter * 0.12 * strength).roundToInt())
    }

    // Individual annotations

    private fun pixels(rect: NormalizedRect?, width: Int, height: Int): Rect {
        if (rect == null) return Rect(0, 0, width, height)
        val left = (rect.left * width).roundToInt().coerceIn(0, width - 1)
        val top = (rect.top * height).roundToInt().coerceIn(0, height - 1)
        val right = ((rect.left + rect.width) * width).roundToInt().coerceIn(left + 1, width)
        val bottom = ((rect.top + rect.height) * height).roundToInt().coerceIn(top + 1, height)
        return Rect(left, top, right, bottom)
    }

    private fun argb(value: Long?, fallback: Int = Color.WHITE): Int =
        value?.toInt() ?: fallback

    private fun drawText(canvas: Canvas, spec: AnnotationSpec, width: Int, height: Int) {
        val text = spec.text
        if (text.isNullOrEmpty()) return

        // Size from a fraction of the output height, so the same annotation
        // looks identical at 720p and 4K. The system typeface shapes emoji,
        // which is why emoji needs no separate primitive.
        val textSize = max(1.0, (spec.heightFraction ?: 0.08) * height).toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.textSize = textSize
            color = argb(spec.colorArgb)
            isFakeBoldText = true
            textAlign = Paint.Align.CENTER
        }

        val centerX = ((spec.centerX ?: 0.5) * width).toFloat()
        val centerY = ((spec.centerY ?: 0.5) * height).toFloat()
        val metrics = paint.fontMetrics
        // Canvas draws from the baseline; this centres the glyph box instead.
        val baseline = centerY - (metrics.ascent + metrics.descent) / 2

        val saved = canvas.save()
        canvas.rotate(Math.toDegrees(spec.rotation).toFloat(), centerX, centerY)

        spec.backgroundArgb?.let { background ->
            val padding = textSize * 0.2f
            val half = paint.measureText(text) / 2
            val box = RectF(
                centerX - half - padding,
                baseline + metrics.ascent - padding * 0.6f,
                centerX + half + padding,
                baseline + metrics.descent + padding * 0.6f,
            )
            canvas.drawRoundRect(
                box,
                padding,
                padding,
                Paint(Paint.ANTI_ALIAS_FLAG).apply { color = argb(background, Color.TRANSPARENT) },
            )
        }

        canvas.drawText(text, centerX, baseline, paint)
        canvas.restoreToCount(saved)
    }

    private fun drawSticker(canvas: Canvas, spec: AnnotationSpec, width: Int, height: Int) {
        val path = spec.imagePath ?: return
        if (!File(path).exists()) return
        // A missing or unreadable sticker costs that sticker, not the export.
        val sticker = BitmapFactory.decodeFile(path) ?: return

        val rect = RectF(pixels(spec.rect, width, height))
        val paint = Paint(Paint.FILTER_BITMAP_FLAG).apply {
            alpha = (((spec.opacity ?: 1.0).coerceIn(0.0, 1.0)) * 255).roundToInt()
        }

        val saved = canvas.save()
        canvas.rotate(Math.toDegrees(spec.rotation).toFloat(), rect.centerX(), rect.centerY())
        canvas.drawBitmap(sticker, null, rect, paint)
        canvas.restoreToCount(saved)
        sticker.recycle()
    }

    private fun drawStroke(canvas: Canvas, spec: AnnotationSpec, width: Int, height: Int) {
        val flat = spec.points ?: return
        if (flat.size < 2) return

        // Width against the shorter edge, so a line keeps its weight whichever
        // way the frame is turned.
        val strokeWidth = max(1.0, (spec.widthFraction ?: 0.01) * min(width, height)).toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = argb(spec.colorArgb)
            style = Paint.Style.STROKE
            this.strokeWidth = strokeWidth
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }

        if (flat.size == 2) {
            // A tap is a dot, not nothing.
            canvas.drawCircle(
                (flat[0] * width).toFloat(),
                (flat[1] * height).toFloat(),
                strokeWidth / 2,
                Paint(paint).apply { style = Paint.Style.FILL },
            )
            return
        }

        val path = Path()
        path.moveTo((flat[0] * width).toFloat(), (flat[1] * height).toFloat())
        var index = 2
        while (index + 1 < flat.size) {
            path.lineTo((flat[index] * width).toFloat(), (flat[index + 1] * height).toFloat())
            index += 2
        }
        canvas.drawPath(path, paint)
    }
}
