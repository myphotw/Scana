package com.myphotw.scana.imageprocessing

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc

/** Full-resolution, paper-aware document appearance enhancement. */
object OpenCvPageEnhancer {
    private const val ANALYSIS_MAX_DIMENSION = 1200.0
    private const val PAPER_TARGET_LUMINANCE = 238.0
    private const val PAPER_MIN_LUMINANCE = 142.0
    private const val PAPER_MAX_CHROMA_DISTANCE = 22.0
    private const val PAPER_MAX_LOCAL_TEXTURE = 14.0
    private const val PAPER_CHROMA_NEUTRALIZATION = 0.34
    private const val FOREGROUND_MAX_LUMINANCE = 205.0
    private const val FOREGROUND_MIN_DARK_DETAIL = 3.0
    private const val FOREGROUND_MIN_BACKGROUND = 158.0
    private const val SOURCE_LUMINANCE_BLEND = 0.07
    private const val FOREGROUND_DARKENING_AMOUNT = 0.20
    private const val SHARPEN_AMOUNT = 0.17
    private val openCvReady: Boolean by lazy { OpenCVLoader.initLocal() }

    fun enhance(
        sourceImagePath: String,
        outputImagePath: String,
        mode: String,
        qualityDiagnosticsEnabled: Boolean,
    ): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }
        val startedAt = System.nanoTime()
        val source = Imgcodecs.imread(sourceImagePath, Imgcodecs.IMREAD_COLOR)
        if (source.empty()) {
            source.release()
            throw IllegalArgumentException("The corrected image could not be decoded.")
        }

        var output: Mat? = null
        var stageTimings = emptyMap<String, Int>()
        try {
            output = when (mode) {
                "scanColor" -> {
                    val result = enhanceScanColor(source)
                    stageTimings = result.timings
                    result.image
                }
                "originalColor" -> source.clone()
                "grayscale" -> enhanceGrayscale(source)
                "blackWhite" -> enhanceBlackWhite(source)
                else -> throw IllegalArgumentException("Unknown enhancement mode.")
            }
            check(output.cols() == source.cols() && output.rows() == source.rows()) {
                "Enhancement changed the corrected image resolution."
            }
            val sourceQuality = if (qualityDiagnosticsEnabled) {
                OpenCvImageQuality.metrics(source, "source")
            } else {
                emptyMap()
            }
            val outputQuality = if (qualityDiagnosticsEnabled) {
                OpenCvImageQuality.metrics(output, "output")
            } else {
                emptyMap()
            }
            val written = OpenCvImageQuality.write(outputImagePath, output)
            check(written) { "The enhanced image could not be written." }
            return mutableMapOf<String, Any>(
                "outputWidth" to output.cols(),
                "outputHeight" to output.rows(),
                "processingMilliseconds" to elapsedMilliseconds(startedAt),
                "outputFormat" to java.io.File(outputImagePath).extension.lowercase(),
            ).apply {
                putAll(sourceQuality)
                putAll(outputQuality)
                putAll(stageTimings)
                if (mode == "scanColor") {
                    put("sharpeningAmount", SHARPEN_AMOUNT)
                    put("foregroundDarkeningAmount", FOREGROUND_DARKENING_AMOUNT)
                    put("sourceLuminanceBlend", SOURCE_LUMINANCE_BLEND)
                }
            }
        } finally {
            output?.release()
            source.release()
        }
    }

    private fun enhanceScanColor(source: Mat): ScanColorResult {
        val totalStartedAt = System.nanoTime()
        val timings = mutableMapOf<String, Int>()
        val lab = Mat()
        val channels = mutableListOf<Mat>()
        var background: Mat? = null
        var normalized: Mat? = null
        var paperMask: Mat? = null
        var whitened: Mat? = null
        var foregroundMask: Mat? = null
        var foregroundEnhanced: Mat? = null
        var sharpened: Mat? = null
        var adjustedA: Mat? = null
        var adjustedB: Mat? = null
        val merged = Mat()
        val output = Mat()
        var succeeded = false
        try {
            var stageStartedAt = System.nanoTime()
            Imgproc.cvtColor(source, lab, Imgproc.COLOR_BGR2Lab)
            Core.split(lab, channels)
            background = estimatePaperBackground(channels[0])
            timings["backgroundAnalysisMilliseconds"] =
                elapsedMilliseconds(stageStartedAt)

            stageStartedAt = System.nanoTime()
            normalized = normalizeAgainstBackground(channels[0], background)
            timings["backgroundNormalizationMilliseconds"] =
                elapsedMilliseconds(stageStartedAt)

            stageStartedAt = System.nanoTime()
            paperMask = buildPaperMask(normalized, channels[1], channels[2])
            val paperTone = applyLut(normalized, ::paperToneValue)
            try {
                whitened = blendBrighterWithMask(normalized, paperTone, paperMask)
            } finally {
                paperTone.release()
            }
            timings["backgroundWhiteningMilliseconds"] =
                elapsedMilliseconds(stageStartedAt)

            stageStartedAt = System.nanoTime()
            foregroundMask = buildForegroundMask(
                whitened,
                background,
            )
            val foregroundTone = applyLut(whitened, ::foregroundToneValue)
            try {
                foregroundEnhanced = blendDarkerWithMask(
                    whitened,
                    foregroundTone,
                    foregroundMask,
                )
            } finally {
                foregroundTone.release()
            }
            timings["foregroundEnhancementMilliseconds"] =
                elapsedMilliseconds(stageStartedAt)

            stageStartedAt = System.nanoTime()
            sharpened = sharpenForeground(foregroundEnhanced, foregroundMask)
            adjustedA = neutralizePaperChroma(channels[1], paperMask)
            adjustedB = neutralizePaperChroma(channels[2], paperMask)
            Core.merge(listOf(sharpened, adjustedA, adjustedB), merged)
            Imgproc.cvtColor(merged, output, Imgproc.COLOR_Lab2BGR)
            timings["sharpeningMilliseconds"] = elapsedMilliseconds(stageStartedAt)
            timings["totalEnhancementMilliseconds"] =
                elapsedMilliseconds(totalStartedAt)
            succeeded = true
            return ScanColorResult(output, timings)
        } finally {
            if (!succeeded) output.release()
            merged.release()
            adjustedB?.release()
            adjustedA?.release()
            sharpened?.release()
            foregroundEnhanced?.release()
            foregroundMask?.release()
            whitened?.release()
            paperMask?.release()
            normalized?.release()
            background?.release()
            channels.forEach(Mat::release)
            lab.release()
        }
    }

    /** Closing removes dark glyphs before a broad blur estimates paper lighting. */
    private fun estimatePaperBackground(luminance: Mat): Mat {
        val scale = min(
            1.0,
            ANALYSIS_MAX_DIMENSION / max(luminance.cols(), luminance.rows()).toDouble(),
        )
        val analysis = Mat()
        val closed = Mat()
        val backgroundSmall = Mat()
        val background = Mat()
        var morphologyKernel: Mat? = null
        var succeeded = false
        try {
            if (scale < 1.0) {
                Imgproc.resize(luminance, analysis, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                luminance.copyTo(analysis)
            }
            val minimumDimension = min(analysis.cols(), analysis.rows())
            val closingSize = oddSize(
                (minimumDimension * 0.035).roundToInt(),
                minimum = 15,
                maximum = 61,
            )
            morphologyKernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_ELLIPSE,
                Size(closingSize.toDouble(), closingSize.toDouble()),
            )
            Imgproc.morphologyEx(
                analysis,
                closed,
                Imgproc.MORPH_CLOSE,
                morphologyKernel,
            )
            val blurSize = oddSize(
                (minimumDimension * 0.10).roundToInt(),
                minimum = 31,
                maximum = 151,
            )
            Imgproc.GaussianBlur(
                closed,
                backgroundSmall,
                Size(blurSize.toDouble(), blurSize.toDouble()),
                0.0,
            )
            Imgproc.resize(
                backgroundSmall,
                background,
                luminance.size(),
                0.0,
                0.0,
                Imgproc.INTER_LINEAR,
            )
            succeeded = true
            return background
        } finally {
            if (!succeeded) background.release()
            morphologyKernel?.release()
            backgroundSmall.release()
            closed.release()
            analysis.release()
        }
    }

    private fun normalizeAgainstBackground(luminance: Mat, background: Mat): Mat {
        val safeBackground = Mat()
        val divided = Mat()
        val normalized = Mat()
        var succeeded = false
        try {
            Core.max(background, Scalar.all(48.0), safeBackground)
            Core.divide(
                luminance,
                safeBackground,
                divided,
                PAPER_TARGET_LUMINANCE,
            )
            Core.addWeighted(
                luminance,
                SOURCE_LUMINANCE_BLEND,
                divided,
                1.0 - SOURCE_LUMINANCE_BLEND,
                0.0,
                normalized,
            )
            succeeded = true
            return normalized
        } finally {
            if (!succeeded) normalized.release()
            divided.release()
            safeBackground.release()
        }
    }

    /** Bright, low-chroma and low-texture pixels are likely visible paper. */
    private fun buildPaperMask(
        luminance: Mat,
        channelA: Mat,
        channelB: Mat,
    ): Mat {
        val luminanceMask = Mat()
        val chromaA = Mat()
        val chromaB = Mat()
        val chromaDistance = Mat()
        val chromaMask = Mat()
        val localMean = Mat()
        val localTexture = Mat()
        val textureMask = Mat()
        val combined = Mat()
        val softMask = Mat()
        var succeeded = false
        try {
            Imgproc.threshold(
                luminance,
                luminanceMask,
                PAPER_MIN_LUMINANCE,
                255.0,
                Imgproc.THRESH_BINARY,
            )
            Core.absdiff(channelA, Scalar.all(128.0), chromaA)
            Core.absdiff(channelB, Scalar.all(128.0), chromaB)
            Core.max(chromaA, chromaB, chromaDistance)
            Imgproc.threshold(
                chromaDistance,
                chromaMask,
                PAPER_MAX_CHROMA_DISTANCE,
                255.0,
                Imgproc.THRESH_BINARY_INV,
            )
            Imgproc.GaussianBlur(luminance, localMean, Size(9.0, 9.0), 0.0)
            Core.absdiff(luminance, localMean, localTexture)
            Imgproc.threshold(
                localTexture,
                textureMask,
                PAPER_MAX_LOCAL_TEXTURE,
                255.0,
                Imgproc.THRESH_BINARY_INV,
            )
            Core.bitwise_and(luminanceMask, chromaMask, combined)
            Core.bitwise_and(combined, textureMask, combined)
            Imgproc.GaussianBlur(combined, softMask, Size(9.0, 9.0), 0.0)
            succeeded = true
            return softMask
        } finally {
            if (!succeeded) softMask.release()
            combined.release()
            textureMask.release()
            localTexture.release()
            localMean.release()
            chromaMask.release()
            chromaDistance.release()
            chromaB.release()
            chromaA.release()
            luminanceMask.release()
        }
    }

    /** Keeps strong, small dark structures while excluding weak show-through. */
    private fun buildForegroundMask(luminance: Mat, background: Mat): Mat {
        val localMean = Mat()
        val darkDetail = Mat()
        val detailMask = Mat()
        val darkMask = Mat()
        val backgroundMask = Mat()
        val combined = Mat()
        val dilated = Mat()
        val softMask = Mat()
        var kernel: Mat? = null
        var succeeded = false
        try {
            Imgproc.GaussianBlur(luminance, localMean, Size(5.0, 5.0), 0.0)
            Core.subtract(localMean, luminance, darkDetail)
            Imgproc.threshold(
                darkDetail,
                detailMask,
                FOREGROUND_MIN_DARK_DETAIL,
                255.0,
                Imgproc.THRESH_BINARY,
            )
            Imgproc.threshold(
                luminance,
                darkMask,
                FOREGROUND_MAX_LUMINANCE,
                255.0,
                Imgproc.THRESH_BINARY_INV,
            )
            Imgproc.threshold(
                background,
                backgroundMask,
                FOREGROUND_MIN_BACKGROUND,
                255.0,
                Imgproc.THRESH_BINARY,
            )
            Core.bitwise_and(detailMask, darkMask, combined)
            Core.bitwise_and(combined, backgroundMask, combined)
            kernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_ELLIPSE,
                Size(3.0, 3.0),
            )
            Imgproc.dilate(combined, dilated, kernel)
            Imgproc.GaussianBlur(dilated, softMask, Size(3.0, 3.0), 0.0)
            succeeded = true
            return softMask
        } finally {
            if (!succeeded) softMask.release()
            kernel?.release()
            dilated.release()
            combined.release()
            backgroundMask.release()
            darkMask.release()
            detailMask.release()
            darkDetail.release()
            localMean.release()
        }
    }

    private fun sharpenForeground(luminance: Mat, foregroundMask: Mat): Mat {
        val blurred = Mat()
        val sharpenCandidate = Mat()
        val laplacian16 = Mat()
        val edgeMagnitude = Mat()
        val edgeMask = Mat()
        val sharpenMask = Mat()
        val output = Mat()
        var succeeded = false
        try {
            Imgproc.GaussianBlur(luminance, blurred, Size(), 0.9)
            Core.addWeighted(
                luminance,
                1.0 + SHARPEN_AMOUNT,
                blurred,
                -SHARPEN_AMOUNT,
                0.0,
                sharpenCandidate,
            )
            Imgproc.Laplacian(luminance, laplacian16, CvType.CV_16S, 3)
            Core.convertScaleAbs(laplacian16, edgeMagnitude)
            Imgproc.threshold(
                edgeMagnitude,
                edgeMask,
                7.0,
                255.0,
                Imgproc.THRESH_BINARY,
            )
            Core.bitwise_and(edgeMask, foregroundMask, sharpenMask)
            Imgproc.GaussianBlur(sharpenMask, sharpenMask, Size(3.0, 3.0), 0.0)
            luminance.copyTo(output)
            sharpenCandidate.copyTo(output, sharpenMask)
            succeeded = true
            return output
        } finally {
            if (!succeeded) output.release()
            sharpenMask.release()
            edgeMask.release()
            edgeMagnitude.release()
            laplacian16.release()
            sharpenCandidate.release()
            blurred.release()
        }
    }

    /** Only paper pixels move toward neutral; colored text and images are protected. */
    private fun neutralizePaperChroma(channel: Mat, paperMask: Mat): Mat {
        val neutral = Mat(channel.size(), channel.type(), Scalar.all(128.0))
        val neutralBlend = Mat()
        val output = Mat()
        var succeeded = false
        try {
            Core.addWeighted(
                channel,
                1.0 - PAPER_CHROMA_NEUTRALIZATION,
                neutral,
                PAPER_CHROMA_NEUTRALIZATION,
                0.0,
                neutralBlend,
            )
            channel.copyTo(output)
            neutralBlend.copyTo(output, paperMask)
            succeeded = true
            return output
        } finally {
            if (!succeeded) output.release()
            neutralBlend.release()
            neutral.release()
        }
    }

    /** Candidate must be brighter than base; all arithmetic stays 8-bit. */
    private fun blendBrighterWithMask(base: Mat, candidate: Mat, mask: Mat): Mat {
        val difference = Mat()
        val weightedDifference = Mat()
        val output = Mat()
        var succeeded = false
        try {
            Core.subtract(candidate, base, difference)
            Core.multiply(difference, mask, weightedDifference, 1.0 / 255.0)
            Core.add(base, weightedDifference, output)
            succeeded = true
            return output
        } finally {
            if (!succeeded) output.release()
            weightedDifference.release()
            difference.release()
        }
    }

    /** Candidate must be darker than base; all arithmetic stays 8-bit. */
    private fun blendDarkerWithMask(base: Mat, candidate: Mat, mask: Mat): Mat {
        val difference = Mat()
        val weightedDifference = Mat()
        val output = Mat()
        var succeeded = false
        try {
            Core.subtract(base, candidate, difference)
            Core.multiply(difference, mask, weightedDifference, 1.0 / 255.0)
            Core.subtract(base, weightedDifference, output)
            succeeded = true
            return output
        } finally {
            if (!succeeded) output.release()
            weightedDifference.release()
            difference.release()
        }
    }

    private fun applyLut(source: Mat, mapping: (Int) -> Int): Mat {
        val lut = Mat(1, 256, CvType.CV_8U)
        val output = Mat()
        var succeeded = false
        try {
            val values = ByteArray(256) { index ->
                mapping(index).coerceIn(0, 255).toByte()
            }
            lut.put(0, 0, values)
            Core.LUT(source, lut, output)
            succeeded = true
            return output
        } finally {
            if (!succeeded) output.release()
            lut.release()
        }
    }

    private fun paperToneValue(value: Int): Int {
        if (value <= 120) return value
        val progress = ((value - 120) / 120.0).coerceIn(0.0, 1.0)
        val softProgress = smoothStep(progress)
        return (value + (255 - value) * 0.86 * softProgress).roundToInt()
    }

    private fun foregroundToneValue(value: Int): Int {
        if (value >= FOREGROUND_MAX_LUMINANCE) return value
        val strength = smoothStep(
            ((FOREGROUND_MAX_LUMINANCE - value) / FOREGROUND_MAX_LUMINANCE)
                .coerceIn(0.0, 1.0),
        )
        return (value * (1.0 - FOREGROUND_DARKENING_AMOUNT * strength)).roundToInt()
    }

    private fun enhanceGrayscale(source: Mat): Mat {
        val gray = Mat()
        var normalized: Mat? = null
        val output = Mat()
        var succeeded = false
        try {
            Imgproc.cvtColor(source, gray, Imgproc.COLOR_BGR2GRAY)
            normalized = normalizeLegacyLuminance(gray)
            Imgproc.cvtColor(normalized, output, Imgproc.COLOR_GRAY2BGR)
            succeeded = true
            return output
        } finally {
            if (!succeeded) output.release()
            normalized?.release()
            gray.release()
        }
    }

    private fun enhanceBlackWhite(source: Mat): Mat {
        val gray = Mat()
        var normalized: Mat? = null
        val smoothed = Mat()
        val binary = Mat()
        val output = Mat()
        var succeeded = false
        try {
            Imgproc.cvtColor(source, gray, Imgproc.COLOR_BGR2GRAY)
            normalized = normalizeLegacyLuminance(gray)
            Imgproc.medianBlur(normalized, smoothed, 3)
            val minimumDimension = min(source.cols(), source.rows())
            val blockSize = oddSize(
                (minimumDimension * 0.025).roundToInt(),
                minimum = 31,
                maximum = 101,
            )
            Imgproc.adaptiveThreshold(
                smoothed,
                binary,
                255.0,
                Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
                Imgproc.THRESH_BINARY,
                blockSize,
                12.0,
            )
            Imgproc.cvtColor(binary, output, Imgproc.COLOR_GRAY2BGR)
            succeeded = true
            return output
        } finally {
            normalized?.release()
            if (!succeeded) output.release()
            binary.release()
            smoothed.release()
            gray.release()
        }
    }

    /** Retained for Grayscale and Black & White M8 regression compatibility. */
    private fun normalizeLegacyLuminance(luminance: Mat): Mat {
        val background = estimatePaperBackground(luminance)
        val normalized = Mat()
        val denoised = Mat()
        val sharpenBlur = Mat()
        var succeeded = false
        try {
            val divided = normalizeAgainstBackground(luminance, background)
            try {
                divided.copyTo(normalized)
            } finally {
                divided.release()
            }
            val clahe = Imgproc.createCLAHE(1.8, Size(8.0, 8.0))
            try {
                clahe.apply(normalized, normalized)
            } finally {
                clahe.collectGarbage()
            }
            Imgproc.GaussianBlur(normalized, denoised, Size(3.0, 3.0), 0.0)
            Core.addWeighted(normalized, 0.82, denoised, 0.18, 0.0, normalized)
            Imgproc.GaussianBlur(normalized, sharpenBlur, Size(), 1.0)
            Core.addWeighted(normalized, 1.12, sharpenBlur, -0.12, 0.0, normalized)
            succeeded = true
            return normalized
        } finally {
            if (!succeeded) normalized.release()
            sharpenBlur.release()
            denoised.release()
            background.release()
        }
    }

    private fun oddSize(value: Int, minimum: Int, maximum: Int): Int {
        var result = value.coerceIn(minimum, maximum)
        if (result % 2 == 0) result++
        return result.coerceAtMost(if (maximum % 2 == 1) maximum else maximum - 1)
    }

    private fun smoothStep(value: Double): Double = value * value * (3.0 - 2.0 * value)

    private fun elapsedMilliseconds(startedAt: Long): Int =
        ((System.nanoTime() - startedAt) / 1_000_000L).toInt()

    private data class ScanColorResult(
        val image: Mat,
        val timings: Map<String, Int>,
    )
}
