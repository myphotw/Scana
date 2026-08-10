package com.myphotw.scana.imageprocessing

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import org.opencv.android.OpenCVLoader
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc

/** Offline document quadrilateral detector used through Flutter's method channel. */
object OpenCvDocumentDetector {
    private const val MAX_DETECTION_DIMENSION = 1400.0
    private const val MIN_AREA_RATIO = 0.08
    private const val MAX_ASPECT_RATIO = 8.0

    private val openCvReady: Boolean by lazy { OpenCVLoader.initLocal() }

    fun detect(imagePath: String): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }

        val source = Imgcodecs.imread(imagePath, Imgcodecs.IMREAD_COLOR)
        if (source.empty()) {
            source.release()
            throw IllegalArgumentException("The image could not be decoded.")
        }

        val sourceWidth = source.cols()
        val sourceHeight = source.rows()
        val scale = min(1.0, MAX_DETECTION_DIMENSION / max(sourceWidth, sourceHeight).toDouble())
        val resized = Mat()
        val gray = Mat()
        val blurred = Mat()
        val edges = Mat()
        val hierarchy = Mat()
        val contours = mutableListOf<MatOfPoint>()

        try {
            if (scale < 1.0) {
                Imgproc.resize(source, resized, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                source.copyTo(resized)
            }
            Imgproc.cvtColor(resized, gray, Imgproc.COLOR_BGR2GRAY)
            Imgproc.GaussianBlur(gray, blurred, Size(5.0, 5.0), 0.0)
            Imgproc.Canny(blurred, edges, 60.0, 180.0)
            val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
            try {
                Imgproc.morphologyEx(edges, edges, Imgproc.MORPH_CLOSE, kernel)
            } finally {
                kernel.release()
            }
            Imgproc.findContours(
                edges,
                contours,
                hierarchy,
                Imgproc.RETR_LIST,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )

            val imageArea = resized.cols().toDouble() * resized.rows().toDouble()
            val candidates =
                contours
                    .asSequence()
                    .sortedByDescending { Imgproc.contourArea(it) }
                    .take(40)
                    .mapNotNull { evaluateCandidate(it, resized.size(), imageArea) }
                    .toList()
            val best = candidates.maxByOrNull { it.score }
                ?: return notDetected(sourceWidth, sourceHeight)
            val ordered = orderCorners(best.points).map { point ->
                Point(point.x / scale, point.y / scale)
            }

            return mapOf(
                "detected" to true,
                "confidence" to best.score.coerceIn(0.0, 1.0),
                "sourceWidth" to sourceWidth,
                "sourceHeight" to sourceHeight,
                "corners" to ordered.map(::pointMap),
            )
        } finally {
            contours.forEach(Mat::release)
            hierarchy.release()
            edges.release()
            blurred.release()
            gray.release()
            resized.release()
            source.release()
        }
    }

    private fun evaluateCandidate(
        contour: MatOfPoint,
        imageSize: Size,
        imageArea: Double,
    ): Candidate? {
        val contour2f = MatOfPoint2f(*contour.toArray())
        val approximation = MatOfPoint2f()
        val approximationInt = MatOfPoint()
        try {
            val perimeter = Imgproc.arcLength(contour2f, true)
            Imgproc.approxPolyDP(contour2f, approximation, perimeter * 0.02, true)
            if (approximation.total() != 4L) return null

            approximation.convertTo(approximationInt, CvType.CV_32S)
            if (!Imgproc.isContourConvex(approximationInt)) return null

            val points = approximation.toArray()
            val area = abs(Imgproc.contourArea(approximation))
            val areaRatio = area / imageArea
            if (areaRatio < MIN_AREA_RATIO) return null

            val bounds = Imgproc.boundingRect(approximationInt)
            val shortSide = min(bounds.width, bounds.height).coerceAtLeast(1)
            val longSide = max(bounds.width, bounds.height)
            val aspectRatio = longSide.toDouble() / shortSide.toDouble()
            if (aspectRatio > MAX_ASPECT_RATIO) return null

            val angleScore = rightAngleScore(points)
            val rectangularity = (area / (bounds.width.toDouble() * bounds.height)).coerceIn(0.0, 1.0)
            val edgeScore = edgeDistanceScore(points, imageSize)
            val aspectScore = (1.0 - ((aspectRatio - 1.0) / MAX_ASPECT_RATIO)).coerceIn(0.0, 1.0)
            val score =
                areaRatio.coerceAtMost(1.0) * 0.48 +
                    angleScore * 0.24 +
                    rectangularity * 0.10 +
                    edgeScore * 0.10 +
                    aspectScore * 0.08
            return Candidate(points, score)
        } finally {
            approximationInt.release()
            approximation.release()
            contour2f.release()
        }
    }

    private fun rightAngleScore(points: Array<Point>): Double {
        val ordered = orderCorners(points)
        var cosineSum = 0.0
        for (index in ordered.indices) {
            val previous = ordered[(index + ordered.size - 1) % ordered.size]
            val current = ordered[index]
            val next = ordered[(index + 1) % ordered.size]
            val firstX = previous.x - current.x
            val firstY = previous.y - current.y
            val secondX = next.x - current.x
            val secondY = next.y - current.y
            val denominator =
                sqrt(firstX * firstX + firstY * firstY) *
                    sqrt(secondX * secondX + secondY * secondY)
            if (denominator > 0.0) {
                cosineSum += abs((firstX * secondX + firstY * secondY) / denominator)
            }
        }
        return (1.0 - cosineSum / ordered.size).coerceIn(0.0, 1.0)
    }

    private fun edgeDistanceScore(points: Array<Point>, imageSize: Size): Double {
        val margin = min(imageSize.width, imageSize.height) * 0.015
        val pointsOnEdge = points.count { point ->
            point.x <= margin ||
                point.y <= margin ||
                point.x >= imageSize.width - margin ||
                point.y >= imageSize.height - margin
        }
        return 1.0 - pointsOnEdge / 4.0
    }

    private fun orderCorners(points: Array<Point>): List<Point> {
        val top = points.sortedBy { it.y }.take(2).sortedBy { it.x }
        val bottom = points.sortedByDescending { it.y }.take(2).sortedBy { it.x }
        return listOf(top[0], top[1], bottom[1], bottom[0])
    }

    private fun pointMap(point: Point): Map<String, Double> =
        mapOf("x" to point.x, "y" to point.y)

    private fun notDetected(sourceWidth: Int, sourceHeight: Int): Map<String, Any> =
        mapOf(
            "detected" to false,
            "confidence" to 0.0,
            "sourceWidth" to sourceWidth,
            "sourceHeight" to sourceHeight,
        )

    private data class Candidate(val points: Array<Point>, val score: Double)
}
