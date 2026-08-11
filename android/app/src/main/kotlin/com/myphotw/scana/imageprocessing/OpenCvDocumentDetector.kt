package com.myphotw.scana.imageprocessing

import android.util.Log
import kotlin.math.abs
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt
import org.opencv.android.OpenCVLoader
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Rect
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import java.io.File

/** Offline document quadrilateral detector used through Flutter's method channel. */
object OpenCvDocumentDetector {
    private const val MAX_DETECTION_DIMENSION = 1400.0
    private const val MAX_PREVIEW_DIMENSION = 720.0
    private const val MIN_AREA_RATIO = 0.05
    private const val MIN_CANDIDATE_SCORE = 0.32
    private const val MAX_ASPECT_RATIO = 8.0
    private const val BOUNDARY_SAMPLE_COUNT = 24

    private val openCvReady: Boolean by lazy { OpenCVLoader.initLocal() }

    fun detect(
        imagePath: String,
        pageSideValue: String? = null,
        debugLogging: Boolean = false,
    ): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }
        val pageSide = PageSide.fromValue(pageSideValue)

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
        val enhanced = Mat()
        val blurred = Mat()
        val edges = Mat()
        val hierarchy = Mat()
        val contours = mutableListOf<MatOfPoint>()
        val brightnessMask = Mat()
        val brightnessHierarchy = Mat()
        val brightnessContours = mutableListOf<MatOfPoint>()

        try {
            if (scale < 1.0) {
                Imgproc.resize(source, resized, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                source.copyTo(resized)
            }
            Imgproc.cvtColor(resized, gray, Imgproc.COLOR_BGR2GRAY)
            val clahe = Imgproc.createCLAHE(2.0, Size(8.0, 8.0))
            try {
                clahe.apply(gray, enhanced)
            } finally {
                clahe.collectGarbage()
            }
            Imgproc.GaussianBlur(enhanced, blurred, Size(5.0, 5.0), 0.0)
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
            Imgproc.adaptiveThreshold(
                blurred,
                brightnessMask,
                255.0,
                Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
                Imgproc.THRESH_BINARY,
                31,
                7.0,
            )
            Imgproc.findContours(
                brightnessMask,
                brightnessContours,
                brightnessHierarchy,
                Imgproc.RETR_LIST,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )

            val imageArea = resized.cols().toDouble() * resized.rows().toDouble()
            val longLines = collectLongLines(edges, resized.size())
            val spine = detectSpine(blurred, longLines)
            val contentEnvelope = contentEnvelope(edges, pageSide)
            val baseCandidates =
                (contours.asSequence() + brightnessContours.asSequence())
                    .asSequence()
                    .sortedByDescending { Imgproc.contourArea(it) }
                    .take(40)
                    .mapNotNull {
                        evaluateCandidate(
                            it,
                            resized.size(),
                            imageArea,
                            longLines,
                            blurred,
                            edges,
                            spine,
                            contentEnvelope,
                            pageSide,
                        )
                    }
                    .toList()
            val candidates = if (pageSide == null) {
                baseCandidates + baseCandidates.flatMap { candidate ->
                    splitOpenBookCandidate(
                        candidate,
                        spine,
                        blurred,
                        edges,
                        resized.size(),
                        imageArea,
                    )
                }
            } else {
                baseCandidates + listOfNotNull(
                    spreadPriorCandidate(
                        blurred,
                        edges,
                        resized.size(),
                        imageArea,
                        contentEnvelope,
                        pageSide,
                    ),
                )
            }
            val best = candidates
                .filter { it.score >= MIN_CANDIDATE_SCORE }
                .maxByOrNull { it.score }
                ?: return notDetected(sourceWidth, sourceHeight)
            logCandidate(best, pageSide, debugLogging)
            val ordered = orderCorners(best.points).map { point ->
                Point(point.x / scale, point.y / scale)
            }

            return mapOf(
                "detected" to true,
                "confidence" to best.score.coerceIn(0.0, 1.0),
                "sourceWidth" to sourceWidth,
                "sourceHeight" to sourceHeight,
                "corners" to ordered.map(::pointMap),
                "boundary" to boundaryMap(
                    best.contourPoints,
                    orderCorners(best.points),
                    scale,
                    sourceWidth,
                    sourceHeight,
                    best.score,
                    best.spineSide,
                    best.clippingEvidence,
                ),
            )
        } catch (_: Exception) {
            return notDetected(sourceWidth, sourceHeight)
        } finally {
            contours.forEach(Mat::release)
            brightnessContours.forEach(Mat::release)
            brightnessHierarchy.release()
            brightnessMask.release()
            hierarchy.release()
            edges.release()
            blurred.release()
            enhanced.release()
            gray.release()
            resized.release()
            source.release()
        }
    }

    /** Splits a manually spine-aligned book capture into independent ROI JPEGs. */
    fun splitSpreadCapture(imagePath: String, overlapFraction: Double): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }
        require(overlapFraction >= 0.0 && overlapFraction < 1.0)
        val source = Imgcodecs.imread(imagePath, Imgcodecs.IMREAD_COLOR)
        if (source.empty()) {
            source.release()
            throw IllegalArgumentException("The image could not be decoded.")
        }
        var leftRoi: Mat? = null
        var rightRoi: Mat? = null
        try {
            val width = source.cols()
            val height = source.rows()
            require(width > 1 && height > 0)
            val halfOverlap = overlapFraction / 2.0
            val leftEnd = (width * (0.5 + halfOverlap)).roundToInt().coerceIn(1, width)
            val rightStart = (width * (0.5 - halfOverlap)).roundToInt().coerceIn(0, width - 1)
            leftRoi = Mat(source, Rect(0, 0, leftEnd, height))
            rightRoi = Mat(source, Rect(rightStart, 0, width - rightStart, height))
            val sourceFile = File(imagePath)
            val parent = sourceFile.parentFile
                ?: throw IllegalArgumentException("The capture has no parent directory.")
            val stem = sourceFile.nameWithoutExtension
            val leftFile = File(parent, ".$stem.spread_left.jpg")
            val rightFile = File(parent, ".$stem.spread_right.jpg")
            if (leftFile.exists()) leftFile.delete()
            if (rightFile.exists()) rightFile.delete()
            if (!Imgcodecs.imwrite(leftFile.path, leftRoi) ||
                !Imgcodecs.imwrite(rightFile.path, rightRoi)
            ) {
                leftFile.delete()
                rightFile.delete()
                throw IllegalStateException("The spread ROI images could not be written.")
            }
            return mapOf(
                "leftImagePath" to leftFile.path,
                "rightImagePath" to rightFile.path,
            )
        } finally {
            leftRoi?.release()
            rightRoi?.release()
            source.release()
        }
    }

    /** Writes a conservative axis-aligned crop instead of applying a weak transform. */
    fun cropSpreadFallback(
        imagePath: String,
        outputImagePath: String,
        leftFraction: Double,
        topFraction: Double,
        rightFraction: Double,
        bottomFraction: Double,
    ): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }
        require(leftFraction >= 0.0 && leftFraction < rightFraction && rightFraction <= 1.0)
        require(topFraction >= 0.0 && topFraction < bottomFraction && bottomFraction <= 1.0)
        val source = Imgcodecs.imread(imagePath, Imgcodecs.IMREAD_COLOR)
        if (source.empty()) {
            source.release()
            throw IllegalArgumentException("The spread ROI could not be decoded.")
        }
        var cropped: Mat? = null
        try {
            val left = (source.cols() * leftFraction).roundToInt()
                .coerceIn(0, source.cols() - 1)
            val top = (source.rows() * topFraction).roundToInt()
                .coerceIn(0, source.rows() - 1)
            val right = (source.cols() * rightFraction).roundToInt()
                .coerceIn(left + 1, source.cols())
            val bottom = (source.rows() * bottomFraction).roundToInt()
                .coerceIn(top + 1, source.rows())
            cropped = Mat(source, Rect(left, top, right - left, bottom - top))
            val output = File(outputImagePath)
            output.parentFile?.mkdirs()
            if (!Imgcodecs.imwrite(output.path, cropped)) {
                output.delete()
                throw IllegalStateException("The spread fallback crop could not be written.")
            }
            return mapOf(
                "outputWidth" to cropped.cols(),
                "outputHeight" to cropped.rows(),
            )
        } finally {
            cropped?.release()
            source.release()
        }
    }

    /** Low-resolution luminance path used by the throttled Camera preview. */
    fun detectPreview(
        luminance: ByteArray,
        width: Int,
        height: Int,
        rowStride: Int,
    ): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }
        require(width > 0 && height > 0 && rowStride >= width)
        require(luminance.size >= rowStride * height)

        val packed =
            if (rowStride == width) {
                luminance
            } else {
                ByteArray(width * height).also { target ->
                    for (row in 0 until height) {
                        System.arraycopy(luminance, row * rowStride, target, row * width, width)
                    }
                }
            }
        val sourceGray = Mat(height, width, CvType.CV_8UC1)
        val resized = Mat()
        val blurred = Mat()
        val enhanced = Mat()
        val edges = Mat()
        val threshold = Mat()
        val hierarchy = Mat()
        val thresholdHierarchy = Mat()
        val contours = mutableListOf<MatOfPoint>()
        val thresholdContours = mutableListOf<MatOfPoint>()
        val scale = min(1.0, MAX_PREVIEW_DIMENSION / max(width, height).toDouble())
        try {
            sourceGray.put(0, 0, packed)
            if (scale < 1.0) {
                Imgproc.resize(sourceGray, resized, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                sourceGray.copyTo(resized)
            }
            val clahe = Imgproc.createCLAHE(2.0, Size(8.0, 8.0))
            try {
                clahe.apply(resized, enhanced)
            } finally {
                clahe.collectGarbage()
            }
            Imgproc.GaussianBlur(enhanced, blurred, Size(5.0, 5.0), 0.0)
            Imgproc.Canny(blurred, edges, 48.0, 145.0)
            val closeKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
            try {
                Imgproc.morphologyEx(edges, edges, Imgproc.MORPH_CLOSE, closeKernel)
            } finally {
                closeKernel.release()
            }
            Imgproc.adaptiveThreshold(
                blurred,
                threshold,
                255.0,
                Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
                Imgproc.THRESH_BINARY,
                31,
                7.0,
            )
            Imgproc.findContours(edges, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
            Imgproc.findContours(
                threshold,
                thresholdContours,
                thresholdHierarchy,
                Imgproc.RETR_LIST,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val imageArea = resized.cols().toDouble() * resized.rows().toDouble()
            val longLines = collectLongLines(edges, resized.size())
            val spine = detectSpine(blurred, longLines)
            val contentEnvelope = contentEnvelope(edges, null)
            val baseCandidates =
                (contours.asSequence() + thresholdContours.asSequence())
                    .sortedByDescending { Imgproc.contourArea(it) }
                    .take(48)
                    .mapNotNull {
                        evaluateCandidate(
                            it,
                            resized.size(),
                            imageArea,
                            longLines,
                            blurred,
                            edges,
                            spine,
                            contentEnvelope,
                            null,
                        )
                    }
                    .toList()
            val best =
                (baseCandidates + baseCandidates.flatMap { candidate ->
                    splitOpenBookCandidate(
                        candidate,
                        spine,
                        blurred,
                        edges,
                        resized.size(),
                        imageArea,
                    )
                }).filter { it.score >= MIN_CANDIDATE_SCORE }
                    .maxByOrNull { it.score }
                    ?: return notDetected(width, height)
            val ordered = orderCorners(best.points).map { Point(it.x / scale, it.y / scale) }
            return mapOf(
                "detected" to true,
                "confidence" to best.score.coerceIn(0.0, 1.0),
                "sourceWidth" to width,
                "sourceHeight" to height,
                "corners" to ordered.map(::pointMap),
                "boundary" to boundaryMap(
                    best.contourPoints,
                    orderCorners(best.points),
                    scale,
                    width,
                    height,
                    best.score,
                    best.spineSide,
                    best.clippingEvidence,
                ),
            )
        } catch (_: Exception) {
            return notDetected(width, height)
        } finally {
            contours.forEach(Mat::release)
            thresholdContours.forEach(Mat::release)
            thresholdHierarchy.release()
            hierarchy.release()
            threshold.release()
            edges.release()
            blurred.release()
            enhanced.release()
            resized.release()
            sourceGray.release()
        }
    }

    private fun evaluateCandidate(
        contour: MatOfPoint,
        imageSize: Size,
        imageArea: Double,
        longLines: List<LineSegment>,
        contrastImage: Mat,
        edgeImage: Mat,
        spine: SpineEvidence?,
        contentEnvelope: ContentEnvelope,
        pageSide: PageSide?,
    ): Candidate? {
        val contour2f = MatOfPoint2f(*contour.toArray())
        val approximation = MatOfPoint2f()
        val approximationInt = MatOfPoint()
        try {
            val perimeter = Imgproc.arcLength(contour2f, true)
            Imgproc.approxPolyDP(contour2f, approximation, perimeter * 0.02, true)
            if (approximation.total() !in 4L..12L) return null

            approximation.convertTo(approximationInt, CvType.CV_32S)
            if (!Imgproc.isContourConvex(approximationInt)) return null

            val approximationPoints = approximation.toArray()
            val points = if (approximationPoints.size == 4) {
                approximationPoints
            } else {
                representativeCorners(approximationPoints)
            }
            val area = abs(Imgproc.contourArea(approximation))
            val areaRatio = area / imageArea
            if (areaRatio < MIN_AREA_RATIO) return null
            val edgePointCount = pointsOnImageEdge(points, imageSize)
            if (areaRatio > 0.94 && edgePointCount >= 3) return null

            val bounds = Imgproc.boundingRect(approximationInt)
            val shortSide = min(bounds.width, bounds.height).coerceAtLeast(1)
            val longSide = max(bounds.width, bounds.height)
            val aspectRatio = longSide.toDouble() / shortSide.toDouble()
            if (aspectRatio > MAX_ASPECT_RATIO) return null

            val angleScore = rightAngleScore(points)
            val rectangularity = (area / (bounds.width.toDouble() * bounds.height)).coerceIn(0.0, 1.0)
            val edgeScore = edgeDistanceScore(points, imageSize)
            val aspectScore = (1.0 - ((aspectRatio - 1.0) / MAX_ASPECT_RATIO)).coerceIn(0.0, 1.0)
            val guideAlignmentScore = guideAlignmentScore(points, imageSize)
            val lineSupportScore = longLineSupportScore(points, longLines, imageSize)
            val contrastScore = brightnessBoundaryScore(points, contrastImage)
            val regionSignals = regionSignals(points, contrastImage, edgeImage)
            val validation = boundaryValidationSignals(
                points,
                contour.toArray(),
                contrastImage,
                edgeImage,
                imageSize,
            )
            val envelopeContainment = contentEnvelope.containmentFor(points)
            if (validation.selfIntersects ||
                validation.contentContainment < 0.72 ||
                envelopeContainment < 0.80
            ) return null
            val curveScore = boundaryCurvatureScore(contour.toArray(), points, imageSize)
            val spineProximity = spineProximityScore(points, spine, imageSize)
            val twoPageStructure = twoPageStructureScore(
                points,
                spine,
                contrastImage,
                edgeImage,
            )
            val isOpenBookSpread = pageSide == null && spine != null &&
                spine.strength >= 0.35 &&
                twoPageStructure >= 0.35 &&
                bounds.width >= bounds.height * 1.15 &&
                spine.x in (bounds.x + bounds.width * 0.28)..(bounds.x + bounds.width * 0.72)
            val documentScore =
                areaRatio.coerceAtMost(1.0) * 0.32 +
                    angleScore * 0.24 +
                    rectangularity * 0.10 +
                    edgeScore * 0.10 +
                    aspectScore * 0.08 +
                    guideAlignmentScore * 0.06 +
                    lineSupportScore * 0.04 +
                    contrastScore * 0.06
            val bookScore =
                areaRatio.coerceAtMost(0.65) / 0.65 * 0.18 +
                    angleScore * 0.08 +
                    guideAlignmentScore * 0.10 +
                    spineProximity * 0.16 +
                    regionSignals.textDensity * 0.15 +
                    regionSignals.brightnessConsistency * 0.09 +
                    curveScore * 0.12 +
                    contrastScore * 0.07 +
                    lineSupportScore * 0.05
            val kind = when {
                pageSide != null -> CandidateKind.bookPage
                isOpenBookSpread -> CandidateKind.openBookSpread
                spineProximity >= 0.55 || curveScore >= 0.28 -> CandidateKind.bookPage
                else -> CandidateKind.document
            }
            val maximumContinuation = if (kind == CandidateKind.bookPage) 0.42 else 0.58
            if (validation.outsideContentContinuation >= maximumContinuation) return null
            val sidePolicy = pageSidePolicyScore(points, pageSide, imageSize, longLines)
            val overlapPenalty = overlapExpansionPenalty(points, pageSide, imageSize)
            val score = when (kind) {
                CandidateKind.openBookSpread -> documentScore - 0.24
                CandidateKind.bookPage ->
                    max(documentScore, bookScore) * 0.82 +
                        validation.outerBoundaryContinuity * 0.08 +
                        validation.contentContainment * 0.05 +
                        envelopeContainment * 0.13 +
                        sidePolicy * 0.20 -
                        validation.outsideContentContinuation * 0.20 -
                        overlapPenalty * 0.22
                CandidateKind.document ->
                    documentScore * 0.84 +
                        validation.outerBoundaryContinuity * 0.08 +
                        validation.contentContainment * 0.04 +
                        envelopeContainment * 0.12 -
                        validation.outsideContentContinuation * 0.16
            }
            return Candidate(
                points,
                contour.toArray(),
                score,
                kind,
                pageSide?.spineSide ?: if (kind == CandidateKind.bookPage) spineSideFor(points, spine) else null,
                validation.clippingEvidence,
                CandidateDebugScores(
                    area = areaRatio,
                    contentContainment = envelopeContainment,
                    outerContinuity = validation.outerBoundaryContinuity,
                    topContinuity = validation.topContinuity,
                    bottomContinuity = validation.bottomContinuity,
                    internalLinePenalty = validation.outsideContentContinuation,
                    spineScore = spineProximity,
                    sidePolicy = sidePolicy,
                ),
            )
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

    private fun representativeCorners(points: Array<Point>): Array<Point> {
        val selected = arrayOf(
            points.minBy { it.x + it.y },
            points.maxBy { it.x - it.y },
            points.maxBy { it.x + it.y },
            points.minBy { it.x - it.y },
        )
        val unique = selected.map { "${it.x.roundToInt()}:${it.y.roundToInt()}" }.toSet()
        if (unique.size == 4) return selected

        val cloud = MatOfPoint2f(*points)
        return try {
            Array(4) { Point() }.also { rectangle ->
                Imgproc.minAreaRect(cloud).points(rectangle)
            }
        } finally {
            cloud.release()
        }
    }

    private fun edgeDistanceScore(points: Array<Point>, imageSize: Size): Double {
        return 1.0 - pointsOnImageEdge(points, imageSize) / 4.0
    }

    private fun pointsOnImageEdge(points: Array<Point>, imageSize: Size): Int {
        val margin = min(imageSize.width, imageSize.height) * 0.015
        return points.count { point ->
            point.x <= margin ||
                point.y <= margin ||
                point.x >= imageSize.width - margin ||
                point.y >= imageSize.height - margin
        }
    }

    private fun guideAlignmentScore(points: Array<Point>, imageSize: Size): Double {
        val centerX = points.map { it.x }.average()
        val centerY = points.map { it.y }.average()
        val normalizedX = abs(centerX - imageSize.width / 2.0) / max(1.0, imageSize.width / 2.0)
        val normalizedY = abs(centerY - imageSize.height / 2.0) / max(1.0, imageSize.height / 2.0)
        return (1.0 - sqrt(normalizedX * normalizedX + normalizedY * normalizedY) / sqrt(2.0))
            .coerceIn(0.0, 1.0)
    }

    private fun collectLongLines(edges: Mat, imageSize: Size): List<LineSegment> {
        val lines = Mat()
        try {
            val minimumLength = min(imageSize.width, imageSize.height) * 0.22
            Imgproc.HoughLinesP(
                edges,
                lines,
                1.0,
                PI / 180.0,
                45,
                minimumLength,
                minimumLength * 0.18,
            )
            return (0 until min(lines.rows(), 80)).mapNotNull { row ->
                val values = lines.get(row, 0)
                if (values == null || values.size < 4) null else
                    LineSegment(Point(values[0], values[1]), Point(values[2], values[3]))
            }
        } finally {
            lines.release()
        }
    }

    private fun longLineSupportScore(
        points: Array<Point>,
        lines: List<LineSegment>,
        imageSize: Size,
    ): Double {
        if (lines.isEmpty()) return 0.0
        val ordered = orderCorners(points)
        val margin = min(imageSize.width, imageSize.height) * 0.035
        val supported = lines.count { line ->
            val middle = Point(
                (line.start.x + line.end.x) / 2.0,
                (line.start.y + line.end.y) / 2.0,
            )
            (ordered.indices).minOf { index ->
                distanceToSegment(middle, ordered[index], ordered[(index + 1) % ordered.size])
            } <= margin
        }
        return (supported / 4.0).coerceIn(0.0, 1.0)
    }

    private fun brightnessBoundaryScore(points: Array<Point>, gray: Mat): Double {
        val ordered = orderCorners(points)
        val margin = min(gray.cols(), gray.rows()) * 0.018
        val differences = mutableListOf<Double>()
        for (index in ordered.indices) {
            val start = ordered[index]
            val end = ordered[(index + 1) % ordered.size]
            val dx = end.x - start.x
            val dy = end.y - start.y
            val length = sqrt(dx * dx + dy * dy)
            if (length <= 1.0) continue
            val normalX = -dy / length
            val normalY = dx / length
            for (ratio in listOf(0.25, 0.5, 0.75)) {
                val x = start.x + dx * ratio
                val y = start.y + dy * ratio
                val insideX = (x + normalX * margin).roundToInt()
                val insideY = (y + normalY * margin).roundToInt()
                val outsideX = (x - normalX * margin).roundToInt()
                val outsideY = (y - normalY * margin).roundToInt()
                if (insideX !in 0 until gray.cols() ||
                    insideY !in 0 until gray.rows() ||
                    outsideX !in 0 until gray.cols() ||
                    outsideY !in 0 until gray.rows()
                ) {
                    continue
                }
                val inside = gray.get(insideY, insideX)?.firstOrNull()
                val outside = gray.get(outsideY, outsideX)?.firstOrNull()
                if (inside != null && outside != null) {
                    differences.add(abs(inside - outside) / 255.0)
                }
            }
        }
        return if (differences.isEmpty()) 0.0 else
            (differences.average() * 3.0).coerceIn(0.0, 1.0)
    }

    private fun detectSpine(gray: Mat, lines: List<LineSegment>): SpineEvidence? {
        if (gray.empty() || gray.cols() < 40 || gray.rows() < 40) return null
        val width = gray.cols()
        val height = gray.rows()
        val pixels = ByteArray(width * height)
        gray.get(0, 0, pixels)
        val searchStart = (width * 0.08).roundToInt()
        val searchEnd = (width * 0.92).roundToInt()
        val top = (height * 0.06).roundToInt()
        val bottom = (height * 0.94).roundToInt()

        var darkestX = width / 2
        var darkestMean = Double.MAX_VALUE
        val columnMeans = mutableMapOf<Int, Double>()
        for (x in searchStart..searchEnd step 3) {
            var sum = 0.0
            var count = 0
            for (y in top until bottom step 6) {
                sum += unsigned(pixels[y * width + x])
                count++
            }
            val mean = if (count == 0) 255.0 else sum / count
            columnMeans[x] = mean
            if (mean < darkestMean) {
                darkestMean = mean
                darkestX = x
            }
        }
        val comparisonOffset = max(6, (width * 0.045).roundToInt())
        fun nearbyMean(target: Int): Double {
            val nearest = columnMeans.keys.minByOrNull { abs(it - target) }
            return if (nearest == null) darkestMean else columnMeans.getValue(nearest)
        }
        val surrounding = (
            nearbyMean((darkestX - comparisonOffset).coerceAtLeast(searchStart)) +
                nearbyMean((darkestX + comparisonOffset).coerceAtMost(searchEnd))
            ) / 2.0
        val shadowStrength = ((surrounding - darkestMean) / 70.0).coerceIn(0.0, 1.0)

        val verticalLine = lines
            .mapNotNull { line ->
                val dx = abs(line.end.x - line.start.x)
                val dy = abs(line.end.y - line.start.y)
                val x = (line.start.x + line.end.x) / 2.0
                if (dy < height * 0.28 || dy < dx * 2.2 || x !in searchStart.toDouble()..searchEnd.toDouble()) {
                    null
                } else {
                    val centerScore = 1.0 - abs(x - width / 2.0) / (width / 2.0)
                    val positionWeight = 0.55 + centerScore.coerceIn(0.0, 1.0) * 0.45
                    Triple(line, x, (dy / height * positionWeight).coerceIn(0.0, 1.0))
                }
            }
            .maxByOrNull { it.third }
        val lineStrength = verticalLine?.third ?: 0.0
        val strength = max(shadowStrength, lineStrength)
        if (strength < 0.28) return null
        val centerX = when {
            verticalLine == null -> darkestX.toDouble()
            shadowStrength >= 0.22 && abs(verticalLine.second - darkestX) < width * 0.10 ->
                verticalLine.second * 0.55 + darkestX * 0.45
            lineStrength > shadowStrength -> verticalLine.second
            else -> darkestX.toDouble()
        }
        return SpineEvidence(
            x = centerX,
            strength = strength,
            curve = traceSpineCurve(pixels, width, height, centerX),
        )
    }

    private fun traceSpineCurve(
        pixels: ByteArray,
        width: Int,
        height: Int,
        centerX: Double,
    ): List<Point> {
        val radius = max(5, (width * 0.035).roundToInt())
        val raw = (0 until BOUNDARY_SAMPLE_COUNT).map { index ->
            val y = (height - 1.0) * index / (BOUNDARY_SAMPLE_COUNT - 1)
            var bestX = centerX.roundToInt().coerceIn(0, width - 1)
            var bestValue = Double.MAX_VALUE
            for (x in max(0, bestX - radius)..min(width - 1, bestX + radius) step 2) {
                var sum = 0.0
                var count = 0
                for (sampleY in max(0, y.roundToInt() - 3)..min(height - 1, y.roundToInt() + 3)) {
                    sum += unsigned(pixels[sampleY * width + x])
                    count++
                }
                val value = sum / max(1, count)
                if (value < bestValue) {
                    bestValue = value
                    bestX = x
                }
            }
            Point(bestX.toDouble(), y)
        }
        return smoothPolyline(smoothPolyline(raw))
    }

    private fun splitOpenBookCandidate(
        candidate: Candidate,
        spine: SpineEvidence?,
        gray: Mat,
        edges: Mat,
        imageSize: Size,
        imageArea: Double,
    ): List<Candidate> {
        if (candidate.kind != CandidateKind.openBookSpread || spine == null) return emptyList()
        val corners = orderCorners(candidate.points)
        val topY = min(corners[0].y, corners[1].y)
        val bottomY = max(corners[2].y, corners[3].y)
        val spinePoints = spine.curve.filter { it.y in topY..bottomY }
        if (spinePoints.size < 8) return emptyList()
        val normalizedSpine = resampleAndSmooth(spinePoints.sortedBy { it.y }, BOUNDARY_SAMPLE_COUNT)
        val spineTop = normalizedSpine.first()
        val spineBottom = normalizedSpine.last()
        val leftCorners = arrayOf(corners[0], spineTop, spineBottom, corners[3])
        val rightCorners = arrayOf(spineTop, corners[1], corners[2], spineBottom)
        val leftContour = candidate.contourPoints.filter { it.x <= spine.x }.toTypedArray() +
            normalizedSpine.toTypedArray()
        val rightContour = candidate.contourPoints.filter { it.x >= spine.x }.toTypedArray() +
            normalizedSpine.toTypedArray()
        return listOf(
            createBookPageCandidate(
                leftCorners,
                leftContour,
                normalizedSpine,
                spine,
                gray,
                edges,
                imageSize,
                imageArea,
                SpineSide.right,
            ),
            createBookPageCandidate(
                rightCorners,
                rightContour,
                normalizedSpine,
                spine,
                gray,
                edges,
                imageSize,
                imageArea,
                SpineSide.left,
            ),
        )
    }

    private fun createBookPageCandidate(
        corners: Array<Point>,
        contour: Array<Point>,
        spineCurve: List<Point>,
        spine: SpineEvidence,
        gray: Mat,
        edges: Mat,
        imageSize: Size,
        imageArea: Double,
        spineSide: SpineSide,
    ): Candidate {
        val areaRatio = polygonArea(corners) / imageArea
        val signals = regionSignals(corners, gray, edges)
        val score =
            (areaRatio / 0.55).coerceIn(0.0, 1.0) * 0.14 +
                rightAngleScore(corners) * 0.06 +
                guideAlignmentScore(corners, imageSize) * 0.12 +
                spine.strength * 0.20 +
                signals.textDensity * 0.18 +
                signals.brightnessConsistency * 0.10 +
                curveDeviationScore(spineCurve, imageSize) * 0.12 +
                brightnessBoundaryScore(corners, gray) * 0.08
        val validation = boundaryValidationSignals(corners, contour, gray, edges, imageSize)
        val safeScore = if (
            validation.selfIntersects ||
            validation.contentContainment < 0.72 ||
            validation.outsideContentContinuation >= 0.42
        ) {
            -1.0
        } else {
            score * 0.82 +
                validation.outerBoundaryContinuity * 0.08 +
                validation.contentContainment * 0.10 -
                validation.outsideContentContinuation * 0.20
        }
        return Candidate(
            corners,
            contour,
            safeScore,
            CandidateKind.bookPage,
            spineSide,
            validation.clippingEvidence,
        )
    }

    private fun regionSignals(
        points: Array<Point>,
        gray: Mat,
        edges: Mat,
    ): RegionSignals {
        val minX = points.minOf { it.x }.roundToInt().coerceIn(0, gray.cols() - 1)
        val maxX = points.maxOf { it.x }.roundToInt().coerceIn(0, gray.cols() - 1)
        val minY = points.minOf { it.y }.roundToInt().coerceIn(0, gray.rows() - 1)
        val maxY = points.maxOf { it.y }.roundToInt().coerceIn(0, gray.rows() - 1)
        val brightness = mutableListOf<Double>()
        var edgeSamples = 0
        var total = 0
        for (row in 1 until 20) {
            val y = minY + (maxY - minY) * row / 20
            for (column in 1 until 20) {
                val x = minX + (maxX - minX) * column / 20
                val point = Point(x.toDouble(), y.toDouble())
                if (!pointInsidePolygon(point, points)) continue
                brightness.add(gray.get(y, x)?.firstOrNull() ?: continue)
                if ((edges.get(y, x)?.firstOrNull() ?: 0.0) > 0.0) edgeSamples++
                total++
            }
        }
        if (total == 0) return RegionSignals(0.0, 0.0)
        val mean = brightness.average()
        val deviation = sqrt(brightness.sumOf { (it - mean) * (it - mean) } / brightness.size)
        return RegionSignals(
            textDensity = (edgeSamples.toDouble() / total * 9.0).coerceIn(0.0, 1.0),
            brightnessConsistency = (1.0 - deviation / 90.0).coerceIn(0.0, 1.0),
        )
    }

    private fun pointInsidePolygon(point: Point, points: Array<Point>): Boolean {
        var inside = false
        var previous = points.last()
        points.forEach { current ->
            if ((current.y > point.y) != (previous.y > point.y) &&
                point.x <
                (previous.x - current.x) * (point.y - current.y) /
                    (previous.y - current.y) + current.x
            ) {
                inside = !inside
            }
            previous = current
        }
        return inside
    }

    /**
     * Rejects horizontal content structures masquerading as the page edge.
     * A real top/bottom edge separates page content from an outward region;
     * an underline or table rule usually has page-like brightness and text
     * edges continuing on its outward side.
     */
    private fun boundaryValidationSignals(
        points: Array<Point>,
        contour: Array<Point>,
        gray: Mat,
        edges: Mat,
        imageSize: Size,
    ): BoundaryValidationSignals {
        val ordered = orderCorners(points).toTypedArray()
        if (segmentsIntersect(ordered[0], ordered[1], ordered[2], ordered[3]) ||
            segmentsIntersect(ordered[1], ordered[2], ordered[3], ordered[0])
        ) {
            return BoundaryValidationSignals(1.0, 0.0, 0.0, 0.0, true, 1.0, 1.0)
        }

        val minX = ordered.minOf { it.x }
        val maxX = ordered.maxOf { it.x }
        val topY = (ordered[0].y + ordered[1].y) / 2.0
        val bottomY = (ordered[2].y + ordered[3].y) / 2.0
        val pageWidth = maxX - minX
        val pageHeight = bottomY - topY
        if (pageWidth < 8.0 || pageHeight < 8.0) {
            return BoundaryValidationSignals(1.0, 0.0, 0.0, 0.0, false, 1.0, 1.0)
        }

        val xInset = pageWidth * 0.12
        val bandDepth = pageHeight * 0.18
        val gap = pageHeight * 0.02
        val xStart = minX + xInset
        val xEnd = maxX - xInset
        val topInside = sampleBand(
            gray,
            edges,
            xStart,
            xEnd,
            topY + gap,
            topY + bandDepth,
        )
        val topOutside = sampleBand(
            gray,
            edges,
            xStart,
            xEnd,
            topY - bandDepth,
            topY - gap,
        )
        val bottomInside = sampleBand(
            gray,
            edges,
            xStart,
            xEnd,
            bottomY - bandDepth,
            bottomY - gap,
        )
        val bottomOutside = sampleBand(
            gray,
            edges,
            xStart,
            xEnd,
            bottomY + gap,
            bottomY + bandDepth,
        )
        val topContinuation = contentContinuation(topInside, topOutside)
        val bottomContinuation = contentContinuation(bottomInside, bottomOutside)
        val continuation = max(topContinuation, bottomContinuation)
        val contrast = brightnessBoundaryScore(points, gray)
        return BoundaryValidationSignals(
            outsideContentContinuation = continuation,
            contentContainment = (1.0 - continuation * 0.55).coerceIn(0.0, 1.0),
            outerBoundaryContinuity = (contrast * 0.70 + (1.0 - continuation) * 0.30)
                .coerceIn(0.0, 1.0),
            clippingEvidence = contourClippingEvidence(contour, imageSize),
            selfIntersects = false,
            topContinuity = topContinuation,
            bottomContinuity = bottomContinuation,
        )
    }

    /** Samples text/edge content only in the page-owned part of a spread ROI. */
    private fun contentEnvelope(edges: Mat, pageSide: PageSide?): ContentEnvelope {
        val width = edges.cols()
        val height = edges.rows()
        val marginX = (width * 0.02).roundToInt()
        val marginY = (height * 0.02).roundToInt()
        val spineExclusion = (width * 0.18).roundToInt()
        val startX = when (pageSide) {
            PageSide.right -> marginX + spineExclusion
            else -> marginX
        }.coerceIn(0, width - 1)
        val endX = when (pageSide) {
            PageSide.left -> width - 1 - marginX - spineExclusion
            else -> width - 1 - marginX
        }.coerceIn(startX, width - 1)
        val points = mutableListOf<Point>()
        val step = max(2, min(width, height) / 260)
        for (y in marginY until height - marginY step step) {
            for (x in startX..endX step step) {
                if ((edges.get(y, x)?.firstOrNull() ?: 0.0) > 0.0) {
                    points.add(Point(x.toDouble(), y.toDouble()))
                }
            }
        }
        return ContentEnvelope(points)
    }

    private fun pageSidePolicyScore(
        points: Array<Point>,
        pageSide: PageSide?,
        imageSize: Size,
        lines: List<LineSegment>,
    ): Double {
        if (pageSide == null) return 0.0
        val ordered = orderCorners(points)
        val outerStart = if (pageSide == PageSide.left) ordered[3] else ordered[1]
        val outerEnd = if (pageSide == PageSide.left) ordered[0] else ordered[2]
        val outerX = (outerStart.x + outerEnd.x) / 2.0
        val position = if (pageSide == PageSide.left) {
            (1.0 - outerX / max(1.0, imageSize.width * 0.62)).coerceIn(0.0, 1.0)
        } else {
            (1.0 - (imageSize.width - outerX) / max(1.0, imageSize.width * 0.62))
                .coerceIn(0.0, 1.0)
        }
        val supportMargin = min(imageSize.width, imageSize.height) * 0.035
        val verticalSupport = lines.count { line ->
            val dx = abs(line.end.x - line.start.x)
            val dy = abs(line.end.y - line.start.y)
            dy >= dx * 1.8 &&
                distanceToSegment(
                    Point((line.start.x + line.end.x) / 2.0, (line.start.y + line.end.y) / 2.0),
                    outerStart,
                    outerEnd,
                ) <= supportMargin
        }
        return position * 0.72 + (verticalSupport / 2.0).coerceIn(0.0, 1.0) * 0.28
    }

    /**
     * Builds a spread-only page candidate from the manually aligned ROI prior.
     * The outer, top, and bottom paper edges are mandatory anchors; the spine
     * anchor is allowed to remain weak because rings, folds, and shadows are
     * expected in that search zone.
     */
    private fun spreadPriorCandidate(
        gray: Mat,
        edges: Mat,
        imageSize: Size,
        imageArea: Double,
        contentEnvelope: ContentEnvelope,
        pageSide: PageSide,
    ): Candidate? {
        val width = imageSize.width.roundToInt()
        val height = imageSize.height.roundToInt()
        if (width < 40 || height < 40) return null

        val outerRange = if (pageSide == PageSide.left) 0.0 to 0.28 else 0.72 to 1.0
        val spineRange = if (pageSide == PageSide.left) 0.70 to 0.97 else 0.03 to 0.30
        val outerTarget = if (pageSide == PageSide.left) 0.03 else 0.97
        val spineTarget = if (pageSide == PageSide.left) 0.91 else 0.09
        val outer = strongestVerticalAnchor(
            gray,
            edges,
            outerRange,
            0.05 to 0.95,
            outerTarget,
        )
        val spine = strongestVerticalAnchor(
            gray,
            edges,
            spineRange,
            0.05 to 0.95,
            spineTarget,
        )
        val ownedStart = if (pageSide == PageSide.left) outer.coordinate else spine.coordinate
        val ownedEnd = if (pageSide == PageSide.left) spine.coordinate else outer.coordinate
        if (ownedEnd - ownedStart < width * 0.42) return null
        val top = strongestHorizontalAnchor(
            gray,
            edges,
            0.01 to 0.27,
            ownedStart / width to ownedEnd / width,
            0.04,
        )
        val bottom = strongestHorizontalAnchor(
            gray,
            edges,
            0.73 to 0.99,
            ownedStart / width to ownedEnd / width,
            0.96,
        )
        if (bottom.coordinate - top.coordinate < height * 0.45) return null
        if (outer.support < 0.045 || top.support < 0.035 || bottom.support < 0.035) {
            return null
        }

        val corners = if (pageSide == PageSide.left) {
            arrayOf(
                Point(outer.coordinate, top.coordinate),
                Point(spine.coordinate, top.coordinate),
                Point(spine.coordinate, bottom.coordinate),
                Point(outer.coordinate, bottom.coordinate),
            )
        } else {
            arrayOf(
                Point(spine.coordinate, top.coordinate),
                Point(outer.coordinate, top.coordinate),
                Point(outer.coordinate, bottom.coordinate),
                Point(spine.coordinate, bottom.coordinate),
            )
        }
        val envelopeContainment = contentEnvelope.containmentFor(corners)
        if (envelopeContainment < 0.80) return null
        val validation = boundaryValidationSignals(corners, corners, gray, edges, imageSize)
        if (validation.selfIntersects || validation.outsideContentContinuation >= 0.42) {
            return null
        }
        val areaRatio = polygonArea(corners) / imageArea
        val anchorScore =
            outer.support * 0.22 +
                top.support * 0.16 +
                bottom.support * 0.16 +
                spine.support * 0.04
        val score =
            0.38 +
                anchorScore +
                envelopeContainment * 0.14 +
                validation.outerBoundaryContinuity * 0.06 -
                validation.outsideContentContinuation * 0.12
        return Candidate(
            points = corners,
            contourPoints = corners,
            score = score,
            kind = CandidateKind.bookPage,
            spineSide = pageSide.spineSide,
            clippingEvidence = validation.clippingEvidence,
            debugScores = CandidateDebugScores(
                area = areaRatio,
                contentContainment = envelopeContainment,
                outerContinuity = validation.outerBoundaryContinuity,
                topContinuity = validation.topContinuity,
                bottomContinuity = validation.bottomContinuity,
                internalLinePenalty = validation.outsideContentContinuation,
                spineScore = spine.support,
                sidePolicy = outer.support,
            ),
        )
    }

    private fun strongestVerticalAnchor(
        gray: Mat,
        edges: Mat,
        xRange: Pair<Double, Double>,
        yRange: Pair<Double, Double>,
        target: Double,
    ): BoundaryAnchor {
        val width = edges.cols()
        val height = edges.rows()
        val start = (width * xRange.first).roundToInt().coerceIn(1, width - 2)
        val end = (width * xRange.second).roundToInt().coerceIn(start, width - 2)
        val yStart = (height * yRange.first).roundToInt().coerceIn(1, height - 2)
        val yEnd = (height * yRange.second).roundToInt().coerceIn(yStart + 1, height - 1)
        val yStep = max(1, (yEnd - yStart) / 180)
        var best = BoundaryAnchor(width * target, 0.0, -1.0)
        for (x in start..end) {
            var edgeHits = 0
            var gradient = 0.0
            var samples = 0
            for (y in yStart until yEnd step yStep) {
                if ((edges.get(y, x)?.firstOrNull() ?: 0.0) > 0.0) edgeHits++
                val before = gray.get(y, x - 1)?.firstOrNull() ?: continue
                val after = gray.get(y, x + 1)?.firstOrNull() ?: continue
                gradient += abs(after - before) / 255.0
                samples++
            }
            if (samples == 0) continue
            val support = edgeHits.toDouble() / samples * 0.75 +
                (gradient / samples).coerceIn(0.0, 1.0) * 0.25
            val positionPrior =
                (1.0 - abs(x.toDouble() / width - target) /
                    max(0.01, xRange.second - xRange.first)).coerceIn(0.0, 1.0)
            val selectionScore = support * 0.86 + positionPrior * 0.14
            if (selectionScore > best.selectionScore) {
                best = BoundaryAnchor(x.toDouble(), support, selectionScore)
            }
        }
        return best
    }

    private fun strongestHorizontalAnchor(
        gray: Mat,
        edges: Mat,
        yRange: Pair<Double, Double>,
        xRange: Pair<Double, Double>,
        target: Double,
    ): BoundaryAnchor {
        val width = edges.cols()
        val height = edges.rows()
        val start = (height * yRange.first).roundToInt().coerceIn(1, height - 2)
        val end = (height * yRange.second).roundToInt().coerceIn(start, height - 2)
        val xStart = (width * xRange.first).roundToInt().coerceIn(1, width - 2)
        val xEnd = (width * xRange.second).roundToInt().coerceIn(xStart + 1, width - 1)
        val xStep = max(1, (xEnd - xStart) / 220)
        var best = BoundaryAnchor(height * target, 0.0, -1.0)
        for (y in start..end) {
            var edgeHits = 0
            var gradient = 0.0
            var samples = 0
            for (x in xStart until xEnd step xStep) {
                if ((edges.get(y, x)?.firstOrNull() ?: 0.0) > 0.0) edgeHits++
                val before = gray.get(y - 1, x)?.firstOrNull() ?: continue
                val after = gray.get(y + 1, x)?.firstOrNull() ?: continue
                gradient += abs(after - before) / 255.0
                samples++
            }
            if (samples == 0) continue
            val support = edgeHits.toDouble() / samples * 0.75 +
                (gradient / samples).coerceIn(0.0, 1.0) * 0.25
            val positionPrior =
                (1.0 - abs(y.toDouble() / height - target) /
                    max(0.01, yRange.second - yRange.first)).coerceIn(0.0, 1.0)
            val selectionScore = support * 0.86 + positionPrior * 0.14
            if (selectionScore > best.selectionScore) {
                best = BoundaryAnchor(y.toDouble(), support, selectionScore)
            }
        }
        return best
    }

    private fun overlapExpansionPenalty(
        points: Array<Point>,
        pageSide: PageSide?,
        imageSize: Size,
    ): Double {
        if (pageSide == null) return 0.0
        val ordered = orderCorners(points)
        val spineX = if (pageSide == PageSide.left) {
            (ordered[1].x + ordered[2].x) / 2.0
        } else {
            (ordered[0].x + ordered[3].x) / 2.0
        }
        return if (pageSide == PageSide.left) {
            ((spineX / imageSize.width - 0.94) / 0.06).coerceIn(0.0, 1.0)
        } else {
            (((1.0 - spineX / imageSize.width) - 0.94) / 0.06).coerceIn(0.0, 1.0)
        }
    }

    private fun sampleBand(
        gray: Mat,
        edges: Mat,
        xStartValue: Double,
        xEndValue: Double,
        yStartValue: Double,
        yEndValue: Double,
    ): BandSignals {
        val xStart = xStartValue.roundToInt().coerceIn(0, gray.cols() - 1)
        val xEnd = xEndValue.roundToInt().coerceIn(0, gray.cols() - 1)
        val yStart = yStartValue.roundToInt().coerceIn(0, gray.rows() - 1)
        val yEnd = yEndValue.roundToInt().coerceIn(0, gray.rows() - 1)
        if (xEnd <= xStart || yEnd <= yStart) return BandSignals.empty
        val xStep = max(1, (xEnd - xStart) / 48)
        val yStep = max(1, (yEnd - yStart) / 14)
        var brightness = 0.0
        var edgeCount = 0
        var count = 0
        for (y in yStart..yEnd step yStep) {
            for (x in xStart..xEnd step xStep) {
                brightness += gray.get(y, x)?.firstOrNull() ?: continue
                if ((edges.get(y, x)?.firstOrNull() ?: 0.0) > 0.0) edgeCount++
                count++
            }
        }
        return if (count < 20) BandSignals.empty else BandSignals(
            brightness / count,
            edgeCount.toDouble() / count,
            count,
        )
    }

    private fun contentContinuation(inside: BandSignals, outside: BandSignals): Double {
        if (inside.samples < 20 || outside.samples < 20) return 0.0
        val relativeEdges = (outside.edgeDensity / max(inside.edgeDensity, 0.012))
            .coerceIn(0.0, 1.0)
        val absoluteEdges = (outside.edgeDensity * 12.0).coerceIn(0.0, 1.0)
        val textContinuation = min(relativeEdges, absoluteEdges)
        val brightnessSimilarity =
            (1.0 - abs(inside.meanBrightness - outside.meanBrightness) / 55.0)
                .coerceIn(0.0, 1.0)
        return (textContinuation * 0.78 + brightnessSimilarity * 0.22)
            .coerceIn(0.0, 1.0)
    }

    private fun contourClippingEvidence(contour: Array<Point>, imageSize: Size): Double {
        if (contour.size < 4) return 0.0
        val margin = min(imageSize.width, imageSize.height) * 0.006
        fun hasVerticalContact(points: List<Point>): Boolean =
            points.size >= 2 &&
                points.maxOf { it.y } - points.minOf { it.y } >= imageSize.height * 0.06
        fun hasHorizontalContact(points: List<Point>): Boolean =
            points.size >= 2 &&
                points.maxOf { it.x } - points.minOf { it.x } >= imageSize.width * 0.06
        val contacts = listOf(
            hasVerticalContact(contour.filter { it.x <= margin }),
            hasVerticalContact(contour.filter { it.x >= imageSize.width - 1 - margin }),
            hasHorizontalContact(contour.filter { it.y <= margin }),
            hasHorizontalContact(contour.filter { it.y >= imageSize.height - 1 - margin }),
        ).count { it }
        return (contacts / 2.0).coerceIn(0.0, 1.0)
    }

    private fun segmentsIntersect(a: Point, b: Point, c: Point, d: Point): Boolean {
        fun cross(p: Point, q: Point, r: Point): Double =
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        val first = cross(a, b, c)
        val second = cross(a, b, d)
        val third = cross(c, d, a)
        val fourth = cross(c, d, b)
        return first * second < 0.0 && third * fourth < 0.0
    }

    private fun boundaryCurvatureScore(
        contour: Array<Point>,
        corners: Array<Point>,
        imageSize: Size,
    ): Double {
        if (contour.isEmpty()) return 0.0
        val ordered = orderCorners(corners)
        val distances = contour.map { point ->
            ordered.indices.minOf { index ->
                distanceToSegment(point, ordered[index], ordered[(index + 1) % ordered.size])
            }
        }.sorted()
        val typical = distances[(distances.size * 0.75).toInt().coerceAtMost(distances.lastIndex)]
        return (typical / min(imageSize.width, imageSize.height) * 24.0).coerceIn(0.0, 1.0)
    }

    private fun curveDeviationScore(curve: List<Point>, imageSize: Size): Double {
        if (curve.size < 3) return 0.0
        val start = curve.first()
        val end = curve.last()
        val maximum = curve.maxOf { distanceToSegment(it, start, end) }
        return (maximum / min(imageSize.width, imageSize.height) * 20.0).coerceIn(0.0, 1.0)
    }

    private fun spineProximityScore(
        points: Array<Point>,
        spine: SpineEvidence?,
        imageSize: Size,
    ): Double {
        if (spine == null) return 0.0
        val ordered = orderCorners(points)
        val leftX = (ordered[0].x + ordered[3].x) / 2.0
        val rightX = (ordered[1].x + ordered[2].x) / 2.0
        val distance = min(abs(leftX - spine.x), abs(rightX - spine.x))
        return (1.0 - distance / max(1.0, imageSize.width * 0.28)).coerceIn(0.0, 1.0) *
            spine.strength
    }

    private fun twoPageStructureScore(
        points: Array<Point>,
        spine: SpineEvidence?,
        gray: Mat,
        edges: Mat,
    ): Double {
        if (spine == null) return 0.0
        val ordered = orderCorners(points)
        val top = min(ordered[0].y, ordered[1].y)
        val bottom = max(ordered[2].y, ordered[3].y)
        val leftX = min(ordered[0].x, ordered[3].x)
        val rightX = max(ordered[1].x, ordered[2].x)
        if (spine.x <= leftX || spine.x >= rightX) return 0.0
        val left = arrayOf(
            ordered[0],
            Point(spine.x, top),
            Point(spine.x, bottom),
            ordered[3],
        )
        val right = arrayOf(
            Point(spine.x, top),
            ordered[1],
            ordered[2],
            Point(spine.x, bottom),
        )
        val leftSignals = regionSignals(left, gray, edges)
        val rightSignals = regionSignals(right, gray, edges)
        return min(leftSignals.textDensity, rightSignals.textDensity) * 0.72 +
            min(leftSignals.brightnessConsistency, rightSignals.brightnessConsistency) * 0.28
    }

    private fun spineSideFor(points: Array<Point>, spine: SpineEvidence?): SpineSide? {
        if (spine == null) return null
        val ordered = orderCorners(points)
        val leftX = (ordered[0].x + ordered[3].x) / 2.0
        val rightX = (ordered[1].x + ordered[2].x) / 2.0
        return if (abs(leftX - spine.x) <= abs(rightX - spine.x)) {
            SpineSide.left
        } else {
            SpineSide.right
        }
    }

    private fun polygonArea(points: Array<Point>): Double {
        var sum = 0.0
        for (index in points.indices) {
            val current = points[index]
            val next = points[(index + 1) % points.size]
            sum += current.x * next.y - next.x * current.y
        }
        return abs(sum) / 2.0
    }

    private fun orderCorners(points: Array<Point>): List<Point> {
        val top = points.sortedBy { it.y }.take(2).sortedBy { it.x }
        val bottom = points.sortedByDescending { it.y }.take(2).sortedBy { it.x }
        return listOf(top[0], top[1], bottom[1], bottom[0])
    }

    private fun pointMap(point: Point): Map<String, Double> =
        mapOf("x" to point.x, "y" to point.y)

    private fun unsigned(value: Byte): Int = value.toInt() and 0xff

    private fun boundaryMap(
        contour: Array<Point>,
        corners: List<Point>,
        scale: Double,
        sourceWidth: Int,
        sourceHeight: Int,
        confidence: Double,
        spineSide: SpineSide?,
        clippingEvidence: Double,
    ): Map<String, Any> {
        val edgeStarts = listOf(corners[0], corners[1], corners[2], corners[3])
        val edgeEnds = listOf(corners[1], corners[2], corners[3], corners[0])
        val groups = List(4) { mutableListOf<Point>() }
        contour.forEach { point ->
            val edge = (0 until 4).minByOrNull { index ->
                distanceToSegment(point, edgeStarts[index], edgeEnds[index])
            } ?: 0
            groups[edge].add(point)
        }
        val edges = groups.mapIndexed { index, points ->
            points.add(edgeStarts[index])
            points.add(edgeEnds[index])
            val ordered = points.sortedBy { projection(it, edgeStarts[index], edgeEnds[index]) }
            resampleAndSmooth(ordered, BOUNDARY_SAMPLE_COUNT)
                .map { Point(it.x / scale, it.y / scale) }
        }
        return mapOf(
            "top" to edges[0].map(::pointMap),
            "right" to edges[1].map(::pointMap),
            "bottom" to edges[2].map(::pointMap),
            "left" to edges[3].map(::pointMap),
            "confidence" to confidence.coerceIn(0.0, 1.0),
            "stability" to 0.0,
            "sourceWidth" to sourceWidth,
            "sourceHeight" to sourceHeight,
            "timestamp" to System.currentTimeMillis(),
            "spineSide" to (spineSide?.value ?: ""),
            "clippingEvidence" to clippingEvidence.coerceIn(0.0, 1.0),
        )
    }

    private fun resampleAndSmooth(points: List<Point>, sampleCount: Int): List<Point> {
        if (points.size <= 2) return points
        val lengths = DoubleArray(points.size)
        for (index in 1 until points.size) {
            lengths[index] = lengths[index - 1] +
                sqrt(
                    (points[index].x - points[index - 1].x) *
                        (points[index].x - points[index - 1].x) +
                        (points[index].y - points[index - 1].y) *
                        (points[index].y - points[index - 1].y),
                )
        }
        val total = lengths.last()
        if (total <= 0.0) return listOf(points.first(), points.last())
        val sampled = MutableList(sampleCount) { points.first() }
        var segment = 1
        for (index in 0 until sampleCount) {
            val target = total * index / (sampleCount - 1)
            while (segment < lengths.size - 1 && lengths[segment] < target) segment++
            val before = segment - 1
            val length = lengths[segment] - lengths[before]
            val ratio = if (length <= 0.0) 0.0 else (target - lengths[before]) / length
            sampled[index] = Point(
                points[before].x + (points[segment].x - points[before].x) * ratio,
                points[before].y + (points[segment].y - points[before].y) * ratio,
            )
        }
        return smoothPolyline(smoothPolyline(sampled))
    }

    private fun smoothPolyline(points: List<Point>): List<Point> =
        points.mapIndexed { index, point ->
            if (index == 0 || index == points.lastIndex) {
                point
            } else {
                Point(
                    points[index - 1].x * 0.25 + point.x * 0.5 + points[index + 1].x * 0.25,
                    points[index - 1].y * 0.25 + point.y * 0.5 + points[index + 1].y * 0.25,
                )
            }
        }

    private fun projection(point: Point, start: Point, end: Point): Double {
        val dx = end.x - start.x
        val dy = end.y - start.y
        val lengthSquared = dx * dx + dy * dy
        return if (lengthSquared <= 0.0) 0.0 else
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
    }

    private fun distanceToSegment(point: Point, start: Point, end: Point): Double {
        val ratio = projection(point, start, end).coerceIn(0.0, 1.0)
        val x = start.x + (end.x - start.x) * ratio
        val y = start.y + (end.y - start.y) * ratio
        val dx = point.x - x
        val dy = point.y - y
        return sqrt(dx * dx + dy * dy)
    }

    private fun notDetected(sourceWidth: Int, sourceHeight: Int): Map<String, Any> =
        mapOf(
            "detected" to false,
            "confidence" to 0.0,
            "sourceWidth" to sourceWidth,
            "sourceHeight" to sourceHeight,
        )

    private data class Candidate(
        val points: Array<Point>,
        val contourPoints: Array<Point>,
        val score: Double,
        val kind: CandidateKind,
        val spineSide: SpineSide?,
        val clippingEvidence: Double,
        val debugScores: CandidateDebugScores = CandidateDebugScores(),
    )

    private data class LineSegment(val start: Point, val end: Point)

    private data class BoundaryAnchor(
        val coordinate: Double,
        val support: Double,
        val selectionScore: Double,
    )

    private data class SpineEvidence(
        val x: Double,
        val strength: Double,
        val curve: List<Point>,
    )

    private data class RegionSignals(
        val textDensity: Double,
        val brightnessConsistency: Double,
    )

    private data class BandSignals(
        val meanBrightness: Double,
        val edgeDensity: Double,
        val samples: Int,
    ) {
        companion object {
            val empty = BandSignals(0.0, 0.0, 0)
        }
    }

    private data class BoundaryValidationSignals(
        val outsideContentContinuation: Double,
        val contentContainment: Double,
        val outerBoundaryContinuity: Double,
        val clippingEvidence: Double,
        val selfIntersects: Boolean,
        val topContinuity: Double,
        val bottomContinuity: Double,
    )

    private data class ContentEnvelope(val points: List<Point>) {
        fun containmentFor(candidate: Array<Point>): Double {
            if (points.size < 16) return 1.0
            return points.count { point -> pointInsidePolygon(point, candidate) }
                .toDouble() / points.size
        }
    }

    private data class CandidateDebugScores(
        val area: Double = 0.0,
        val contentContainment: Double = 1.0,
        val outerContinuity: Double = 1.0,
        val topContinuity: Double = 0.0,
        val bottomContinuity: Double = 0.0,
        val internalLinePenalty: Double = 0.0,
        val spineScore: Double = 0.0,
        val sidePolicy: Double = 0.0,
    )

    private enum class CandidateKind { document, bookPage, openBookSpread }

    private enum class SpineSide(val value: String) { left("left"), right("right") }

    private enum class PageSide(
        val value: String,
        val spineSide: SpineSide,
    ) {
        left("left", SpineSide.right),
        right("right", SpineSide.left),
        ;

        companion object {
            fun fromValue(value: String?): PageSide? =
                entries.firstOrNull { it.value == value }
        }
    }

    private fun logCandidate(
        candidate: Candidate,
        pageSide: PageSide?,
        debugLogging: Boolean,
    ) {
        if (!debugLogging) return
        val scores = candidate.debugScores
        Log.d(
            "ScanaDetector",
            "candidate area=${scores.area} " +
                "contentContainment=${scores.contentContainment} " +
                "outerContinuity=${scores.outerContinuity} " +
                "topContinuity=${scores.topContinuity} " +
                "bottomContinuity=${scores.bottomContinuity} " +
                "internalLinePenalty=${scores.internalLinePenalty} " +
                "spineScore=${scores.spineScore} " +
                "pageSide=${pageSide?.value ?: "single"} " +
                "sidePolicy=${scores.sidePolicy} finalScore=${candidate.score}",
        )
    }
}
