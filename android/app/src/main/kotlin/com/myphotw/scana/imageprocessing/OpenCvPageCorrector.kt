package com.myphotw.scana.imageprocessing

import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfDouble
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc

/** Perspective correction and conservative geometry-based curved-page flattening. */
object OpenCvPageCorrector {
    private const val MAX_OUTPUT_PIXELS = 32_000_000.0
    private const val CURVE_ANALYSIS_MAX_DIMENSION = 1200.0
    private const val REMAP_STRIP_HEIGHT = 192
    private const val MINIMUM_CURVE_SIGNALS = 2
    private const val MAXIMUM_CURVE_CANDIDATES = 24
    private const val CONTOUR_ENDPOINT_TRIM_FRACTION = 0.10
    private const val CONTOUR_ONLY_MILD_MAX_DEFORMATION_FRACTION = 0.006

    private val openCvReady: Boolean by lazy { OpenCVLoader.initLocal() }

    fun correct(
        sourceImagePath: String,
        outputImagePath: String,
        cornerValues: List<Map<String, Number>>,
        correctionType: String,
        pageBoundaryMode: String,
        curvePolicyValues: Map<String, Number>,
        pageBoundary: Map<String, Any>?,
        qualityDiagnosticsEnabled: Boolean,
    ): Map<String, Any> {
        check(openCvReady) { "OpenCV initialization failed." }
        val source = Imgcodecs.imread(sourceImagePath, Imgcodecs.IMREAD_COLOR)
        if (source.empty()) {
            source.release()
            throw IllegalArgumentException("The source image could not be decoded.")
        }

        var output: Mat? = null
        var curveDiagnostics: MutableMap<String, Any>? = null
        try {
            output = when (correctionType) {
                "perspective" -> {
                    val corners = parseAndValidateCorners(cornerValues, source.size())
                    applyPerspective(source, corners)
                }
                "curved" -> {
                    val flattened = flattenCurvedPage(
                        source,
                        pageBoundaryMode,
                        CurvePolicy.from(curvePolicyValues),
                        cornerValues,
                        pageBoundary,
                        outputImagePath,
                        qualityDiagnosticsEnabled,
                    )
                    curveDiagnostics = flattened.diagnostics
                    flattened.image
                }
                else -> throw IllegalArgumentException("Unknown correction type.")
            }
            if (correctionType == "curved") {
                validateCurvedOutput(source, output, curveDiagnostics.orEmpty())
                val beforeQuality = horizontalStraightness(source)
                val afterQuality = horizontalStraightness(output)
                curveDiagnostics?.put("perspectiveStraightness", beforeQuality)
                curveDiagnostics?.put("curvedStraightness", afterQuality)
                val state = curveDiagnostics?.get("curvatureState") as? String
                val strength = (curveDiagnostics?.get("deformationStrength") as? Number)
                    ?.toDouble() ?: 1.0
                val geometryBefore = (
                    curveDiagnostics?.get("profileDeformationMagnitude") as? Number
                    )?.toDouble() ?: 0.0
                val effectiveDeformation = (
                    curveDiagnostics?.get("effectiveDeformationMagnitude") as? Number
                    )?.toDouble() ?: geometryBefore * strength
                val geometryAfter = max(0.0, geometryBefore - effectiveDeformation)
                curveDiagnostics?.put("geometryBefore", geometryBefore)
                curveDiagnostics?.put("geometryAfter", geometryAfter)
                val straightnessRatio = if (state == "mildCurve") 1.0005 else 1.005
                val straightnessImproved = beforeQuality > 0.0 &&
                    afterQuality >= beforeQuality * straightnessRatio
                val geometryImproved = state == "mildCurve" &&
                    geometryBefore >= CurvePolicy.from(curvePolicyValues)
                        .minimumDeformationFraction &&
                    geometryAfter <= geometryBefore * 0.995
                if (!straightnessImproved && !geometryImproved) {
                    throw CurvedCorrectionException(
                        "curve_not_improved",
                        "Curved output did not improve page geometry.",
                        curveDiagnostics.orEmpty() +
                            mapOf(
                                "rejectionReason" to "no_geometry_or_straightness_improvement",
                                "requiredStraightnessRatio" to straightnessRatio,
                            ),
                    )
                }
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
            check(written) { "The corrected image could not be written." }
            return mutableMapOf<String, Any>(
                "outputWidth" to output.cols(),
                "outputHeight" to output.rows(),
                "outcome" to "completed",
                "outputFormat" to File(outputImagePath).extension.lowercase(),
            ).apply {
                putAll(sourceQuality)
                putAll(outputQuality)
                curveDiagnostics?.let { put("curveDiagnostics", it) }
            }
        } finally {
            output?.release()
            source.release()
        }
    }

    /** Rejects corrupt/empty canvases before they can replace perspective. */
    private fun validateCurvedOutput(
        perspective: Mat,
        curved: Mat,
        diagnostics: Map<String, Any>,
    ) {
        if (curved.empty() || curved.cols() <= 1 || curved.rows() <= 1) {
            throw CurvedCorrectionException(
                "curve_unsafe",
                "Curved correction produced an empty image.",
                diagnostics + mapOf("rejectionReason" to "output_empty"),
            )
        }
        val widthChange = abs(curved.cols() - perspective.cols()).toDouble() /
            perspective.cols().coerceAtLeast(1)
        val heightChange = abs(curved.rows() - perspective.rows()).toDouble() /
            perspective.rows().coerceAtLeast(1)
        val perspectiveAspect = perspective.cols().toDouble() / perspective.rows()
        val curvedAspect = curved.cols().toDouble() / curved.rows()
        val aspectChange = abs(curvedAspect - perspectiveAspect) / perspectiveAspect
        if (widthChange > 0.02 || heightChange > 0.02 || aspectChange > 0.02) {
            throw CurvedCorrectionException(
                "curve_unsafe",
                "Curved correction changed the perspective canvas.",
                diagnostics +
                    mapOf(
                        "rejectionReason" to "canvas_changed",
                        "widthChange" to widthChange,
                        "heightChange" to heightChange,
                        "aspectChange" to aspectChange,
                    ),
            )
        }

        val gray = Mat()
        val mean = MatOfDouble()
        val deviation = MatOfDouble()
        try {
            Imgproc.cvtColor(curved, gray, Imgproc.COLOR_BGR2GRAY)
            Core.meanStdDev(gray, mean, deviation)
            val meanValue = mean.toArray().firstOrNull() ?: 0.0
            val deviationValue = deviation.toArray().firstOrNull() ?: 0.0
            if (!meanValue.isFinite() || !deviationValue.isFinite() ||
                meanValue < 8.0 || (meanValue < 25.0 && deviationValue < 0.5)
            ) {
                throw CurvedCorrectionException(
                    "curve_unsafe",
                    "Curved correction produced an invalid image.",
                    diagnostics +
                        mapOf(
                            "rejectionReason" to "output_invalid",
                            "outputMean" to meanValue,
                            "outputDeviation" to deviationValue,
                        ),
                )
            }
        } finally {
            deviation.release()
            mean.release()
            gray.release()
        }
    }

    private fun applyPerspective(source: Mat, corners: Array<Point>): Mat {
        val topWidth = distance(corners[0], corners[1])
        val bottomWidth = distance(corners[3], corners[2])
        val leftHeight = distance(corners[0], corners[3])
        val rightHeight = distance(corners[1], corners[2])
        var outputWidth = max(topWidth, bottomWidth).roundToInt().coerceAtLeast(1)
        var outputHeight = max(leftHeight, rightHeight).roundToInt().coerceAtLeast(1)
        val outputPixels = outputWidth.toDouble() * outputHeight.toDouble()
        if (outputPixels > MAX_OUTPUT_PIXELS) {
            val scale = sqrt(MAX_OUTPUT_PIXELS / outputPixels)
            outputWidth = (outputWidth * scale).roundToInt().coerceAtLeast(1)
            outputHeight = (outputHeight * scale).roundToInt().coerceAtLeast(1)
        }

        val sourcePoints = MatOfPoint2f(*corners)
        val destinationPoints =
            MatOfPoint2f(
                Point(0.0, 0.0),
                Point((outputWidth - 1).toDouble(), 0.0),
                Point((outputWidth - 1).toDouble(), (outputHeight - 1).toDouble()),
                Point(0.0, (outputHeight - 1).toDouble()),
            )
        val transform = Imgproc.getPerspectiveTransform(sourcePoints, destinationPoints)
        val corrected = Mat()
        try {
            Imgproc.warpPerspective(
                source,
                corrected,
                transform,
                Size(outputWidth.toDouble(), outputHeight.toDouble()),
                // Linear interpolation avoids the wider cubic kernel that can
                // soften small glyphs during a full-resolution document warp.
                Imgproc.INTER_LINEAR,
                Core.BORDER_REPLICATE,
                Scalar.all(255.0),
            )
            return corrected
        } finally {
            transform.release()
            destinationPoints.release()
            sourcePoints.release()
        }
    }

    private fun flattenCurvedPage(
        perspective: Mat,
        pageBoundaryMode: String,
        policy: CurvePolicy,
        cornerValues: List<Map<String, Number>>,
        pageBoundary: Map<String, Any>?,
        debugOutputPath: String,
        debugArtifactsEnabled: Boolean,
    ): CurvedFlattenResult {
        val detectionStartedAt = System.nanoTime()
        check(perspective.rows() > 1 && perspective.cols() > 2) {
            "The perspective image is too small for curved correction."
        }
        val scale = min(
            1.0,
            CURVE_ANALYSIS_MAX_DIMENSION / max(perspective.cols(), perspective.rows()).toDouble(),
        )
        val analysis = Mat()
        val gray = Mat()
        val binary = Mat()
        val horizontal = Mat()
        try {
            if (scale < 1.0) {
                Imgproc.resize(perspective, analysis, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                perspective.copyTo(analysis)
            }
            Imgproc.cvtColor(analysis, gray, Imgproc.COLOR_BGR2GRAY)
            Imgproc.adaptiveThreshold(
                gray,
                binary,
                255.0,
                Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
                Imgproc.THRESH_BINARY_INV,
                31,
                15.0,
            )
            val region = pageRegion(analysis.size(), pageBoundaryMode, policy.insetFraction)
            val kernelWidth = max(11, (region.width * 0.025).roundToInt())
            val kernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_RECT,
                Size(kernelWidth.toDouble(), 1.0),
            )
            try {
                Imgproc.morphologyEx(binary, horizontal, Imgproc.MORPH_OPEN, kernel)
            } finally {
                kernel.release()
            }

            val pixelGeometry = if (pageBoundaryMode == "detected") {
                collectBoundaryCurves(gray, region, policy)
            } else {
                PageGeometryCurves()
            }
            val metadataGeometry = collectMetadataBoundaryCurves(
                pageBoundary,
                cornerValues,
                analysis.cols(),
                analysis.rows(),
            )
            val spineSignal = collectSpineBoundarySignal(pageBoundary, cornerValues)
            val internalSignals = collectTextCurves(horizontal, region, policy)
            val textCurves = internalSignals.map { it.raw }
            val normalizedTextCurves = internalSignals.map { it.normalized }
            val geometry = metadataGeometry.withFallback(pixelGeometry)
            val topCurve = geometry.top
            val bottomCurve = geometry.bottom
            val pageCurves = listOfNotNull(topCurve, bottomCurve)
            val fusion = curvatureEvidenceFusion(
                geometry = geometry,
                spineSignal = spineSignal,
                internalCurves = normalizedTextCurves,
                internalRawCurves = textCurves,
                imageHeight = analysis.rows(),
                flatMagnitudeLimit = policy.minimumDeformationFraction,
            )
            if (debugArtifactsEnabled) {
                writeCurvatureDebugOverlays(
                    perspective = perspective,
                    analysis = analysis,
                    horizontal = horizontal,
                    topCurve = topCurve,
                    bottomCurve = bottomCurve,
                    spineSide = pageBoundary?.get("spineSide") as? String,
                    outputPath = debugOutputPath,
                )
            }
            val internalProfileCoverage = candidateCoverage(textCurves, region)
            val internalProfileAvailable = textCurves.isNotEmpty() &&
                internalProfileCoverage >= policy.minimumEvidenceCoverage &&
                fusion.internalSignalCount > 0
            val signals = if (internalProfileAvailable) {
                textCurves.take(8)
            } else {
                pageCurves
            }
            val evidenceCount = pageCurves.size +
                (if (spineSignal != null) 1 else 0) +
                min(2, textCurves.size)
            if (evidenceCount < MINIMUM_CURVE_SIGNALS || signals.isEmpty()) {
                throw CurvedCorrectionException(
                    "curve_insufficient_evidence",
                    "Stable page curvature was not found.",
                    mapOf(
                        "rejectionReason" to "insufficient_evidence",
                        "pageCurveCount" to pageCurves.size,
                        "horizontalLineCount" to textCurves.size,
                        "spineSignalCount" to if (spineSignal == null) 0 else 1,
                        "evidenceCount" to evidenceCount,
                        "minimumEvidenceCount" to MINIMUM_CURVE_SIGNALS,
                        "minimumConfidence" to policy.minimumConfidence,
                        "curvatureState" to "unreliable",
                        "detectMs" to elapsedMilliseconds(detectionStartedAt),
                    ) + fusion.diagnostics(),
                )
            }
            val estimate = aggregateCurves(
                signals,
                region,
                analysis.rows(),
                policy,
                !internalProfileAvailable && pageCurves.size >= 2,
                evidenceCount,
                fusion.diagnostics(),
            )
            if (!internalProfileAvailable) {
                clampContourOnlyProfile(estimate.offsets, region, analysis.rows())
            }
            if (spineSignal != null) {
                applySpineWeight(estimate.offsets, spineSignal)
            }
            val profileDeformationMagnitude =
                (estimate.offsets.maxOfOrNull { abs(it) } ?: 0.0) / max(1, analysis.rows())
            val curvatureState = classifyCurvature(estimate, fusion, analysis.rows(), policy)
            val deformationStrength = when (curvatureState) {
                "flat" -> throw CurvedCorrectionException(
                    "curve_nearly_flat",
                    "The page is already nearly flat.",
                    estimate.diagnostics(policy, analysis.rows()) + fusion.diagnostics() +
                        mapOf(
                            "curvatureState" to curvatureState,
                            "curvatureMagnitude" to profileDeformationMagnitude,
                            "combinedMagnitude" to profileDeformationMagnitude,
                            "profileDeformationMagnitude" to profileDeformationMagnitude,
                            "effectiveDeformationMagnitude" to 0.0,
                            "deformationStrength" to 0.0,
                            "rejectReason" to "curvature_too_small",
                            "rejectionReason" to "curvature_too_small",
                            "detectMs" to elapsedMilliseconds(detectionStartedAt),
                        ),
                )
                "mildCurve" -> policy.mildDewarpStrength
                "strongCurve" -> 1.0
                else -> {
                    val rejectionReason = when {
                        fusion.conflicting -> "evidence_direction_conflict"
                        estimate.consistency < policy.minimumEvidenceConsistency ->
                            "curve_consistency_too_low"
                        fusion.pageContourMagnitude >= policy.minimumDeformationFraction ->
                            "geometry_mild_support_incomplete"
                        estimate.confidence < policy.mildMinimumConfidence ->
                            "confidence_below_mild_threshold"
                        else -> "evidence_unreliable"
                    }
                    throw CurvedCorrectionException(
                        "curve_low_confidence",
                        "Curve evidence is unreliable.",
                        estimate.diagnostics(policy, analysis.rows()) + fusion.diagnostics() +
                            mapOf(
                                "curvatureState" to "unreliable",
                                "curvatureMagnitude" to profileDeformationMagnitude,
                                "combinedMagnitude" to profileDeformationMagnitude,
                                "profileDeformationMagnitude" to profileDeformationMagnitude,
                                "effectiveDeformationMagnitude" to 0.0,
                                "deformationStrength" to 0.0,
                                "rejectReason" to rejectionReason,
                                "rejectionReason" to rejectionReason,
                                "detectMs" to elapsedMilliseconds(detectionStartedAt),
                            ),
                    )
                }
            }
            if (deformationStrength < 1.0) {
                for (index in estimate.offsets.indices) {
                    estimate.offsets[index] *= deformationStrength
                }
            }
            val effectiveDeformationMagnitude =
                (estimate.offsets.maxOfOrNull { abs(it) } ?: 0.0) / max(1, analysis.rows())
            validateCurveOrThrow(
                estimate,
                analysis.rows(),
                policy,
                requireStrongConfidence = curvatureState == "strongCurve",
                requireMinimumDeformation = curvatureState == "strongCurve",
                additionalDiagnostics = fusion.diagnostics() +
                    mapOf(
                        "curvatureState" to curvatureState,
                        "internalDeformationMagnitude" to fusion.internalMagnitude,
                        "profileDeformationMagnitude" to profileDeformationMagnitude,
                        "effectiveDeformationMagnitude" to effectiveDeformationMagnitude,
                        "profileSource" to
                            if (internalProfileAvailable) "internal" else "contour_clamped",
                        "deformationStrength" to deformationStrength,
                    ),
            )
            val detectionMilliseconds = elapsedMilliseconds(detectionStartedAt)
            val dewarpStartedAt = System.nanoTime()
            val image = remapInStrips(perspective, estimate.offsets, analysis.rows())
            val dewarpMilliseconds = elapsedMilliseconds(dewarpStartedAt)
            return CurvedFlattenResult(
                image,
                (estimate.diagnostics(policy, analysis.rows()) + fusion.diagnostics() +
                    mapOf(
                        "curvatureState" to curvatureState,
                        "curvatureMagnitude" to profileDeformationMagnitude,
                        "combinedMagnitude" to profileDeformationMagnitude,
                        "internalDeformationMagnitude" to fusion.internalMagnitude,
                        "profileDeformationMagnitude" to profileDeformationMagnitude,
                        "effectiveDeformationMagnitude" to effectiveDeformationMagnitude,
                        "profileSource" to if (internalProfileAvailable) "internal" else "contour_clamped",
                        "internalProfileCoverage" to internalProfileCoverage,
                        "deformationStrength" to deformationStrength,
                        "detectMs" to detectionMilliseconds,
                        "dewarpMs" to dewarpMilliseconds,
                    )).toMutableMap(),
            )
        } finally {
            horizontal.release()
            binary.release()
            gray.release()
            analysis.release()
        }
    }

    private fun pageRegion(size: Size, boundaryMode: String, insetFraction: Double): Rect {
        if (boundaryMode == "detected") {
            return Rect(0, 0, size.width.roundToInt(), size.height.roundToInt())
        }
        require(boundaryMode == "insetFallback") { "Unknown page boundary mode." }
        val insetX = (size.width * insetFraction).roundToInt()
        val insetY = (size.height * insetFraction).roundToInt()
        return Rect(
            insetX,
            insetY,
            max(1, size.width.roundToInt() - insetX * 2),
            max(1, size.height.roundToInt() - insetY * 2),
        )
    }

    private fun writeCurvatureDebugOverlays(
        perspective: Mat,
        analysis: Mat,
        horizontal: Mat,
        topCurve: DoubleArray?,
        bottomCurve: DoubleArray?,
        spineSide: String?,
        outputPath: String,
    ) {
        try {
            val parent = File(outputPath).parentFile ?: return
            val stem = File(outputPath).nameWithoutExtension
                .trimStart('.')
                .replace(Regex("[^A-Za-z0-9_.-]"), "_")
            val directory = File(parent, "debug_curvature/$stem")
            if (!directory.exists() && !directory.mkdirs()) return
            OpenCvImageQuality.write(File(directory, "perspective.png").path, perspective)

            val contourOverlay = perspective.clone()
            try {
                val xScale = perspective.cols().toDouble() / max(1, analysis.cols())
                val yScale = perspective.rows().toDouble() / max(1, analysis.rows())
                fun drawCurve(curve: DoubleArray?, baseline: Double, color: Scalar) {
                    if (curve == null) return
                    var previous: Point? = null
                    curve.forEachIndexed { x, offset ->
                        if (!offset.isFinite()) return@forEachIndexed
                        val current = Point(x * xScale, baseline + offset * yScale)
                        previous?.let { Imgproc.line(contourOverlay, it, current, color, 3) }
                        if (x % max(1, curve.size / 16) == 0) {
                            Imgproc.circle(contourOverlay, current, 5, color, Imgproc.FILLED)
                        }
                        previous = current
                    }
                }
                val topBaseline = perspective.rows() * 0.04
                val bottomBaseline = perspective.rows() * 0.96
                Imgproc.line(
                    contourOverlay,
                    Point(0.0, topBaseline),
                    Point((perspective.cols() - 1).toDouble(), topBaseline),
                    Scalar(255.0, 255.0, 255.0),
                    1,
                )
                Imgproc.line(
                    contourOverlay,
                    Point(0.0, bottomBaseline),
                    Point((perspective.cols() - 1).toDouble(), bottomBaseline),
                    Scalar(255.0, 255.0, 255.0),
                    1,
                )
                drawCurve(topCurve, topBaseline, Scalar(0.0, 255.0, 0.0))
                drawCurve(bottomCurve, bottomBaseline, Scalar(0.0, 180.0, 255.0))
                if (spineSide == "left" || spineSide == "right") {
                    val x = if (spineSide == "left") {
                        perspective.cols() * 0.02
                    } else {
                        perspective.cols() * 0.98
                    }
                    Imgproc.line(
                        contourOverlay,
                        Point(x, 0.0),
                        Point(x, (perspective.rows() - 1).toDouble()),
                        Scalar(255.0, 0.0, 255.0),
                        3,
                    )
                }
                OpenCvImageQuality.write(
                    File(directory, "contour_overlay.png").path,
                    contourOverlay,
                )
            } finally {
                contourOverlay.release()
            }

            val internalOverlay = Mat()
            try {
                Imgproc.cvtColor(horizontal, internalOverlay, Imgproc.COLOR_GRAY2BGR)
                OpenCvImageQuality.write(
                    File(directory, "internal_lines_overlay.png").path,
                    internalOverlay,
                )
            } finally {
                internalOverlay.release()
            }
        } catch (_: Throwable) {
            // DEBUG artifacts must never affect production correction.
        }
    }

    private fun collectBoundaryCurves(
        gray: Mat,
        region: Rect,
        policy: CurvePolicy,
    ): PageGeometryCurves {
        val edges = Mat()
        val longEdges = Mat()
        try {
            Imgproc.Canny(gray, edges, 60.0, 160.0)
            val kernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_RECT,
                Size(max(15, region.width / 12).toDouble(), 1.0),
            )
            try {
                Imgproc.morphologyEx(edges, longEdges, Imgproc.MORPH_OPEN, kernel)
            } finally {
                kernel.release()
            }
            val pixels = ByteArray(longEdges.cols() * longEdges.rows())
            longEdges.get(0, 0, pixels)
            val bandHeight = max(2, (region.height * 0.18).roundToInt())
            val top = DoubleArray(longEdges.cols()) { Double.NaN }
            val bottom = DoubleArray(longEdges.cols()) { Double.NaN }
            for (x in region.x until region.x + region.width) {
                for (y in region.y until min(region.y + bandHeight, longEdges.rows())) {
                    if (unsigned(pixels[y * longEdges.cols() + x]) != 0) {
                        top[x] = y.toDouble()
                        break
                    }
                }
                for (
                    y in min(region.y + region.height - 1, longEdges.rows() - 1)
                        downTo max(region.y, region.y + region.height - bandHeight)
                ) {
                    if (unsigned(pixels[y * longEdges.cols() + x]) != 0) {
                        bottom[x] = y.toDouble()
                        break
                    }
                }
            }
            val topRaw = normalizeCandidate(
                top,
                region.x,
                region.x + region.width,
                gray.rows(),
                policy,
            )
            val bottomRaw = normalizeCandidate(
                bottom,
                region.x,
                region.x + region.width,
                gray.rows(),
                policy,
            )
            return PageGeometryCurves(
                top = topRaw,
                bottom = bottomRaw,
                topRaw = topRaw,
                bottomRaw = bottomRaw,
            )
        } finally {
            longEdges.release()
            edges.release()
        }
    }

