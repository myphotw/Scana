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
    private const val MIN_AREA_RATIO = 0.12
    private const val MIN_CANDIDATE_SCORE = 0.32
    private const val MIN_BOUNDARY_CONFIDENCE = 0.38
    private const val MIN_PREVIEW_CANDIDATE_SCORE = 0.22
    private const val MIN_PREVIEW_BOUNDARY_CONFIDENCE = 0.22
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
            val eligible = candidates
                .filter {
                    it.score >= MIN_CANDIDATE_SCORE &&
                        it.confidence >= MIN_BOUNDARY_CONFIDENCE
                }
            val best = selectConservativeCandidate(eligible, imageArea)
            logCandidates(candidates, pageSide, debugLogging, best)
            if (best == null) return notDetected(sourceWidth, sourceHeight)
            val ordered = orderCorners(best.points).map { point ->
                Point(point.x / scale, point.y / scale)
            }

            return mapOf(
                "detected" to true,
                "confidence" to best.confidence,
                "sourceWidth" to sourceWidth,
                "sourceHeight" to sourceHeight,
                "corners" to ordered.map(::pointMap),
                "boundary" to boundaryMap(
                    best.contourPoints,
                    orderCorners(best.points),
                    scale,
                    sourceWidth,
                    sourceHeight,
                    best.confidence,
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
                }).filter {
                    it.score >= MIN_PREVIEW_CANDIDATE_SCORE &&
                        it.confidence >= MIN_PREVIEW_BOUNDARY_CONFIDENCE
                }
                    .maxByOrNull { it.score }
                    ?: return notDetected(width, height)
            val ordered = orderCorners(best.points).map { Point(it.x / scale, it.y / scale) }
            return mapOf(
                "detected" to true,
                "confidence" to best.confidence,
                "sourceWidth" to width,
                "sourceHeight" to height,
                "corners" to ordered.map(::pointMap),
                "boundary" to boundaryMap(
                    best.contourPoints,
                    orderCorners(best.points),
                    scale,
                    width,
                    height,
                    best.confidence,
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
            val widthRatio = bounds.width / imageSize.width
            val heightRatio = bounds.height / imageSize.height
            if (widthRatio < 0.30 || heightRatio < 0.30) return null
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
            val occupancy = occupancyScore(areaRatio, pageSide)
            val borderProximity = borderProximityScore(points, imageSize, pageSide)
            val paperScore = paperInteriorScore(regionSignals)
            val smallCandidatePenalty = smallCandidatePenalty(areaRatio, pageSide)
            val internalLinePenalty = max(
                internalLinePenalty(
                    contrastScore,
                    borderProximity,
                    smallCandidatePenalty,
                    validation.outsideContentContinuation,
                ),
                repeatedHorizontalBoundaryPenalty(points, longLines),
            )
            val minimumModeArea = if (pageSide == null) 0.14 else 0.24
            val minimumWidth = if (pageSide == null) 0.46 else 0.42
            val minimumHeight = if (pageSide == null) 0.48 else 0.48
            if (areaRatio < minimumModeArea || widthRatio < minimumWidth ||
                heightRatio < minimumHeight || internalLinePenalty >= 0.82
            ) return null
            val score = when (kind) {
                CandidateKind.openBookSpread -> documentScore - 0.24
                CandidateKind.bookPage ->
                    max(documentScore, bookScore) * 0.05 +
                        occupancy * 0.22 +
                        borderProximity * 0.16 +
                        contrastScore * 0.11 +
                        paperScore * 0.13 +
                        rectangularity * 0.06 +
                        validation.outerBoundaryContinuity * 0.10 +
                        sidePolicy * 0.11 +
                        envelopeContainment * 0.06 +
                        spineProximity * 0.02 +
                        curveScore * 0.02 -
                        internalLinePenalty * 0.28 -
                        smallCandidatePenalty * 0.22 -
                        validation.outsideContentContinuation * 0.10 -
                        overlapPenalty * 0.20
                CandidateKind.document ->
                    documentScore * 0.08 +
                        occupancy * 0.24 +
                        borderProximity * 0.16 +
                        contrastScore * 0.14 +
                        paperScore * 0.14 +
                        rectangularity * 0.08 +
                        validation.outerBoundaryContinuity * 0.08 +
                        envelopeContainment * 0.08 -
                        internalLinePenalty * 0.28 -
                        smallCandidatePenalty * 0.22 -
                        validation.outsideContentContinuation * 0.10
            }
            val confidence = candidateConfidence(
                occupancy,
                borderProximity,
                contrastScore,
                paperScore,
                rectangularity,
                validation.outerBoundaryContinuity,
                internalLinePenalty,
                smallCandidatePenalty,
            )
            return Candidate(
                points,
                contour.toArray(),
                score,
                confidence,
                kind,
                pageSide?.spineSide ?: if (kind == CandidateKind.bookPage) spineSideFor(points, spine) else null,
                validation.clippingEvidence,
                CandidateDebugScores(
                    occupancy = occupancy,
                    borderProximity = borderProximity,
                    insideOutsideContrast = contrastScore,
                    paperScore = paperScore,
                    rectangularity = rectangularity,
                    edgeContinuity = validation.outerBoundaryContinuity,
                    contentContainment = envelopeContainment,
                    internalLinePenalty = internalLinePenalty,
                    smallCandidatePenalty = smallCandidatePenalty,
                    outsideContinuationPenalty = validation.outsideContentContinuation,
                    widthRatio = widthRatio,
                    heightRatio = heightRatio,
                    areaRatio = areaRatio,
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

    /** Presentation-only preview ROI split. Detection scoring remains unchanged. */
    fun detectPreviewForPage(
        luminance: ByteArray, width: Int, height: Int, rowStride: Int,
        pageSide: String, sensorOrientation: Int,
    ): Map<String, Any> {
        val left = pageSide == "left"
        val start = if (left) 0.0 else 0.45
        val end = if (left) 0.55 else 1.0
        val roi = when (sensorOrientation) {
            90 -> PreviewRoi(0, (height * (1 - end)).toInt(), width, (height * (1 - start)).toInt())
            270 -> PreviewRoi(0, (height * start).toInt(), width, (height * end).toInt())
            180 -> PreviewRoi((width * (1 - end)).toInt(), 0, (width * (1 - start)).toInt(), height)
            else -> PreviewRoi((width * start).toInt(), 0, (width * end).toInt(), height)
        }.clamped(width, height)
        val cropped = ByteArray(roi.width * roi.height)
        for (row in 0 until roi.height) {
            System.arraycopy(luminance, (roi.top + row) * rowStride + roi.left, cropped, row * roi.width, roi.width)
        }
        val result = detectPreview(cropped, roi.width, roi.height, roi.width)
        if (result["detected"] != true) return notDetected(width, height)
        fun shift(value: Any?): Map<String, Double>? {
            val point = value as? Map<*, *> ?: return null
            val x = (point["x"] as? Number)?.toDouble() ?: return null
            val y = (point["y"] as? Number)?.toDouble() ?: return null
            return mapOf("x" to x + roi.left, "y" to y + roi.top)
        }
        val mapped = result.toMutableMap()
        mapped["sourceWidth"] = width
        mapped["sourceHeight"] = height
        mapped["corners"] = (result["corners"] as? List<*>)?.mapNotNull(::shift) ?: emptyList<Map<String, Double>>()
        val boundary = result["boundary"] as? Map<*, *>
        if (boundary != null) {
            val next = boundary.toMutableMap()
            for (edge in listOf("top", "right", "bottom", "left")) {
                next[edge] = (boundary[edge] as? List<*>)?.mapNotNull(::shift) ?: emptyList<Map<String, Double>>()
            }
            next["sourceWidth"] = width
            next["sourceHeight"] = height
            mapped["boundary"] = next
        }
        return mapped
    }

    private data class PreviewRoi(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width get() = right - left
        val height get() = bottom - top
        fun clamped(width: Int, height: Int): PreviewRoi {
            val l = left.coerceIn(0, width - 1); val t = top.coerceIn(0, height - 1)
            return PreviewRoi(l, t, right.coerceIn(l + 1, width), bottom.coerceIn(t + 1, height))
        }
    }

    private fun occupancyScore(areaRatio: Double, pageSide: PageSide?): Double {
        val floor = if (pageSide == null) 0.14 else 0.24
        val preferred = if (pageSide == null) 0.72 else 0.68
        return ((areaRatio - floor) / (preferred - floor)).coerceIn(0.0, 1.0)
    }

    private fun smallCandidatePenalty(areaRatio: Double, pageSide: PageSide?): Double {
        val preferredMinimum = if (pageSide == null) 0.42 else 0.48
        return ((preferredMinimum - areaRatio) / preferredMinimum).coerceIn(0.0, 1.0)
    }

    private fun borderProximityScore(
        points: Array<Point>,
        imageSize: Size,
        pageSide: PageSide?,
    ): Double {
        val leftGap = points.minOf { it.x } / imageSize.width
        val rightGap = (imageSize.width - points.maxOf { it.x }) / imageSize.width
        val topGap = points.minOf { it.y } / imageSize.height
        val bottomGap = (imageSize.height - points.maxOf { it.y }) / imageSize.height
        fun proximity(gap: Double, tolerance: Double): Double =
            (1.0 - gap / tolerance).coerceIn(0.0, 1.0)
        val top = proximity(topGap, 0.30)
        val bottom = proximity(bottomGap, 0.30)
        if (pageSide == null) {
            return (
                proximity(leftGap, 0.30) +
                    proximity(rightGap, 0.30) +
                    top +
                    bottom
                ) / 4.0
        }
        val outer = if (pageSide == PageSide.left) {
            proximity(leftGap, 0.26)
        } else {
            proximity(rightGap, 0.26)
        }
        val spine = if (pageSide == PageSide.left) {
            proximity(rightGap, 0.40)
        } else {
            proximity(leftGap, 0.40)
        }
        return outer * 0.36 + top * 0.27 + bottom * 0.27 + spine * 0.10
    }

    private fun paperInteriorScore(signals: RegionSignals): Double {
        val brightness = (signals.meanBrightness / 210.0).coerceIn(0.0, 1.0)
        val foregroundStructure = (signals.textDensity / 0.55).coerceIn(0.0, 1.0)
        return (
            brightness * 0.30 +
                signals.brightPixelRatio * 0.32 +
                signals.brightnessConsistency * 0.20 +
                foregroundStructure * 0.18
            ).coerceIn(0.0, 1.0)
    }

    private fun internalLinePenalty(
        boundaryContrast: Double,
        borderProximity: Double,
        smallCandidatePenalty: Double,
        outsideContentContinuation: Double,
    ): Double {
        val paperOnBothSides = 1.0 - boundaryContrast
        val centered = 1.0 - borderProximity
        return (
            paperOnBothSides * centered * 0.42 +
                smallCandidatePenalty * 0.28 +
                outsideContentContinuation * 0.30
            ).coerceIn(0.0, 1.0)
    }

    private fun repeatedHorizontalBoundaryPenalty(
        points: Array<Point>,
        lines: List<LineSegment>,
    ): Double {
        val corners = orderCorners(points)
        val topY = (corners[0].y + corners[1].y) / 2.0
        val bottomY = (corners[2].y + corners[3].y) / 2.0
        val height = max(1.0, bottomY - topY)
        val width = max(1.0, points.maxOf { it.x } - points.minOf { it.x })
        val nearBoundary = lines.count { line ->
            val dx = abs(line.end.x - line.start.x)
            val dy = abs(line.end.y - line.start.y)
            val middleY = (line.start.y + line.end.y) / 2.0
            dx >= width * 0.18 && dy <= dx * 0.12 &&
                (abs(middleY - topY) <= height * 0.055 ||
                    abs(middleY - bottomY) <= height * 0.055)
        }
        return when {
            nearBoundary >= 5 -> 0.92
            nearBoundary >= 3 -> 0.74
            nearBoundary >= 2 -> 0.52
            else -> 0.0
        }
    }

    private fun candidateConfidence(
        occupancy: Double,
        borderProximity: Double,
        contrast: Double,
        paperScore: Double,
        rectangularity: Double,
        edgeContinuity: Double,
        internalLinePenalty: Double,
        smallCandidatePenalty: Double,
    ): Double = (
        occupancy * 0.23 +
            borderProximity * 0.15 +
            contrast * 0.17 +
            paperScore * 0.16 +
            rectangularity * 0.10 +
            edgeContinuity * 0.19 -
            internalLinePenalty * 0.24 -
            smallCandidatePenalty * 0.18
        ).coerceIn(0.0, 1.0)

    private fun selectConservativeCandidate(
        candidates: List<Candidate>,
        imageArea: Double,
    ): Candidate? {
        val highest = candidates.maxByOrNull { it.score } ?: return null
        val highestArea = polygonArea(highest.points) / imageArea
        val alternatives = candidates.filter { candidate ->
            val area = polygonArea(candidate.points) / imageArea
            val evidence = candidate.debugScores
            area >= highestArea * 1.16 &&
                candidate.score >= highest.score - 0.10 &&
                evidence.paperScore >= 0.50 &&
                evidence.insideOutsideContrast >= 0.16 &&
                evidence.internalLinePenalty < 0.62 &&
                evidence.outsideContinuationPenalty <=
                    highest.debugScores.outsideContinuationPenalty + 0.10
        }
        return alternatives.maxByOrNull { polygonArea(it.points) } ?: highest
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
        val luminanceDifferences = mutableListOf<Double>()
        val varianceDifferences = mutableListOf<Double>()
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
                val insideValues = mutableListOf<Double>()
                val outsideValues = mutableListOf<Double>()
                for (depth in listOf(0.65, 1.0, 1.35)) {
                    val insideX = (x + normalX * margin * depth).roundToInt()
                    val insideY = (y + normalY * margin * depth).roundToInt()
                    val outsideX = (x - normalX * margin * depth).roundToInt()
                    val outsideY = (y - normalY * margin * depth).roundToInt()
                    if (insideX !in 0 until gray.cols() ||
                        insideY !in 0 until gray.rows() ||
                        outsideX !in 0 until gray.cols() ||
                        outsideY !in 0 until gray.rows()
                    ) continue
                    gray.get(insideY, insideX)?.firstOrNull()?.let(insideValues::add)
                    gray.get(outsideY, outsideX)?.firstOrNull()?.let(outsideValues::add)
                }
                if (insideValues.size < 2 || outsideValues.size < 2) continue
                val insideMean = insideValues.average()
                val outsideMean = outsideValues.average()
                val insideVariance = insideValues.sumOf { (it - insideMean) * (it - insideMean) } /
                    insideValues.size
                val outsideVariance = outsideValues.sumOf { (it - outsideMean) * (it - outsideMean) } /
                    outsideValues.size
                luminanceDifferences.add(abs(insideMean - outsideMean) / 255.0)
                varianceDifferences.add(
                    (abs(sqrt(insideVariance) - sqrt(outsideVariance)) / 64.0)
                        .coerceIn(0.0, 1.0),
                )
            }
        }
        if (luminanceDifferences.isEmpty()) return 0.0
        val luminance = (luminanceDifferences.average() * 3.0).coerceIn(0.0, 1.0)
        val variance = if (varianceDifferences.isEmpty()) 0.0 else varianceDifferences.average()
        return (luminance * 0.78 + variance * 0.22).coerceIn(0.0, 1.0)
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
        val validation = boundaryValidationSignals(corners, contour, gray, edges, imageSize)
        val pageSide = if (spineSide == SpineSide.right) PageSide.left else PageSide.right
        val occupancy = occupancyScore(areaRatio, pageSide)
        val borderProximity = borderProximityScore(corners, imageSize, pageSide)
        val contrast = brightnessBoundaryScore(corners, gray)
        val paperScore = paperInteriorScore(signals)
        val rectangularity = rightAngleScore(corners)
        val smallPenalty = smallCandidatePenalty(areaRatio, pageSide)
        val linePenalty = internalLinePenalty(
            contrast,
            borderProximity,
            smallPenalty,
            validation.outsideContentContinuation,
        )
        val score = if (
            validation.selfIntersects ||
            validation.contentContainment < 0.72 ||
            validation.outsideContentContinuation >= 0.42 ||
            areaRatio < 0.24 ||
            linePenalty >= 0.82
        ) {
            -1.0
        } else {
            occupancy * 0.24 +
                borderProximity * 0.18 +
                contrast * 0.12 +
                paperScore * 0.14 +
                rectangularity * 0.08 +
                validation.outerBoundaryContinuity * 0.10 +
                spine.strength * 0.04 +
                curveDeviationScore(spineCurve, imageSize) * 0.03 +
                validation.contentContainment * 0.07 -
                linePenalty * 0.28 -
                smallPenalty * 0.22
        }
        val confidence = candidateConfidence(
            occupancy,
            borderProximity,
            contrast,
            paperScore,
            rectangularity,
            validation.outerBoundaryContinuity,
            linePenalty,
            smallPenalty,
        )
        return Candidate(
            corners,
            contour,
            score,
            confidence,
            CandidateKind.bookPage,
            spineSide,
            validation.clippingEvidence,
            CandidateDebugScores(
                occupancy = occupancy,
                borderProximity = borderProximity,
                insideOutsideContrast = contrast,
                paperScore = paperScore,
                rectangularity = rectangularity,
                edgeContinuity = validation.outerBoundaryContinuity,
                contentContainment = validation.contentContainment,
                internalLinePenalty = linePenalty,
                smallCandidatePenalty = smallPenalty,
                outsideContinuationPenalty = validation.outsideContentContinuation,
                widthRatio = (corners.maxOf { it.x } - corners.minOf { it.x }) / imageSize.width,
                heightRatio = (corners.maxOf { it.y } - corners.minOf { it.y }) / imageSize.height,
                areaRatio = areaRatio,
            ),
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
        if (total == 0) return RegionSignals(0.0, 0.0, 0.0, 0.0)
        val mean = brightness.average()
        val deviation = sqrt(brightness.sumOf { (it - mean) * (it - mean) } / brightness.size)
        val brightPixelRatio = brightness.count { it >= 150.0 }.toDouble() / brightness.size
        return RegionSignals(
            textDensity = (edgeSamples.toDouble() / total * 9.0).coerceIn(0.0, 1.0),
            brightnessConsistency = (1.0 - deviation / 90.0).coerceIn(0.0, 1.0),
            meanBrightness = mean,
            brightPixelRatio = brightPixelRatio,
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
            if (pageSide == PageSide.left) 1 else -1,
        )
        val spine = strongestVerticalAnchor(
            gray,
            edges,
            spineRange,
            0.05 to 0.95,
            spineTarget,
            if (pageSide == PageSide.left) -1 else 1,
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
            1,
        )
        val bottom = strongestHorizontalAnchor(
            gray,
            edges,
            0.73 to 0.99,
            ownedStart / width to ownedEnd / width,
            0.96,
            -1,
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
        val signals = regionSignals(corners, gray, edges)
        val occupancy = occupancyScore(areaRatio, pageSide)
        val borderProximity = borderProximityScore(corners, imageSize, pageSide)
        val contrast = brightnessBoundaryScore(corners, gray)
        val paperScore = paperInteriorScore(signals)
        val rectangularity = rightAngleScore(corners)
        val smallPenalty = smallCandidatePenalty(areaRatio, pageSide)
        val linePenalty = internalLinePenalty(
            contrast,
            borderProximity,
            smallPenalty,
            validation.outsideContentContinuation,
        )
        if (areaRatio < 0.24 || linePenalty >= 0.82) return null
        val anchorContinuity = (
            outer.support * 0.42 +
                top.support * 0.27 +
                bottom.support * 0.27 +
                spine.support * 0.04
            ).coerceIn(0.0, 1.0)
        val score =
            occupancy * 0.24 +
                borderProximity * 0.17 +
                contrast * 0.11 +
                paperScore * 0.13 +
                rectangularity * 0.06 +
                anchorContinuity * 0.14 +
                envelopeContainment * 0.08 +
                outer.support * 0.07 -
                linePenalty * 0.28 -
                smallPenalty * 0.22
        val baseConfidence = candidateConfidence(
            occupancy,
            borderProximity,
            contrast,
            paperScore,
            rectangularity,
            anchorContinuity,
            linePenalty,
            smallPenalty,
        )
        val outerEvidence = (outer.support / 0.16).coerceIn(0.0, 1.0)
        val confidence = max(
            baseConfidence,
            (baseConfidence * 0.78 + outerEvidence * 0.22).coerceIn(0.0, 1.0),
        )
        return Candidate(
            points = corners,
            contourPoints = corners,
            score = score,
            confidence = confidence,
            kind = CandidateKind.bookPage,
            spineSide = pageSide.spineSide,
            clippingEvidence = validation.clippingEvidence,
            debugScores = CandidateDebugScores(
                occupancy = occupancy,
                borderProximity = borderProximity,
                insideOutsideContrast = contrast,
                paperScore = paperScore,
                rectangularity = rectangularity,
                edgeContinuity = anchorContinuity,
                contentContainment = envelopeContainment,
                internalLinePenalty = linePenalty,
                smallCandidatePenalty = smallPenalty,
                outsideContinuationPenalty = validation.outsideContentContinuation,
                widthRatio = (ownedEnd - ownedStart) / width,
                heightRatio = (bottom.coordinate - top.coordinate) / height,
                areaRatio = areaRatio,
            ),
        )
    }

    private fun strongestVerticalAnchor(
        gray: Mat,
        edges: Mat,
        xRange: Pair<Double, Double>,
        yRange: Pair<Double, Double>,
        target: Double,
        insideDirection: Int,
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
            val contrast = verticalBoundaryContrast(
                gray,
                x,
                yStart,
                yEnd,
                insideDirection,
            )
            val positionPrior =
                (1.0 - abs(x.toDouble() / width - target) /
                    max(0.01, xRange.second - xRange.first)).coerceIn(0.0, 1.0)
            val selectionScore = support * 0.50 + contrast * 0.30 + positionPrior * 0.20
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
        insideDirection: Int,
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
            val contrast = horizontalBoundaryContrast(
                gray,
                y,
                xStart,
                xEnd,
                insideDirection,
            )
            val positionPrior =
                (1.0 - abs(y.toDouble() / height - target) /
                    max(0.01, yRange.second - yRange.first)).coerceIn(0.0, 1.0)
            val selectionScore = support * 0.50 + contrast * 0.30 + positionPrior * 0.20
            if (selectionScore > best.selectionScore) {
                best = BoundaryAnchor(y.toDouble(), support, selectionScore)
            }
        }
        return best
    }

    private fun verticalBoundaryContrast(
        gray: Mat,
        x: Int,
        yStart: Int,
        yEnd: Int,
        insideDirection: Int,
    ): Double {
        val offset = max(2, (gray.cols() * 0.012).roundToInt())
        val insideX = (x + insideDirection * offset).coerceIn(0, gray.cols() - 1)
        val outsideX = (x - insideDirection * offset).coerceIn(0, gray.cols() - 1)
        val step = max(1, (yEnd - yStart) / 96)
        val differences = mutableListOf<Double>()
        for (y in yStart until yEnd step step) {
            val inside = gray.get(y, insideX)?.firstOrNull() ?: continue
            val outside = gray.get(y, outsideX)?.firstOrNull() ?: continue
            differences.add(abs(inside - outside) / 255.0)
        }
        return if (differences.isEmpty()) 0.0 else
            (differences.average() * 3.2).coerceIn(0.0, 1.0)
    }

    private fun horizontalBoundaryContrast(
        gray: Mat,
        y: Int,
        xStart: Int,
        xEnd: Int,
        insideDirection: Int,
    ): Double {
        val offset = max(2, (gray.rows() * 0.012).roundToInt())
        val insideY = (y + insideDirection * offset).coerceIn(0, gray.rows() - 1)
        val outsideY = (y - insideDirection * offset).coerceIn(0, gray.rows() - 1)
        val step = max(1, (xEnd - xStart) / 120)
        val differences = mutableListOf<Double>()
        for (x in xStart until xEnd step step) {
            val inside = gray.get(insideY, x)?.firstOrNull() ?: continue
            val outside = gray.get(outsideY, x)?.firstOrNull() ?: continue
            differences.add(abs(inside - outside) / 255.0)
        }
        return if (differences.isEmpty()) 0.0 else
            (differences.average() * 3.2).coerceIn(0.0, 1.0)
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
        val confidence: Double,
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
        val meanBrightness: Double,
        val brightPixelRatio: Double,
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
        val occupancy: Double = 0.0,
        val borderProximity: Double = 0.0,
        val insideOutsideContrast: Double = 0.0,
        val paperScore: Double = 0.0,
        val rectangularity: Double = 0.0,
        val edgeContinuity: Double = 0.0,
        val contentContainment: Double = 1.0,
        val internalLinePenalty: Double = 0.0,
        val smallCandidatePenalty: Double = 0.0,
        val outsideContinuationPenalty: Double = 0.0,
        val widthRatio: Double = 0.0,
        val heightRatio: Double = 0.0,
        val areaRatio: Double = 0.0,
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

    private fun logCandidates(
        candidates: List<Candidate>,
        pageSide: PageSide?,
        debugLogging: Boolean,
        selected: Candidate?,
    ) {
        if (!debugLogging) return
        Log.d(
            "ScanaDetector",
            "mode=${if (pageSide == null) "single" else "spread"} " +
                "roi=${pageSide?.value ?: "full"} candidate_count=${candidates.size} " +
                "selected_candidate_index=${selected?.let { candidates.indexOf(it) } ?: -1} " +
                "selected_by=${if (selected == null) "fallback" else "highRes"} " +
                "fallback_used=${selected == null} " +
                "fallback_reason=${if (selected == null) "no_reliable_candidate" else "none"}",
        )
        candidates.sortedByDescending { it.score }.take(3).forEachIndexed { index, candidate ->
            val scores = candidate.debugScores
            Log.d(
                "ScanaDetector",
                "rank=${index + 1} occupancy=${scores.occupancy} " +
                    "border_proximity=${scores.borderProximity} " +
                    "inside_outside_contrast=${scores.insideOutsideContrast} " +
                    "paper_score=${scores.paperScore} " +
                    "rectangularity=${scores.rectangularity} " +
                    "edge_continuity=${scores.edgeContinuity} " +
                    "content_containment=${scores.contentContainment} " +
                    "internal_line_penalty=${scores.internalLinePenalty} " +
                    "small_candidate_penalty=${scores.smallCandidatePenalty} " +
                    "outside_continuation_penalty=${scores.outsideContinuationPenalty} " +
                    "area_ratio=${scores.areaRatio} width_ratio=${scores.widthRatio} " +
                    "height_ratio=${scores.heightRatio} " +
                    "final_score=${candidate.score} confidence=${candidate.confidence}",
            )
        }
        selected?.let { candidate ->
            val corners = orderCorners(candidate.points)
            Log.d(
                "ScanaDetector",
                "selected_corners topLeft=${pointMap(corners[0])} " +
                    "topRight=${pointMap(corners[1])} " +
                    "bottomRight=${pointMap(corners[2])} bottomLeft=${pointMap(corners[3])}",
            )
        }
    }
}
