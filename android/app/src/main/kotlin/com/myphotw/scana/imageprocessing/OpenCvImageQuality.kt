package com.myphotw.scana.imageprocessing

import java.io.File
import kotlin.math.min
import kotlin.math.max
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfDouble
import org.opencv.core.MatOfInt
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc

/** Lossless intermediate writer and lightweight document-detail diagnostics. */
object OpenCvImageQuality {
    private const val METRIC_MAX_DIMENSION = 1600.0
    private const val JPEG_QUALITY = 98
    private const val PNG_COMPRESSION = 3

    fun write(path: String, image: Mat): Boolean {
        val extension = File(path).extension.lowercase()
        val parameters = when (extension) {
            "png" -> MatOfInt(Imgcodecs.IMWRITE_PNG_COMPRESSION, PNG_COMPRESSION)
            "jpg", "jpeg" -> MatOfInt(Imgcodecs.IMWRITE_JPEG_QUALITY, JPEG_QUALITY)
            else -> throw IllegalArgumentException("Unsupported image output format: $extension")
        }
        return try {
            Imgcodecs.imwrite(path, image, parameters)
        } finally {
            parameters.release()
        }
    }

    fun metrics(image: Mat, prefix: String): Map<String, Any> {
        val sample = Mat()
        val gray = Mat()
        val laplacian = Mat()
        val localMean = Mat()
        val broadMean = Mat()
        val darkDetail = Mat()
        val darkResidual = Mat()
        val detailMask = Mat()
        val darkMask = Mat()
        val foregroundMask = Mat()
        val backgroundMask = Mat()
        val speckleMask = Mat()
        val mean = MatOfDouble()
        val deviation = MatOfDouble()
        val foregroundMean = MatOfDouble()
        val foregroundDeviation = MatOfDouble()
        val backgroundMean = MatOfDouble()
        val backgroundDeviation = MatOfDouble()
        try {
            val scale = min(
                1.0,
                METRIC_MAX_DIMENSION / max(image.cols(), image.rows()).toDouble(),
            )
            if (scale < 1.0) {
                Imgproc.resize(image, sample, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                image.copyTo(sample)
            }
            Imgproc.cvtColor(sample, gray, Imgproc.COLOR_BGR2GRAY)
            Imgproc.Laplacian(gray, laplacian, CvType.CV_64F, 3)
            Core.meanStdDev(laplacian, mean, deviation)

            Imgproc.GaussianBlur(gray, localMean, Size(5.0, 5.0), 0.0)
            Core.subtract(localMean, gray, darkDetail)
            Imgproc.threshold(darkDetail, detailMask, 3.0, 255.0, Imgproc.THRESH_BINARY)
            Imgproc.threshold(gray, darkMask, 220.0, 255.0, Imgproc.THRESH_BINARY_INV)
            Core.bitwise_and(detailMask, darkMask, foregroundMask)
            val foregroundPixels = Core.countNonZero(foregroundMask)
            if (foregroundPixels > 0) {
                Core.meanStdDev(
                    laplacian,
                    foregroundMean,
                    foregroundDeviation,
                    foregroundMask,
                )
            }

            // DEBUG-only paper cleanliness signal. The broad local mean finds
            // likely bright paper even when a dark speckle sits on it; the
            // residual then measures local dark contamination without taking
            // part in the production enhancement policy.
            Imgproc.GaussianBlur(gray, broadMean, Size(15.0, 15.0), 0.0)
            Core.subtract(broadMean, gray, darkResidual)
            Imgproc.threshold(
                broadMean,
                backgroundMask,
                175.0,
                255.0,
                Imgproc.THRESH_BINARY,
            )
            Imgproc.threshold(
                darkResidual,
                speckleMask,
                12.0,
                255.0,
                Imgproc.THRESH_BINARY,
            )
            Core.bitwise_and(speckleMask, backgroundMask, speckleMask)
            val backgroundPixels = Core.countNonZero(backgroundMask)
            val specklePixels = Core.countNonZero(speckleMask)
            if (backgroundPixels > 0) {
                Core.meanStdDev(
                    darkResidual,
                    backgroundMean,
                    backgroundDeviation,
                    backgroundMask,
                )
            }
            val globalDeviation = deviation.toArray().firstOrNull() ?: 0.0
            val detailDeviation = foregroundDeviation.toArray().firstOrNull() ?: 0.0
            val paperDeviation = backgroundDeviation.toArray().firstOrNull() ?: 0.0
            val darkSpeckleRatio = if (backgroundPixels > 0) {
                specklePixels.toDouble() / backgroundPixels.toDouble()
            } else {
                0.0
            }
            return mapOf(
                "${prefix}Width" to image.cols(),
                "${prefix}Height" to image.rows(),
                "${prefix}Sharpness" to globalDeviation * globalDeviation,
                "${prefix}ForegroundSharpness" to detailDeviation * detailDeviation,
                "${prefix}ForegroundPixels" to max(0, foregroundPixels),
                "${prefix}BackgroundVariance" to paperDeviation * paperDeviation,
                "${prefix}DarkSpeckleRatio" to darkSpeckleRatio,
                "${prefix}BackgroundPixels" to max(0, backgroundPixels),
            )
        } finally {
            backgroundDeviation.release()
            backgroundMean.release()
            foregroundDeviation.release()
            foregroundMean.release()
            deviation.release()
            mean.release()
            foregroundMask.release()
            speckleMask.release()
            backgroundMask.release()
            darkMask.release()
            detailMask.release()
            darkResidual.release()
            darkDetail.release()
            broadMean.release()
            localMean.release()
            laplacian.release()
            gray.release()
            sample.release()
        }
    }
}