    private fun collectTextCurves(
        horizontal: Mat,
        region: Rect,
        policy: CurvePolicy,
    ): List<InternalCurveSignal> {
        val contourInput = horizontal.clone()
        val hierarchy = Mat()
        val contours = mutableListOf<MatOfPoint>()
        try {
            Imgproc.findContours(
                contourInput,
                contours,
                hierarchy,
                Imgproc.RETR_LIST,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val eligible = contours
                .map { contour -> contour to Imgproc.boundingRect(contour) }
                .filter { (_, rect) ->
                    rect.width >= region.width * 0.18 &&
                        rect.height <= max(4.0, region.height * 0.08) &&
                        rect.x < region.x + region.width &&
                        rect.x + rect.width > region.x &&
                        rect.y >= region.y &&
                        rect.y + rect.height <= region.y + region.height
                }
                .sortedByDescending { (_, rect) -> rect.width }
                .take(MAXIMUM_CURVE_CANDIDATES)
            val pixels = ByteArray(horizontal.cols() * horizontal.rows())
            horizontal.get(0, 0, pixels)
            return eligible.mapNotNull { (_, rect) ->
                val startX = max(region.x, rect.x)
                val endX = min(region.x + region.width, rect.x + rect.width)
                val samples = DoubleArray(horizontal.cols()) { Double.NaN }
                for (x in startX until endX) {
                    val yValues = mutableListOf<Double>()
                    for (y in rect.y until rect.y + rect.height) {
                        if (unsigned(pixels[y * horizontal.cols() + x]) != 0) {
                            yValues.add(y.toDouble())
                        }
                    }
                    if (yValues.isNotEmpty()) samples[x] = median(yValues)
                }
                val raw = normalizeCandidate(
                    samples,
                    startX,
                    endX,
                    horizontal.rows(),
                    policy,
                ) ?: return@mapNotNull null
                InternalCurveSignal(raw = raw, normalized = raw.copyOf())
            }
        } finally {
            contours.forEach { it.release() }
            hierarchy.release()
            contourInput.release()
        }
    }

    private fun collectMetadataBoundaryCurves(
        boundary: Map<String, Any>?,
        cornerValues: List<Map<String, Number>>,
        targetWidth: Int,
        targetHeight: Int,
    ): PageGeometryCurves {
        if (boundary == null || cornerValues.size != 4 || targetWidth < 3 || targetHeight < 3) {
            return PageGeometryCurves()
        }
        val sourceHeight = (boundary["sourceHeight"] as? Number)?.toDouble()
            ?: return PageGeometryCurves()
        if (sourceHeight <= 0.0) return PageGeometryCurves()
        val corners = cornerValues.mapNotNull { value ->
            val x = value["x"]?.toDouble()
            val y = value["y"]?.toDouble()
            if (x == null || y == null || !x.isFinite() || !y.isFinite()) null else Point(x, y)
        }
        if (corners.size != 4) return PageGeometryCurves()

        fun points(key: String): List<Point> {
            val values = boundary[key] as? List<*> ?: return emptyList()
            return values.mapNotNull { item ->
                val map = item as? Map<*, *> ?: return@mapNotNull null
                val x = (map["x"] as? Number)?.toDouble()
                val y = (map["y"] as? Number)?.toDouble()
                if (x == null || y == null || !x.isFinite() || !y.isFinite()) {
                    null
                } else {
                    Point(x, y)
                }
            }
        }

        val topRaw = metadataCurve(
            points("top"),
            corners[0],
            corners[1],
            sourceHeight,
            targetWidth,
            targetHeight,
        )
        val bottomRaw = metadataCurve(
            points("bottom"),
            corners[3],
            corners[2],
            sourceHeight,
            targetWidth,
            targetHeight,
        )
        return PageGeometryCurves(
            top = topRaw,
            bottom = bottomRaw,
            topRaw = topRaw,
            bottomRaw = bottomRaw,
        )
    }

    private fun collectSpineBoundarySignal(
        boundary: Map<String, Any>?,
        cornerValues: List<Map<String, Number>>,
    ): SpineBoundarySignal? {
        val side = boundary?.get("spineSide") as? String ?: return null
        if (side != "left" && side != "right") return null
        if (cornerValues.size != 4) return null
        val points = (boundary[side] as? List<*>)?.mapNotNull { item ->
            val map = item as? Map<*, *> ?: return@mapNotNull null
            val x = (map["x"] as? Number)?.toDouble()
            val y = (map["y"] as? Number)?.toDouble()
            if (x == null || y == null) null else Point(x, y)
        } ?: return null
        if (points.size < 4) return null
        fun corner(index: Int): Point? {
            val value = cornerValues[index]
            val x = value["x"]?.toDouble()
            val y = value["y"]?.toDouble()
            return if (x == null || y == null) null else Point(x, y)
        }
        val start = if (side == "left") corner(3) else corner(1)
        val end = if (side == "left") corner(0) else corner(2)
        if (start == null || end == null) return null
        val chordLength = distance(start, end)
        if (chordLength <= 1.0) return null
        val rawSignedDistances = points.mapNotNull { point ->
            val projection = chordProjection(point, start, end)
            if (projection.t !in CONTOUR_ENDPOINT_TRIM_FRACTION..
                (1.0 - CONTOUR_ENDPOINT_TRIM_FRACTION)
            ) {
                null
            } else {
                projection.signedDistance
            }
        }
        if (rawSignedDistances.size < 3) return null
        val curvature = robustMagnitude(rawSignedDistances) / chordLength
        if (!curvature.isFinite() || curvature < 0.0005) return null
        return SpineBoundarySignal(
            side = side,
            curvature = curvature,
            strength = max(0.45, (curvature * 30.0).coerceIn(0.0, 1.0)),
            rawSign = directionOf(rawSignedDistances),
            normalizedSign = directionOf(rawSignedDistances),
        )
    }

    private fun applySpineWeight(offsets: DoubleArray, signal: SpineBoundarySignal) {
        for (x in offsets.indices) {
            val normalizedX = x.toDouble() / max(1, offsets.lastIndex)
            val proximity = if (signal.side == "left") 1.0 - normalizedX else normalizedX
            val weight = 0.82 + 0.18 * proximity * signal.strength
            offsets[x] *= weight
        }
    }

    private fun chordProjection(point: Point, start: Point, end: Point): ChordProjection {
        val dx = end.x - start.x
        val dy = end.y - start.y
        val lengthSquared = dx * dx + dy * dy
        val ratio = if (lengthSquared <= 0.0) 0.0 else
            (((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
                .coerceIn(0.0, 1.0)
        val x = start.x + dx * ratio
        val y = start.y + dy * ratio
        val length = sqrt(lengthSquared)
        val signedDistance = if (length <= 0.0) {
            0.0
        } else {
            (point.x - x) * (-dy / length) + (point.y - y) * (dx / length)
        }
        return ChordProjection(ratio, signedDistance)
    }

    private fun negatedCurve(curve: DoubleArray): DoubleArray =
        DoubleArray(curve.size) { index ->
            if (curve[index].isFinite()) -curve[index] else Double.NaN
        }

    private fun robustMagnitude(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        val sorted = values.filter { it.isFinite() }.map { abs(it) }.sorted()
        if (sorted.isEmpty()) return 0.0
        val index = ((sorted.size - 1) * 0.90).roundToInt().coerceIn(0, sorted.lastIndex)
        return sorted[index]
    }

    private fun directionOf(values: List<Double>): Int {
        val finite = values.filter { it.isFinite() }
        if (finite.size < 3) return 0
        val center = median(finite)
        return when {
            center > 0.000001 -> 1
            center < -0.000001 -> -1
            else -> 0
        }
    }

    private fun metadataCurve(
        points: List<Point>,
        start: Point,
        end: Point,
        sourceHeight: Double,
        targetWidth: Int,
        targetHeight: Int,
    ): DoubleArray? {
        if (points.size < 4) return null
        val dx = end.x - start.x
        val dy = end.y - start.y
        val length = sqrt(dx * dx + dy * dy)
        if (length <= 1.0) return null
        val sums = DoubleArray(targetWidth)
        val counts = IntArray(targetWidth)
        points.forEach { point ->
            val ratio = (
                ((point.x - start.x) * dx + (point.y - start.y) * dy) /
                    (length * length)
                ).coerceIn(0.0, 1.0)
            val chordX = start.x + dx * ratio
            val chordY = start.y + dy * ratio
            val normalX = -dy / length
            val normalY = dx / length
            val signedDistance =
                (point.x - chordX) * normalX + (point.y - chordY) * normalY
            val index = (ratio * (targetWidth - 1)).roundToInt()
            sums[index] += signedDistance / sourceHeight * targetHeight
            counts[index]++
        }
        val offsets = DoubleArray(targetWidth) { index ->
            if (counts[index] == 0) Double.NaN else sums[index] / counts[index]
        }
        if (counts.count { it > 0 } < 4) return null
        interpolateMissing(offsets, 0, targetWidth)
        return offsets
    }

    private fun normalizeCandidate(
        samples: DoubleArray,
        startX: Int,
        endX: Int,
        imageHeight: Int,
        policy: CurvePolicy,
    ): DoubleArray? {
        if (endX - startX < 3) return null
        val validCount = (startX until endX).count { samples[it].isFinite() }
        if (validCount < (endX - startX) * 0.65) return null
        interpolateMissing(samples, startX, endX)
        val anchorWidth = max(2, (endX - startX) / 20)
        val left = median((startX until startX + anchorWidth).map { samples[it] })
        val right = median((endX - anchorWidth until endX).map { samples[it] })
        val offsets = DoubleArray(samples.size) { Double.NaN }
        for (x in startX until endX) {
            val ratio = (x - startX).toDouble() / max(1, endX - startX - 1)
            val value = samples[x] - (left + (right - left) * ratio)
            offsets[x] = value
        }
        val trim = ((endX - startX) * CONTOUR_ENDPOINT_TRIM_FRACTION).roundToInt()
        val robustValues = (startX + trim until endX - trim)
            .map { offsets[it] }
            .filter { it.isFinite() }
        val robustMaximum = robustMagnitude(robustValues)
        return if (robustMaximum <= imageHeight * policy.maximumDeformationFraction) {
            offsets
        } else {
            null
        }
    }

    private fun candidateCoverage(candidates: List<DoubleArray>, region: Rect): Double {
        if (candidates.isEmpty() || region.width <= 0) return 0.0
        val coveredColumns = (region.x until region.x + region.width).count { x ->
            candidates.any { candidate -> x in candidate.indices && candidate[x].isFinite() }
        }
        return coveredColumns.toDouble() / region.width
    }

    private fun clampContourOnlyProfile(
        offsets: DoubleArray,
        region: Rect,
        imageHeight: Int,
    ) {
        val cap = imageHeight * CONTOUR_ONLY_MILD_MAX_DEFORMATION_FRACTION
        val centralStart = region.x + (region.width * CONTOUR_ENDPOINT_TRIM_FRACTION).roundToInt()
        val centralEnd = region.x + region.width -
            (region.width * CONTOUR_ENDPOINT_TRIM_FRACTION).roundToInt()
        val centralValues = (centralStart until centralEnd)
            .mapNotNull { index -> offsets.getOrNull(index)?.takeIf { it.isFinite() } }
        val robustCap = min(cap, robustMagnitude(centralValues))
        for (index in offsets.indices) {
            if (offsets[index].isFinite()) {
                offsets[index] = offsets[index].coerceIn(-robustCap, robustCap)
            }
        }
        applyEdgeTaper(offsets, region)
    }

    private fun aggregateCurves(
        candidates: List<DoubleArray>,
        region: Rect,
        imageHeight: Int,
        policy: CurvePolicy,
        boundaryPreferred: Boolean,
        evidenceCount: Int,
        evidenceDiagnostics: Map<String, Any> = emptyMap(),
    ): CurveEstimate {
        val offsets = DoubleArray(candidates.first().size) { Double.NaN }
        var validColumns = 0
        val columnDisagreement = mutableListOf<Double>()
        for (x in region.x until region.x + region.width) {
            val values = candidates.map { it[x] }.filter { it.isFinite() }
            if (values.isEmpty()) continue
            val center = median(values)
            val deviations = values.map { abs(it - center) }
            val mad = median(deviations)
            val limit = max(1.0, mad * 3.0)
            val inliers = values.filter { abs(it - center) <= limit }
            if (inliers.isEmpty()) continue
            offsets[x] = median(inliers)
            columnDisagreement.add(mad)
            validColumns++
        }
        val coverage = validColumns.toDouble() / region.width
        val minimumCoverage = if (boundaryPreferred) 0.65 else 0.48
        if (coverage < minimumCoverage) {
            throw CurvedCorrectionException(
                "curve_insufficient_coverage",
                "Curve signals do not cover enough of the page.",
                mapOf(
                    "rejectionReason" to "insufficient_coverage",
                    "coverage" to coverage,
                    "minimumCoverage" to minimumCoverage,
                    "evidenceCount" to evidenceCount,
                    "boundaryPreferred" to boundaryPreferred,
                    "minimumConfidence" to policy.minimumConfidence,
                ) + evidenceDiagnostics,
            )
        }
        interpolateMissing(offsets, region.x, region.x + region.width)
        var smoothed = movingMedian(offsets, region, max(3, region.width / 100))
        smoothed = movingAverage(smoothed, region, max(3, region.width / 80))
        applyEdgeTaper(smoothed, region)

        val candidateScore = if (boundaryPreferred) {
            1.0
        } else {
            min(1.0, evidenceCount / 5.0)
        }
        val typicalDisagreement = if (columnDisagreement.isEmpty()) {
            imageHeight.toDouble()
        } else {
            median(columnDisagreement)
        }
        val consistency = 1.0 - min(
            1.0,
            typicalDisagreement / max(1.0, imageHeight * policy.maximumDeformationFraction),
        )
        val confidence = coverage * 0.45 + candidateScore * 0.30 + consistency * 0.25
        return CurveEstimate(
            offsets = smoothed,
            confidence = confidence,
            coverage = coverage,
            candidateScore = candidateScore,
            consistency = consistency,
            evidenceCount = evidenceCount,
            boundaryPreferred = boundaryPreferred,
        )
    }

    private fun validateCurveOrThrow(
        estimate: CurveEstimate,
        imageHeight: Int,
        policy: CurvePolicy,
        requireStrongConfidence: Boolean = true,
        requireMinimumDeformation: Boolean = true,
        additionalDiagnostics: Map<String, Any> = emptyMap(),
    ) {
        val offsets = estimate.offsets
        val diagnostics = estimate.diagnostics(policy, imageHeight) + additionalDiagnostics
        if (!estimate.confidence.isFinite() ||
            (requireStrongConfidence && estimate.confidence < policy.minimumConfidence)
        ) {
            throw CurvedCorrectionException(
                "curve_low_confidence",
                "Curve confidence is low.",
                diagnostics +
                    mapOf("rejectionReason" to "confidence_below_threshold"),
            )
        }
        if (offsets.size < 3 || offsets.any { !it.isFinite() }) {
            throw CurvedCorrectionException(
                "curve_unsafe",
                "Curve contains unsafe coordinates.",
                diagnostics +
                    mapOf("rejectionReason" to "geometry_invalid"),
            )
        }
        val maximum = offsets.maxOf { abs(it) }
        if (requireMinimumDeformation &&
            maximum < imageHeight * policy.minimumDeformationFraction
        ) {
            throw CurvedCorrectionException(
                "curve_nearly_flat",
                "The page is already nearly flat.",
                diagnostics +
                    mapOf("rejectionReason" to "curvature_too_small"),
            )
        }
        if (maximum > imageHeight * policy.maximumDeformationFraction) {
            throw CurvedCorrectionException(
                "curve_unsafe",
                "Curve deformation is excessive.",
                diagnostics +
                    mapOf("rejectionReason" to "deformation_excessive"),
            )
        }
        val adjacentLimit = imageHeight * policy.maximumAdjacentDifferenceFraction
        for (x in 1 until offsets.size) {
            if (abs(offsets[x] - offsets[x - 1]) > adjacentLimit) {
                throw CurvedCorrectionException(
                    "curve_unsafe",
                    "Curve changes too abruptly.",
                    diagnostics +
                        mapOf("rejectionReason" to "inconsistent_curve"),
                )
            }
        }
        for (offset in offsets) {
            var previous = -1.0
            for (sample in 0..64) {
                val y = (imageHeight - 1) * sample / 64.0
                val mappedY = y + offset * sin(PI * y / (imageHeight - 1))
                if (!mappedY.isFinite() ||
                    mappedY < 0.0 ||
                    mappedY > imageHeight - 1 ||
                    mappedY <= previous
                ) {
                    throw CurvedCorrectionException(
                        "curve_unsafe",
                        "Remap coordinates are unsafe.",
                        diagnostics +
                            mapOf("rejectionReason" to "geometry_invalid"),
                    )
                }
                previous = mappedY
            }
        }
    }

    private fun curvatureEvidenceFusion(
        geometry: PageGeometryCurves,
        spineSignal: SpineBoundarySignal?,
        internalCurves: List<DoubleArray>,
        internalRawCurves: List<DoubleArray>,
        imageHeight: Int,
        flatMagnitudeLimit: Double,
    ): CurvatureEvidenceFusion {
        val topCurve = geometry.top
        val bottomCurve = geometry.bottom
        val topMagnitude = curveMagnitude(topCurve, imageHeight)
        val bottomMagnitude = curveMagnitude(bottomCurve, imageHeight)
        val internalMagnitudes = internalCurves.map { curveMagnitude(it, imageHeight) }
            .filter { it.isFinite() }
        val internalMagnitude = if (internalMagnitudes.isEmpty()) {
            0.0
        } else {
            median(internalMagnitudes)
        }
        val normalizedGeometryDirections = buildList {
            if (topMagnitude >= flatMagnitudeLimit * 0.7) {
                curveDirection(topCurve)?.let(::add)
            }
            if (bottomMagnitude >= flatMagnitudeLimit * 0.7) {
                curveDirection(bottomCurve)?.let(::add)
            }
        }
        val normalizedInternalDirections = buildList {
            internalCurves.take(4).forEach { curve ->
                if (curveMagnitude(curve, imageHeight) >= flatMagnitudeLimit * 0.7) {
                    curveDirection(curve)?.let(::add)
                }
            }
        }
        val normalizedDirections =
            normalizedGeometryDirections + normalizedInternalDirections
        val rawDirections = buildList {
            if (topMagnitude >= flatMagnitudeLimit * 0.7) {
                curveDirection(geometry.topRaw)?.let(::add)
            }
            if (bottomMagnitude >= flatMagnitudeLimit * 0.7) {
                curveDirection(geometry.bottomRaw)?.let(::add)
            }
            internalRawCurves.take(4).forEach { curve ->
                if (curveMagnitude(curve, imageHeight) >= flatMagnitudeLimit * 0.7) {
                    curveDirection(curve)?.let(::add)
                }
            }
        }
        val positive = normalizedDirections.count { it > 0 }
        val negative = normalizedDirections.count { it < 0 }
        val directionConsistency = if (normalizedDirections.isEmpty()) {
            0.0
        } else {
            max(positive, negative).toDouble() / normalizedDirections.size
        }
        val geometryDirection = dominantDirection(normalizedGeometryDirections)
        val internalDirection = dominantDirection(normalizedInternalDirections)
        val crossGroupConflict = normalizedGeometryDirections.size >= 2 &&
            normalizedInternalDirections.size >= 2 &&
            geometryDirection != 0 && internalDirection != 0 &&
            geometryDirection != internalDirection &&
            directionConsistencyOf(normalizedGeometryDirections) >= 0.67 &&
            directionConsistencyOf(normalizedInternalDirections) >= 0.67
        val conflicting = hasDirectionConflict(normalizedGeometryDirections) ||
            hasDirectionConflict(normalizedInternalDirections) ||
            crossGroupConflict
        val conflictBeforeNormalization = hasDirectionConflict(rawDirections)
        val pageContourMagnitude = max(topMagnitude, bottomMagnitude)
        val geometrySignalCount =
            listOf(topMagnitude, bottomMagnitude).count { it >= flatMagnitudeLimit } +
                if ((spineSignal?.curvature ?: 0.0) >= flatMagnitudeLimit * 0.7) 1 else 0
        val internalSignalCount = internalMagnitudes.count { it >= flatMagnitudeLimit }
        val contourDirection = when {
            topMagnitude >= bottomMagnitude -> curveDirection(topCurve)
            else -> curveDirection(bottomCurve)
        }
        val strongestInternalDirection = internalCurves
            .maxByOrNull { curveMagnitude(it, imageHeight) }
            ?.let(::curveDirection)
        val contourInternalAgree = contourDirection != null &&
            strongestInternalDirection != null && contourDirection == strongestInternalDirection
        val mildSupported = pageContourMagnitude >= flatMagnitudeLimit &&
            !conflicting &&
            directionConsistency >= 0.67 &&
            (geometrySignalCount >= 2 ||
                (geometrySignalCount >= 1 && internalSignalCount >= 1 && contourInternalAgree))
        return CurvatureEvidenceFusion(
            topMagnitude = topMagnitude,
            bottomMagnitude = bottomMagnitude,
            spineMagnitude = spineSignal?.curvature ?: 0.0,
            internalMagnitude = internalMagnitude,
            pageContourMagnitude = pageContourMagnitude,
            directionConsistency = directionConsistency,
            geometrySignalCount = geometrySignalCount,
            internalSignalCount = internalSignalCount,
            contourInternalAgree = contourInternalAgree,
            mildSupported = mildSupported,
            conflicting = conflicting,
            topRawSign = curveDirection(geometry.topRaw) ?: 0,
            bottomRawSign = curveDirection(geometry.bottomRaw) ?: 0,
            spineRawSign = spineSignal?.rawSign ?: 0,
            topNormalizedSign = curveDirection(topCurve) ?: 0,
            bottomNormalizedSign = curveDirection(bottomCurve) ?: 0,
            spineNormalizedSign = spineSignal?.normalizedSign ?: 0,
            conflictBeforeNormalization = conflictBeforeNormalization,
            horizontalDirectionVotes = mapOf(
                "top" to (curveDirection(topCurve) ?: 0),
                "bottom" to (curveDirection(bottomCurve) ?: 0),
                "internal" to normalizedInternalDirections,
            ),
        )
    }

    private fun curveMagnitude(curve: DoubleArray?, imageHeight: Int): Double {
        if (curve == null || imageHeight <= 0) return 0.0
        val finiteIndices = curve.indices.filter { curve[it].isFinite() }
        if (finiteIndices.isEmpty()) return 0.0
        val trim = (finiteIndices.size * CONTOUR_ENDPOINT_TRIM_FRACTION).roundToInt()
            .coerceAtMost((finiteIndices.size - 1) / 2)
        val central = finiteIndices.drop(trim).dropLast(trim).map { curve[it] }
        return robustMagnitude(central) / imageHeight
    }

    private fun curveDirection(curve: DoubleArray?): Int? {
        if (curve == null) return null
        val finiteIndices = curve.indices.filter { curve[it].isFinite() }
        if (finiteIndices.size < 3) return null
        val trim = (finiteIndices.size * CONTOUR_ENDPOINT_TRIM_FRACTION).roundToInt()
            .coerceAtMost((finiteIndices.size - 1) / 2)
        val finite = finiteIndices.drop(trim).dropLast(trim).map { curve[it] }
        if (finite.size < 3) return null
        val center = median(finite)
        return when {
            center > 0.000001 -> 1
            center < -0.000001 -> -1
            else -> null
        }
    }

    private fun hasDirectionConflict(directions: List<Int>): Boolean {
        if (directions.isEmpty()) return false
        val positive = directions.count { it > 0 }
        val negative = directions.count { it < 0 }
        val consistency = max(positive, negative).toDouble() / directions.size
        return positive > 0 && negative > 0 && consistency < 0.67
    }

    private fun directionConsistencyOf(directions: List<Int>): Double {
        if (directions.isEmpty()) return 0.0
        return max(directions.count { it > 0 }, directions.count { it < 0 }).toDouble() /
            directions.size
    }

    private fun dominantDirection(directions: List<Int>): Int {
        val positive = directions.count { it > 0 }
        val negative = directions.count { it < 0 }
        return when {
            positive > negative -> 1
            negative > positive -> -1
            else -> 0
        }
    }

    private fun classifyCurvature(
        estimate: CurveEstimate,
        fusion: CurvatureEvidenceFusion,
        imageHeight: Int,
        policy: CurvePolicy,
    ): String {
        val magnitude = (estimate.offsets.maxOfOrNull { abs(it) } ?: 0.0) /
            max(1, imageHeight)
        if (!magnitude.isFinite() ||
            !estimate.confidence.isFinite() ||
            estimate.evidenceCount < MINIMUM_CURVE_SIGNALS ||
            estimate.coverage < policy.minimumEvidenceCoverage ||
            fusion.conflicting
        ) {
            return "unreliable"
        }
        val allComponentsFlat = magnitude < policy.minimumDeformationFraction &&
            fusion.pageContourMagnitude < policy.minimumDeformationFraction &&
            fusion.internalMagnitude < policy.minimumDeformationFraction
        if (allComponentsFlat) return "flat"
        val existingMildRule = magnitude < policy.mildMagnitudeLimit &&
            estimate.confidence >= policy.mildMinimumConfidence &&
            estimate.coverage >= policy.mildMinimumCoverage &&
            estimate.consistency >= policy.mildMinimumConsistency
        val geometryMildRule = magnitude < policy.mildMagnitudeLimit &&
            fusion.mildSupported &&
            estimate.confidence >= 0.50 &&
            estimate.coverage >= policy.minimumEvidenceCoverage &&
            estimate.consistency >= policy.minimumEvidenceConsistency
        if (existingMildRule || geometryMildRule) {
            return "mildCurve"
        }
        if (magnitude >= policy.mildMagnitudeLimit &&
            estimate.confidence >= policy.minimumConfidence
        ) {
            return "strongCurve"
        }
        return "unreliable"
    }

    private fun horizontalStraightness(source: Mat): Double {
        val sample = Mat()
        val gray = Mat()
        val binary = Mat()
        val horizontal = Mat()
        try {
            val scale = min(
                1.0,
                CURVE_ANALYSIS_MAX_DIMENSION / max(source.cols(), source.rows()).toDouble(),
            )
            if (scale < 1.0) {
                Imgproc.resize(source, sample, Size(), scale, scale, Imgproc.INTER_AREA)
            } else {
                source.copyTo(sample)
            }
            Imgproc.cvtColor(sample, gray, Imgproc.COLOR_BGR2GRAY)
            Imgproc.adaptiveThreshold(
                gray,
                binary,
                255.0,
                Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
                Imgproc.THRESH_BINARY_INV,
                31,
                15.0,
            )
            val kernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_RECT,
                Size(max(9, sample.cols() / 40).toDouble(), 1.0),
            )
            try {
                Imgproc.morphologyEx(binary, horizontal, Imgproc.MORPH_OPEN, kernel)
            } finally {
                kernel.release()
            }
            val ink = Core.countNonZero(binary).toDouble()
            return if (ink <= 0.0) 0.0 else Core.countNonZero(horizontal) / ink
        } finally {
            horizontal.release()
            binary.release()
            gray.release()
            sample.release()
        }
    }

    private fun remapInStrips(
        source: Mat,
        analysisCurve: DoubleArray,
        analysisHeight: Int,
    ): Mat {
        val flattened = Mat(source.size(), source.type())
        val verticalScale = source.rows().toDouble() / analysisHeight
        var startRow = 0
        while (startRow < source.rows()) {
            val rows = min(REMAP_STRIP_HEIGHT, source.rows() - startRow)
            val mapX = Mat(rows, source.cols(), CvType.CV_32FC1)
            val mapY = Mat(rows, source.cols(), CvType.CV_32FC1)
            val strip = Mat()
            try {
                val xValues = FloatArray(rows * source.cols())
                val yValues = FloatArray(rows * source.cols())
                for (row in 0 until rows) {
                    val y = startRow + row
                    val verticalWeight = sin(PI * y / max(1, source.rows() - 1))
                    for (x in 0 until source.cols()) {
                        val analysisX = (
                            x.toDouble() / max(1, source.cols() - 1) *
                                (analysisCurve.size - 1)
                            ).roundToInt()
                        val mappedY = y + analysisCurve[analysisX] * verticalScale * verticalWeight
                        check(mappedY.isFinite() && mappedY in 0.0..(source.rows() - 1).toDouble()) {
                            "Unsafe remap coordinate."
                        }
                        val index = row * source.cols() + x
                        xValues[index] = x.toFloat()
                        yValues[index] = mappedY.toFloat()
                    }
                }
                mapX.put(0, 0, xValues)
                mapY.put(0, 0, yValues)
                Imgproc.remap(
                    source,
                    strip,
                    mapX,
                    mapY,
                    Imgproc.INTER_LINEAR,
                    Core.BORDER_REPLICATE,
                    Scalar.all(255.0),
                )
                val targetRows = flattened.rowRange(startRow, startRow + rows)
                try {
                    strip.copyTo(targetRows)
                } finally {
                    targetRows.release()
                }
            } finally {
                strip.release()
                mapY.release()
                mapX.release()
            }
            startRow += rows
        }
        return flattened
    }

    private fun movingMedian(values: DoubleArray, region: Rect, radius: Int): DoubleArray {
        val result = values.copyOf()
        for (x in region.x until region.x + region.width) {
            val samples = (max(region.x, x - radius)..min(region.x + region.width - 1, x + radius))
                .map { values[it] }
            result[x] = median(samples)
        }
        return result
    }

    private fun movingAverage(values: DoubleArray, region: Rect, radius: Int): DoubleArray {
        val result = values.copyOf()
        for (x in region.x until region.x + region.width) {
            var sum = 0.0
            var count = 0
            for (sample in max(region.x, x - radius)..min(region.x + region.width - 1, x + radius)) {
                sum += values[sample]
                count++
            }
            result[x] = sum / count
        }
        return result
    }

    private fun applyEdgeTaper(values: DoubleArray, region: Rect) {
        val taperWidth = max(2, (region.width * 0.08).roundToInt())
        for (x in values.indices) {
            if (x < region.x || x >= region.x + region.width) {
                values[x] = 0.0
                continue
            }
            val distanceFromEdge = min(x - region.x, region.x + region.width - 1 - x)
            val weight = min(1.0, distanceFromEdge.toDouble() / taperWidth)
            values[x] *= weight
        }
    }

    private fun interpolateMissing(values: DoubleArray, startX: Int, endX: Int) {
        val firstValid = (startX until endX).firstOrNull { values[it].isFinite() }
            ?: throw IllegalStateException("Stable page curvature was not found.")
        val lastValid = (endX - 1 downTo startX).first { values[it].isFinite() }
        for (x in startX until firstValid) values[x] = values[firstValid]
        for (x in lastValid + 1 until endX) values[x] = values[lastValid]
        var left = firstValid
        while (left < lastValid) {
            if (values[left].isFinite()) {
                var right = left + 1
                while (right <= lastValid && !values[right].isFinite()) right++
                for (x in left + 1 until right) {
                    val ratio = (x - left).toDouble() / (right - left)
                    values[x] = values[left] + (values[right] - values[left]) * ratio
                }
                left = right
            } else {
                left++
            }
        }
    }

    private fun parseAndValidateCorners(
        values: List<Map<String, Number>>,
        sourceSize: Size,
    ): Array<Point> {
        require(values.size == 4) { "Exactly four corners are required." }
        val points = values.map { value ->
            Point(
                value["x"]?.toDouble() ?: throw IllegalArgumentException("Corner x is missing."),
                value["y"]?.toDouble() ?: throw IllegalArgumentException("Corner y is missing."),
            )
        }.toTypedArray()
        points.forEach { point ->
            require(point.x in 0.0..sourceSize.width && point.y in 0.0..sourceSize.height) {
                "A corner lies outside the source image."
            }
        }
        var direction = 0.0
        for (index in points.indices) {
            val first = points[index]
            val second = points[(index + 1) % points.size]
            val third = points[(index + 2) % points.size]
            val cross =
                (second.x - first.x) * (third.y - second.y) -
                    (second.y - first.y) * (third.x - second.x)
            require(abs(cross) > 0.0001) { "Corners are collinear." }
            if (direction == 0.0) direction = kotlin.math.sign(cross)
            require(kotlin.math.sign(cross) == direction) { "Corners are not convex and ordered." }
        }
        require(direction > 0.0) { "Corners must be ordered clockwise." }
        return points
    }

    private fun median(values: List<Double>): Double {
        require(values.isNotEmpty())
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) {
            (sorted[middle - 1] + sorted[middle]) / 2.0
        } else {
            sorted[middle]
        }
    }

    private fun unsigned(value: Byte): Int = value.toInt() and 0xff

    private fun distance(first: Point, second: Point): Double =
        hypot(first.x - second.x, first.y - second.y)

    private fun elapsedMilliseconds(startedAt: Long): Int =
        ((System.nanoTime() - startedAt) / 1_000_000L).toInt()

    private data class CurveEstimate(
        val offsets: DoubleArray,
        val confidence: Double,
        val coverage: Double,
        val candidateScore: Double,
        val consistency: Double,
        val evidenceCount: Int,
        val boundaryPreferred: Boolean,
    ) {
        fun diagnostics(policy: CurvePolicy, imageHeight: Int): Map<String, Any> = mapOf(
            "confidence" to confidence,
            "minimumConfidence" to policy.minimumConfidence,
            "coverage" to coverage,
            "candidateScore" to candidateScore,
            "consistency" to consistency,
            "evidenceCount" to evidenceCount,
            "boundaryPreferred" to boundaryPreferred,
            "maximumDeformationFraction" to
                (offsets.maxOfOrNull { abs(it) } ?: 0.0) / max(1, imageHeight),
            "curvatureMagnitude" to
                (offsets.maxOfOrNull { abs(it) } ?: 0.0) / max(1, imageHeight),
            "combinedMagnitude" to
                (offsets.maxOfOrNull { abs(it) } ?: 0.0) / max(1, imageHeight),
            "minimumDeformationFraction" to policy.minimumDeformationFraction,
            "allowedMaximumDeformationFraction" to policy.maximumDeformationFraction,
        )
    }

    private data class CurvedFlattenResult(
        val image: Mat,
        val diagnostics: MutableMap<String, Any>,
    )

    private data class PageGeometryCurves(
        val top: DoubleArray? = null,
        val bottom: DoubleArray? = null,
        val topRaw: DoubleArray? = top,
        val bottomRaw: DoubleArray? = bottom,
    ) {
        fun withFallback(fallback: PageGeometryCurves): PageGeometryCurves = PageGeometryCurves(
            top = top ?: fallback.top,
            bottom = bottom ?: fallback.bottom,
            topRaw = topRaw ?: fallback.topRaw,
            bottomRaw = bottomRaw ?: fallback.bottomRaw,
        )
    }

    private data class CurvatureEvidenceFusion(
        val topMagnitude: Double,
        val bottomMagnitude: Double,
        val spineMagnitude: Double,
        val internalMagnitude: Double,
        val pageContourMagnitude: Double,
        val directionConsistency: Double,
        val geometrySignalCount: Int,
        val internalSignalCount: Int,
        val contourInternalAgree: Boolean,
        val mildSupported: Boolean,
        val conflicting: Boolean,
        val topRawSign: Int,
        val bottomRawSign: Int,
        val spineRawSign: Int,
        val topNormalizedSign: Int,
        val bottomNormalizedSign: Int,
        val spineNormalizedSign: Int,
        val conflictBeforeNormalization: Boolean,
        val horizontalDirectionVotes: Map<String, Any>,
    ) {
        fun diagnostics(): Map<String, Any> = mapOf(
            "pageContourMagnitude" to pageContourMagnitude,
            "topCurve" to topMagnitude,
            "bottomCurve" to bottomMagnitude,
            "spineCurve" to spineMagnitude,
            "internalLineMagnitude" to internalMagnitude,
            "geometryDirectionConsistency" to directionConsistency,
            "geometryEvidenceCount" to geometrySignalCount,
            "internalEvidenceCount" to internalSignalCount,
            "contourInternalAgree" to contourInternalAgree,
            "geometryMildSupported" to mildSupported,
            "evidenceConflict" to conflicting,
            "topRawSign" to topRawSign,
            "bottomRawSign" to bottomRawSign,
            "spineRawSign" to spineRawSign,
            "topNormalizedSign" to topNormalizedSign,
            "bottomNormalizedSign" to bottomNormalizedSign,
            "spineNormalizedSign" to spineNormalizedSign,
            "directionConflictBeforeNormalization" to conflictBeforeNormalization,
            "directionConflictAfterNormalization" to conflicting,
            "signConvention" to "rectified_y_axis",
            "horizontalDirectionVotes" to horizontalDirectionVotes,
            "spineUsedForDirectionConflict" to false,
        )
    }

    private data class SpineBoundarySignal(
        val side: String,
        val curvature: Double,
        val strength: Double,
        val rawSign: Int,
        val normalizedSign: Int,
    )

    private data class InternalCurveSignal(
        val raw: DoubleArray,
        val normalized: DoubleArray,
    )

    private data class ChordProjection(
        val t: Double,
        val signedDistance: Double,
    )

    class CurvedCorrectionException(
        val code: String,
        message: String,
        val details: Map<String, Any> = emptyMap(),
    ) : IllegalStateException(message)

    private data class CurvePolicy(
        val insetFraction: Double,
        val minimumConfidence: Double,
        val minimumDeformationFraction: Double,
        val maximumDeformationFraction: Double,
        val maximumAdjacentDifferenceFraction: Double,
        val minimumEvidenceCoverage: Double,
        val minimumEvidenceConsistency: Double,
        val mildMagnitudeLimit: Double,
        val mildMinimumConfidence: Double,
        val mildMinimumCoverage: Double,
        val mildMinimumConsistency: Double,
        val mildDewarpStrength: Double,
    ) {
        companion object {
            fun from(values: Map<String, Number>): CurvePolicy = CurvePolicy(
                insetFraction = values.requiredDouble("insetFraction", 0.0, 0.2),
                minimumConfidence = values.requiredDouble("minimumConfidence", 0.0, 1.0),
                minimumDeformationFraction =
                    values.requiredDouble("minimumDeformationFraction", 0.0, 0.1),
                maximumDeformationFraction =
                    values.requiredDouble("maximumDeformationFraction", 0.0, 0.1),
                maximumAdjacentDifferenceFraction =
                    values.requiredDouble("maximumAdjacentDifferenceFraction", 0.0, 0.1),
                minimumEvidenceCoverage =
                    values.requiredDouble("minimumEvidenceCoverage", 0.0, 1.0),
                minimumEvidenceConsistency =
                    values.requiredDouble("minimumEvidenceConsistency", 0.0, 1.0),
                mildMagnitudeLimit =
                    values.requiredDouble("mildMagnitudeLimit", 0.0, 0.1),
                mildMinimumConfidence =
                    values.requiredDouble("mildMinimumConfidence", 0.0, 1.0),
                mildMinimumCoverage =
                    values.requiredDouble("mildMinimumCoverage", 0.0, 1.0),
                mildMinimumConsistency =
                    values.requiredDouble("mildMinimumConsistency", 0.0, 1.0),
                mildDewarpStrength =
                    values.requiredDouble("mildDewarpStrength", 0.0, 1.0),
            ).also { policy ->
                require(policy.minimumDeformationFraction < policy.maximumDeformationFraction)
            }
        }
    }

    private fun Map<String, Number>.requiredDouble(
        key: String,
        minimum: Double,
        maximum: Double,
    ): Double {
        val value = this[key]?.toDouble() ?: throw IllegalArgumentException("Missing $key.")
        require(value.isFinite() && value in minimum..maximum) { "Invalid $key." }
        return value
    }
}
