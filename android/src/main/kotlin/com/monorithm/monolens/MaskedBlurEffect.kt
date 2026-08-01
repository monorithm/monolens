package com.monorithm.monolens

import android.content.Context
import android.opengl.GLES20
import android.opengl.GLUtils
import androidx.annotation.OptIn
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import kotlin.math.min

/**
 * Blurs named regions of a video frame, leaving the rest sharp.
 *
 * Media3 ships `GaussianBlur`, but it blurs the whole frame and takes no mask,
 * which is the opposite of what redacting a face needs. Chaining stock effects
 * cannot recover the sharp part either: an `OverlayEffect` draws *onto* a frame
 * and can never sample it, so there is nothing to composite the unblurred
 * region back from. That leaves a shader, which is what this is.
 */
@OptIn(UnstableApi::class)
internal class MaskedBlurEffect(private val regions: List<AnnotationSpec>) : GlEffect {

    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        MaskedBlurShaderProgram(regions, useHdr)

    /**
     * With nothing to blur the effect removes itself from the chain, so a clip
     * with no blur regions pays nothing for this being available.
     */
    override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = regions.isEmpty()
}

@OptIn(UnstableApi::class)
private class MaskedBlurShaderProgram(
    private val regions: List<AnnotationSpec>,
    useHdr: Boolean,
) : BaseGlShaderProgram(useHdr, /* texturePoolCapacity= */ 1) {

    private val glProgram = GlProgram(VERTEX_SHADER, FRAGMENT_SHADER)

    private var maskTexId = UNSET_TEXTURE
    private var texelWidth = 0f
    private var texelHeight = 0f
    private var radiusTexels = 0f

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        texelWidth = 1f / inputWidth
        texelHeight = 1f / inputHeight

        // One radius for the pass, scaled against the smallest region's shorter
        // edge so a radius picked for a large box does not erase a small one.
        // Same rule as the still path, which is what makes a given `strength`
        // look the same in a JPEG and in an MP4.
        val smallest = regions.minOfOrNull { spec ->
            val rect = spec.rect
            min(
                (rect?.width ?: 1.0) * inputWidth,
                (rect?.height ?: 1.0) * inputHeight,
            )
        } ?: 0.0
        val strength = regions.maxOfOrNull { (it.strength ?: 0.5).coerceIn(0.0, 1.0) } ?: 0.5
        // Divided by the kernel's half-width: the shader steps SAMPLES taps out
        // in each direction, so this is the spacing between taps, not the reach.
        radiusTexels = (smallest * 0.12 * strength / SAMPLES).toFloat().coerceAtLeast(0.5f)

        uploadMask(inputWidth, inputHeight)

        // A blur changes no dimensions.
        return Size(inputWidth, inputHeight)
    }

    /**
     * Rasterizes the regions once and hands them to GL as a texture.
     *
     * A texture rather than uniforms because GLES reports an array uniform
     * under the name `uRegions[0]`, so binding it by the name in the source
     * silently fails — and because this way the oval geometry is decided by the
     * same Canvas code the still path uses instead of being re-derived in GLSL.
     */
    private fun uploadMask(width: Int, height: Int) {
        val mask = AnnotationRenderer.blurMask(regions, width, height) ?: return

        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        maskTexId = ids[0]

        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        // Clamped so a region touching an edge does not wrap to the far side.
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, /* level= */ 0, mask, /* border= */ 0)
        mask.recycle()
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        glProgram.use()
        glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, /* texUnitIndex= */ 0)
        glProgram.setSamplerTexIdUniform("uMaskSampler", maskTexId, /* texUnitIndex= */ 1)
        glProgram.setBufferAttribute(
            "aFramePosition",
            GlUtil.getNormalizedCoordinateBounds(),
            GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
        )
        glProgram.setFloatUniform("uTexelWidth", texelWidth)
        glProgram.setFloatUniform("uTexelHeight", texelHeight)
        glProgram.setFloatUniform("uRadius", radiusTexels)
        glProgram.bindAttributesAndUniforms()

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, /* first= */ 0, /* count= */ 4)
        GlUtil.checkGlError()
    }

    override fun release() {
        super.release()
        if (maskTexId != UNSET_TEXTURE) {
            GLES20.glDeleteTextures(1, intArrayOf(maskTexId), 0)
            maskTexId = UNSET_TEXTURE
        }
        glProgram.delete()
    }

    private companion object {
        /**
         * Taps per direction: a 9x9 kernel. GLSL ES 1.00 needs a loop bound the
         * compiler can constant-fold, so this is baked into the source.
         */
        const val SAMPLES = 4

        /** GL never hands out 0 as a texture name. */
        const val UNSET_TEXTURE = 0

        val VERTEX_SHADER = """
            #version 100
            attribute vec4 aFramePosition;
            varying vec2 vTexCoord;
            void main() {
              gl_Position = aFramePosition;
              // Clip space is -1..1; texture space is 0..1.
              vTexCoord = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
            }
        """.trimIndent()

        val FRAGMENT_SHADER = """
            #version 100
            precision mediump float;

            uniform sampler2D uTexSampler;
            uniform sampler2D uMaskSampler;
            uniform float uTexelWidth;
            uniform float uTexelHeight;
            uniform float uRadius;

            varying vec2 vTexCoord;

            void main() {
              // The mask was drawn by Canvas, whose origin is top-left, while GL
              // samples from the bottom-left. Flipping here is what puts the
              // region where the author drew it instead of mirrored about the
              // middle.
              float mask = texture2D(uMaskSampler, vec2(vTexCoord.x, 1.0 - vTexCoord.y)).r;

              // Most of the frame takes this branch: one fetch and out.
              if (mask < 0.5) {
                gl_FragColor = texture2D(uTexSampler, vTexCoord);
                return;
              }

              vec2 texelSize = vec2(uTexelWidth, uTexelHeight);
              vec4 total = vec4(0.0);
              float taps = 0.0;
              for (int y = -$SAMPLES; y <= $SAMPLES; y++) {
                for (int x = -$SAMPLES; x <= $SAMPLES; x++) {
                  vec2 offset = vec2(float(x), float(y)) * texelSize * uRadius;
                  total += texture2D(uTexSampler, clamp(vTexCoord + offset, 0.0, 1.0));
                  taps += 1.0;
                }
              }
              gl_FragColor = total / taps;
            }
        """.trimIndent()
    }
}
