package com.myphotw.scana.imageprocessing

import android.content.Context
import android.os.SystemClock
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfInt
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.io.Closeable
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Debug comparison implementation for the FairScan v1.2.0 segmentation model.
 *
 * This service never participates in Scana's production crop decision. Calls
 * are serialized by MainActivity's image-processing executor and this class
 * additionally synchronizes interpreter access for lifecycle safety.
 */
class FairScanDocumentSegmenter(private val context: Context) : Closeable {
    private var interpreter: Interpreter? = null
    private var inputBuffer: ByteBuffer? = null
    private var outputBuffer: ByteBuffer? = null
    private var inputShape: IntArray? = null
    private var outputShape: IntArray? = null
    private var modelLoadMilliseconds = 0L

    @Synchronized
    fun modelInfo(): Map<String, Any> {
        ensureInterpreter()
        return mapOf(
            "modelVersion" to MODEL_VERSION,
            "modelAsset" to MODEL_ASSET,
            "modelLoadMs" to modelLoadMilliseconds,
            "inputShape" to inputShape!!.toList(),
            "outputShape" to outputShape!!.toList(),
            "inputType" to DataType.FLOAT32.toString(),
            "outputType" to DataType.FLOAT32.toString(),
            "threads" to THREAD_COUNT,
        )
    }

    @Synchronized
    fun segment(
        imagePath: String,
        pageSide: String?,
        debugArtifactsEnabled: Boolean,
        debugOutputDirectory: String?,
        debugStem: String,
        openCvCorners: List<Map<String, Number>>?,
        expectedGuideCorners: List<Map<String, Number>>?,
    ): Map<String, Any> {
        val totalStart = SystemClock.elapsedRealtime()
        var source: Mat? = null
        var resizedRgb: Mat? = null
        var probability: Mat? = null
        var binary: Mat? = null
        var refined: Mat? = null
        var primaryMask: Mat? = null
        try {
            ensureInterpreter()
            val activeInterpreter = checkNotNull(interpreter)
            val inShape = checkNotNull(inputShape)
            val outShape = checkNotNull(outputShape)
            val inputHeight = inShape[1]
            val inputWidth = inShape[2]
            val maskHeight = outShape[1]
            val maskWidth = outShape[2]

            val preprocessStart = SystemClock.elapsedRealtime()
            source = Imgcodecs.imread(imagePath, Imgcodecs.IMREAD_COLOR)
            require(!source.empty()) { "source_decode_failed" }
            val sourceWidth = source.cols()
            val sourceHeight = source.rows()
            val rgb = Mat()
            try {
                Imgproc.cvtColor(source, rgb, Imgproc.COLOR_BGR2RGB)
                resizedRgb = Mat()
                Imgproc.resize(
                    rgb,
                    resizedRgb,
                    Size(inputWidth.toDouble(), inputHeight.toDouble()),
                    0.0,
                    0.0,
                    Imgproc.INTER_LINEAR,
                )
            } finally {
                rgb.release()
            }
            val rgbBytes = ByteArray(inputWidth * inputHeight * 3)
            resizedRgb.get(0, 0, rgbBytes)
            val input = checkNotNull(inputBuffer).apply { clear() }
            for (value in rgbBytes) {
                input.putFloat(((value.toInt() and 0xff) - 127.5f) / 127.5f)
            }
            input.rewind()
            val preprocessMs = SystemClock.elapsedRealtime() - preprocessStart

            val inferenceStart = SystemClock.elapsedRealtime()
            val output = checkNotNull(outputBuffer).apply { clear() }
            activeInterpreter.run(input, output)
            output.rewind()
            val probabilities = FloatArray(maskWidth * maskHeight)
            output.asFloatBuffer().get(probabilities)
            // FairScan's Android implementation treats the model output as a
            // probability map and clamps it rather than adding sigmoid here.
            for (index in probabilities.indices) {
                probabilities[index] = probabilities[index].coerceIn(0f, 1f)
            }
            val inferenceMs = SystemClock.elapsedRealtime() - inferenceStart

            val postprocessStart = SystemClock.elapsedRealtime()
            probability = Mat(maskHeight, maskWidth, CvType.CV_32FC1)
            probability.put(0, 0, probabilities)
            binary = Mat()
            Imgproc.threshold(probability, binary, MASK_THRESHOLD, 255.0, Imgproc.THRESH_BINARY)
            binary.convertTo(binary, CvType.CV_8UC1)
            refined = refineMask(binary)
            val component = selectLargestPlausibleComponent(
                refined,
                expectedGuideCorners = expectedGuideCorners,
                sourceWidth = sourceWidth,
                sourceHeight = sourceHeight,
            )
                ?: return failure(
                    reason = "empty_mask",
                    totalStart = totalStart,
                    preprocessMs = preprocessMs,
                    inferenceMs = inferenceMs,
                    sourceWidth = sourceWidth,
                    sourceHeight = sourceHeight,
                    maskWidth = maskWidth,
                    maskHeight = maskHeight,
                    pageSide = pageSide,
                )
            primaryMask = Mat.zeros(maskHeight, maskWidth, CvType.CV_8UC1)
            Imgproc.drawContours(
                primaryMask,
                listOf(component.contour),
                0,
                Scalar(255.0),
                Imgproc.FILLED,
            )
            val maskArea = maskWidth.toDouble() * maskHeight
            val positivePixels = Core.countNonZero(primaryMask).toDouble()
            val coverage = positivePixels / maskArea
            val continuity = (component.area / max(1.0, positivePixels)).coerceIn(0.0, 1.0)
            val meanProbability = meanForegroundProbability(probabilities, primaryMask)
            val confidence = (meanProbability * 0.65 + continuity * 0.35).coerceIn(0.0, 1.0)
            val maskCorners = try {
                estimateCorners(component.contour, maskWidth, maskHeight)
            } finally {
                component.contour.release()
            } ?: return failure(
                reason = "invalid_corners",
                totalStart = totalStart,
                preprocessMs = preprocessMs,
                inferenceMs = inferenceMs,
                sourceWidth = sourceWidth,
                sourceHeight = sourceHeight,
                maskWidth = maskWidth,
                maskHeight = maskHeight,
                pageSide = pageSide,
                maskCoverage = coverage,
            )
            val sourceCorners = maskCorners.map { point ->
                Point(
                    point.x / maskWidth * sourceWidth,
                    point.y / maskHeight * sourceHeight,
                )
            }
            val refinement = AiPaperBoundaryRefiner().refine(
                source = source,
                aiMask = primaryMask,
                rawCorners = sourceCorners,
                pageSide = pageSide,
            )
            val artifacts = if (debugArtifactsEnabled && !debugOutputDirectory.isNullOrBlank()) {
                writeDebugArtifacts(
                    source = source,
                    mask = primaryMask,
                    aiRawCorners = sourceCorners,
                    refinement = refinement,
                    openCvCorners = openCvCorners,
                    sourceImagePath = imagePath,
                    outputDirectory = debugOutputDirectory,
                    stem = sanitizeStem(debugStem),
                )
            } else {
                emptyMap()
            }
            val postprocessMs = SystemClock.elapsedRealtime() - postprocessStart
            return mapOf(
                "success" to true,
                "modelVersion" to MODEL_VERSION,
                "modelLoadMs" to modelLoadMilliseconds,
                "preprocessMs" to preprocessMs,
                "inferenceTimeMs" to inferenceMs,
                "postprocessMs" to postprocessMs,
                "totalMs" to (SystemClock.elapsedRealtime() - totalStart),
                "sourceWidth" to sourceWidth,
                "sourceHeight" to sourceHeight,
                "maskWidth" to maskWidth,
                "maskHeight" to maskHeight,
                "confidence" to confidence,
                "maskCoverage" to coverage,
                "maskContinuity" to continuity,
                "pageSide" to (pageSide ?: "single"),
                "corners" to sourceCorners.map { mapOf("x" to it.x, "y" to it.y) },
                "refinementAttempted" to true,
                "refinementAccepted" to refinement.accepted,
                "refinedCorners" to refinement.corners.orEmpty().map {
                    mapOf("x" to it.x, "y" to it.y)
                },
                // Reuse the already-computed owned paper contour as optional
                // curvature geometry. This does not change AI crop scoring.
                "paperContour" to refinement.paperContour.orEmpty().let { contour ->
                    val step = max(1, contour.size / MAX_CURVATURE_CONTOUR_SAMPLES)
                    contour.filterIndexed { index, _ -> index % step == 0 }
                        .take(MAX_CURVATURE_CONTOUR_SAMPLES)
                        .map { mapOf("x" to it.x, "y" to it.y) }
                },
                "finalCorners" to refinement.finalCorners.orEmpty().map {
                    mapOf("x" to it.x, "y" to it.y)
                },
                "finalSource" to (refinement.finalSource ?: "none"),
                "edgeVisibilities" to refinement.edgeVisibilities.map { edge ->
                    mapOf(
                        "edge" to edge.edge,
                        "transitionScore" to edge.transitionScore,
                        "supportingSampleRatio" to edge.supportingSampleRatio,
                        "borderDistance" to edge.borderDistance,
                        "occlusionPenalty" to edge.occlusionPenalty,
                        "confidence" to edge.confidence,
                        "status" to edge.status,
                        "foregroundBeyond" to edge.foregroundBeyond,
                        "paperContinuesBeyond" to edge.paperContinuesBeyond,
                    )
                },
                "refinementFailureReason" to (refinement.failureReason ?: "none"),
                "maskToSearchRoiMs" to refinement.maskToSearchRoiMs,
                "paperCandidateMs" to refinement.paperCandidateMs,
                "edgeRefineMs" to refinement.edgeRefineMs,
                "cornerEstimateMs" to refinement.cornerEstimateMs,
                "totalRefineMs" to refinement.totalRefineMs,
                "rawAreaRatio" to refinement.rawAreaRatio,
                "refinedAreaRatio" to refinement.refinedAreaRatio,
                "aiContainmentRatio" to refinement.aiContainmentRatio,
                "areaExpansionRatio" to refinement.areaExpansionRatio,
                "paperTransitionScore" to refinement.paperTransitionScore,
                "mainPageOwnershipScore" to refinement.mainPageOwnershipScore,
                "outerEnvelopeConsistency" to refinement.outerEnvelopeConsistency,
                "edgeContinuity" to refinement.edgeContinuity,
                "adjacentPagePenalty" to refinement.adjacentPagePenalty,
                "occlusionPenalty" to refinement.occlusionPenalty,
                "refinedConfidence" to refinement.refinedConfidence,
                "refinedStatus" to refinement.refinedStatus,
                "searchRoi" to mapOf(
                    "left" to refinement.searchRoi.x,
                    "top" to refinement.searchRoi.y,
                    "right" to refinement.searchRoi.x + refinement.searchRoi.width,
                    "bottom" to refinement.searchRoi.y + refinement.searchRoi.height,
                ),
                "inputShape" to inShape.toList(),
                "outputShape" to outShape.toList(),
                "debugArtifactsEnabled" to debugArtifactsEnabled,
            ) + artifacts
        } catch (error: Throwable) {
            return failure(
                reason = error.message ?: error.javaClass.simpleName,
                totalStart = totalStart,
                pageSide = pageSide,
            )
        } finally {
            source?.release()
            resizedRgb?.release()
            probability?.release()
            binary?.release()
            refined?.release()
            primaryMask?.release()
        }
    }

    private fun ensureInterpreter() {
        if (interpreter != null) return
        val started = SystemClock.elapsedRealtime()
        val bytes = context.assets.open(MODEL_ASSET).use { it.readBytes() }
        require(bytes.isNotEmpty()) { "model_asset_empty" }
        val model = ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder())
        model.put(bytes)
        model.rewind()
        val loaded = Interpreter(
            model,
            Interpreter.Options().apply {
                setNumThreads(THREAD_COUNT)
                setUseXNNPACK(true)
            },
        )
        val input = loaded.getInputTensor(0)
        val output = loaded.getOutputTensor(0)
        val nextInputShape = input.shape()
        val nextOutputShape = output.shape()
        require(input.dataType() == DataType.FLOAT32) { "input_tensor_type_mismatch" }
        require(output.dataType() == DataType.FLOAT32) { "output_tensor_type_mismatch" }
        require(nextInputShape.size == 4 && nextInputShape[0] == 1 && nextInputShape[3] == 3) {
            "input_tensor_shape_mismatch"
        }
        require(nextOutputShape.size == 4 && nextOutputShape[0] == 1 && nextOutputShape[3] == 1) {
            "output_tensor_shape_mismatch"
        }
        inputShape = nextInputShape
        outputShape = nextOutputShape
        inputBuffer = ByteBuffer.allocateDirect(
            nextInputShape[1] * nextInputShape[2] * nextInputShape[3] * 4,
        ).order(ByteOrder.nativeOrder())
        outputBuffer = ByteBuffer.allocateDirect(
            nextOutputShape[1] * nextOutputShape[2] * nextOutputShape[3] * 4,
        ).order(ByteOrder.nativeOrder())
        interpreter = loaded
        modelLoadMilliseconds = SystemClock.elapsedRealtime() - started
    }

    private fun refineMask(mask: Mat): Mat {
        val refined = Mat()
        val closeKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        val openKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        try {
            Imgproc.morphologyEx(mask, refined, Imgproc.MORPH_CLOSE, closeKernel)
            Imgproc.morphologyEx(refined, refined, Imgproc.MORPH_OPEN, openKernel)
        } finally {
            closeKernel.release()
            openKernel.release()
        }
        return refined
    }

    private data class Component(
        val contour: MatOfPoint,
        val area: Double,
        val score: Double,
    )

    private fun selectLargestPlausibleComponent(
        mask: Mat,
        expectedGuideCorners: List<Map<String, Number>>?,
        sourceWidth: Int,
        sourceHeight: Int,
    ): Component? {
        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        val copy = mask.clone()
        try {
            Imgproc.findContours(copy, contours, hierarchy, Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_SIMPLE)
            val imageArea = mask.cols().toDouble() * mask.rows()
            val imageCenter = Point(mask.cols() / 2.0, mask.rows() / 2.0)
            val guideCenter = expectedGuideCorners
                ?.takeIf { it.size == 4 && sourceWidth > 0 && sourceHeight > 0 }
                ?.let { corners ->
                    Point(
                        corners.mapNotNull { it["x"]?.toDouble() }.average() /
                            sourceWidth * mask.cols(),
                        corners.mapNotNull { it["y"]?.toDouble() }.average() /
                            sourceHeight * mask.rows(),
                    )
                }
            val maxCenterDistance = hypot(imageCenter.x, imageCenter.y).coerceAtLeast(1.0)
            val selected = contours
                .mapNotNull { contour ->
                    val area = abs(Imgproc.contourArea(contour))
                    val areaRatio = area / imageArea
                    if (areaRatio !in MIN_COMPONENT_AREA_RATIO..MAX_COMPONENT_AREA_RATIO) {
                        return@mapNotNull null
                    }

                    val bounds = Imgproc.boundingRect(contour)
                    val shortSide = min(bounds.width, bounds.height).toDouble().coerceAtLeast(1.0)
                    val aspectRatio = max(bounds.width, bounds.height) / shortSide
                    if (aspectRatio > MAX_COMPONENT_ASPECT_RATIO) return@mapNotNull null

                    val contourCenter = Point(
                        bounds.x + bounds.width / 2.0,
                        bounds.y + bounds.height / 2.0,
                    )
                    val centerDistance = hypot(
                        contourCenter.x - imageCenter.x,
                        contourCenter.y - imageCenter.y,
                    )
                    val proximityScore =
                        (1.0 - centerDistance / maxCenterDistance).coerceIn(0.0, 1.0)
                    val centerCurve = MatOfPoint2f(*contour.toArray())
                    val centerCoverage = try {
                        if (Imgproc.pointPolygonTest(centerCurve, imageCenter, false) >= 0.0) {
                            1.0
                        } else {
                            proximityScore
                        }
                    } finally {
                        centerCurve.release()
                    }
                    val guideScore = if (guideCenter == null) {
                        0.0
                    } else {
                        val guideDistance = hypot(
                            contourCenter.x - guideCenter.x,
                            contourCenter.y - guideCenter.y,
                        )
                        val maxGuideDistance = hypot(mask.cols().toDouble(), mask.rows().toDouble())
                            .coerceAtLeast(1.0)
                        (1.0 - guideDistance / maxGuideDistance).coerceIn(0.0, 1.0)
                    }
                    val aspectScore =
                        (1.0 - (aspectRatio - 1.0) / (MAX_COMPONENT_ASPECT_RATIO - 1.0))
                            .coerceIn(0.0, 1.0)
                    val score = if (guideCenter == null) {
                        areaRatio * 0.70 + centerCoverage * 0.20 + aspectScore * 0.10
                    } else {
                        areaRatio * 0.64 + centerCoverage * 0.18 + aspectScore * 0.08 + guideScore * 0.10
                    }
                    Component(
                        contour = contour,
                        area = area,
                        score = score,
                    )
                }
                .maxWithOrNull(compareBy<Component> { it.score }.thenBy { it.area })
            contours.filter { it !== selected?.contour }.forEach(MatOfPoint::release)
            return selected
        } finally {
            copy.release()
            hierarchy.release()
        }
    }

    private fun estimateCorners(contour: MatOfPoint, width: Int, height: Int): List<Point>? {
        val hullIndices = MatOfInt()
        val hullPoints = MatOfPoint()
        val hullCurve = MatOfPoint2f()
        try {
            Imgproc.convexHull(contour, hullIndices)
            val points = contour.toArray()
            val hull = hullIndices.toArray().map { points[it] }
            if (hull.size < 4) return null
            hullPoints.fromList(hull)
            hullCurve.fromArray(*hullPoints.toArray())
            val perimeter = Imgproc.arcLength(hullCurve, true)
            for (ratio in listOf(0.015, 0.025, 0.04, 0.06, 0.08)) {
                val approximated = MatOfPoint2f()
                try {
                    Imgproc.approxPolyDP(hullCurve, approximated, perimeter * ratio, true)
                    val candidate = approximated.toArray().toList()
                    if (candidate.size == 4) return orderCorners(candidate, width, height)
                } finally {
                    approximated.release()
                }
            }
            val rectangle = Imgproc.minAreaRect(hullCurve)
            val rectanglePoints = arrayOf(Point(), Point(), Point(), Point())
            rectangle.points(rectanglePoints)
            return orderCorners(rectanglePoints.toList(), width, height)
        } finally {
            hullIndices.release()
            hullPoints.release()
            hullCurve.release()
        }
    }

    private fun orderCorners(points: List<Point>, width: Int, height: Int): List<Point>? {
        if (points.size != 4) return null
        val top = points.sortedBy { it.y }.take(2).sortedBy { it.x }
        val bottom = points.sortedBy { it.y }.takeLast(2).sortedBy { it.x }
        val ordered = listOf(top[0], top[1], bottom[1], bottom[0])
        if (ordered.any { !it.x.isFinite() || !it.y.isFinite() || it.x !in 0.0..width.toDouble() || it.y !in 0.0..height.toDouble() }) {
            return null
        }
        return ordered
    }

    private fun meanForegroundProbability(probabilities: FloatArray, mask: Mat): Double {
        val bytes = ByteArray(mask.cols() * mask.rows())
        mask.get(0, 0, bytes)
        var total = 0.0
        var count = 0
        for (index in probabilities.indices) {
            if ((bytes[index].toInt() and 0xff) > 0) {
                total += probabilities[index]
                count++
            }
        }
        return if (count == 0) 0.0 else total / count
    }

    private fun writeDebugArtifacts(
        source: Mat,
        mask: Mat,
        aiRawCorners: List<Point>,
        refinement: AiPaperBoundaryRefiner.Result,
        openCvCorners: List<Map<String, Number>>?,
        sourceImagePath: String,
        outputDirectory: String,
        stem: String,
    ): Map<String, Any> {
        val directory = File(outputDirectory).apply { mkdirs() }
        val raw = File(directory, "${stem}_raw.jpg")
        File(sourceImagePath).copyTo(raw, overwrite = true)
        val maskFile = File(directory, "${stem}_ai_mask.png")
        Imgcodecs.imwrite(maskFile.absolutePath, mask)

        val aiRawOverlay = source.clone()
        val fullMask = Mat()
        val tint = source.clone()
        val blended = Mat()
        try {
            Imgproc.resize(mask, fullMask, source.size(), 0.0, 0.0, Imgproc.INTER_NEAREST)
            tint.setTo(Scalar(40.0, 220.0, 40.0))
            Core.addWeighted(source, 0.70, tint, 0.30, 0.0, blended)
            blended.copyTo(aiRawOverlay, fullMask)
            drawCorners(aiRawOverlay, aiRawCorners, Scalar(30.0, 255.0, 30.0))
            val aiRawOverlayFile = File(directory, "${stem}_ai_raw_overlay.jpg")
            Imgcodecs.imwrite(aiRawOverlayFile.absolutePath, aiRawOverlay)

                val aiRefinedOverlay = source.clone()
                val aiFinalOverlay = source.clone()
                val searchOverlay = source.clone()
                try {
                drawCorners(aiRefinedOverlay, aiRawCorners, Scalar(80.0, 180.0, 255.0), 5)
                refinement.corners?.let {
                    drawCorners(aiRefinedOverlay, it, Scalar(30.0, 255.0, 30.0), 8)
                }
                val aiRefinedOverlayFile = File(directory, "${stem}_ai_refined_overlay.jpg")
                Imgcodecs.imwrite(aiRefinedOverlayFile.absolutePath, aiRefinedOverlay)

                drawCorners(aiFinalOverlay, aiRawCorners, Scalar(80.0, 180.0, 255.0), 4)
                refinement.finalCorners?.let {
                    drawCorners(aiFinalOverlay, it, Scalar(30.0, 255.0, 30.0), 8)
                }
                val aiFinalOverlayFile = File(directory, "${stem}_ai_final_overlay.jpg")
                Imgcodecs.imwrite(aiFinalOverlayFile.absolutePath, aiFinalOverlay)

                val roi = refinement.searchRoi
                if (roi.width > 0 && roi.height > 0) {
                    Imgproc.rectangle(
                        searchOverlay,
                        Point(roi.x.toDouble(), roi.y.toDouble()),
                        Point((roi.x + roi.width).toDouble(), (roi.y + roi.height).toDouble()),
                        Scalar(255.0, 0.0, 255.0),
                        6,
                    )
                }
                refinement.paperContour?.let { contour ->
                    val points = MatOfPoint(*contour.toTypedArray())
                    try {
                        Imgproc.polylines(searchOverlay, listOf(points), true, Scalar(0.0, 220.0, 255.0), 5)
                    } finally {
                        points.release()
                    }
                }
                val searchRoiFile = File(directory, "${stem}_ai_search_roi.jpg")
                Imgcodecs.imwrite(searchRoiFile.absolutePath, searchOverlay)

                val envelopeOverlay = source.clone()
                val envelopeOverlayFile = File(directory, "${stem}_ai_envelope_overlay.jpg")
                try {
                    drawCorners(envelopeOverlay, aiRawCorners, Scalar(40.0, 160.0, 255.0), 5)
                    refinement.paperContour?.let { contour ->
                        val points = MatOfPoint(*contour.toTypedArray())
                        try {
                            Imgproc.polylines(envelopeOverlay, listOf(points), true, Scalar(0.0, 220.0, 255.0), 5)
                        } finally {
                            points.release()
                        }
                    }
                    refinement.envelopeCorners?.let {
                        drawCorners(envelopeOverlay, it, Scalar(255.0, 0.0, 255.0), 6)
                    }
                    refinement.corners?.let {
                        drawCorners(envelopeOverlay, it, Scalar(30.0, 255.0, 30.0), 8)
                    }
                    Imgcodecs.imwrite(envelopeOverlayFile.absolutePath, envelopeOverlay)
                } finally {
                    envelopeOverlay.release()
                }

                val openCvOverlay = source.clone()
                try {
                    val parsed = openCvCorners?.mapNotNull { value ->
                        val x = value["x"]?.toDouble()
                        val y = value["y"]?.toDouble()
                        if (x == null || y == null) null else Point(x, y)
                    }.orEmpty()
                    if (parsed.size == 4) drawCorners(openCvOverlay, parsed, Scalar(255.0, 220.0, 0.0))
                    val openCvOverlayFile = File(directory, "${stem}_opencv_overlay.jpg")
                    Imgcodecs.imwrite(openCvOverlayFile.absolutePath, openCvOverlay)
                    return mapOf(
                        "debugRawPath" to raw.absolutePath,
                        "debugMaskPath" to maskFile.absolutePath,
                        // Compatibility alias for AI-PoC 1 session readers.
                        "debugAiOverlayPath" to aiRawOverlayFile.absolutePath,
                        "debugAiRawOverlayPath" to aiRawOverlayFile.absolutePath,
                        "debugAiRefinedOverlayPath" to aiRefinedOverlayFile.absolutePath,
                        "debugAiFinalOverlayPath" to aiFinalOverlayFile.absolutePath,
                        "debugSearchRoiPath" to searchRoiFile.absolutePath,
                        "debugEnvelopeOverlayPath" to envelopeOverlayFile.absolutePath,
                        "debugOpenCvOverlayPath" to openCvOverlayFile.absolutePath,
                    )
                } finally {
                    openCvOverlay.release()
                }
            } finally {
                aiRefinedOverlay.release()
                aiFinalOverlay.release()
                searchOverlay.release()
            }
        } finally {
            aiRawOverlay.release()
            fullMask.release()
            tint.release()
            blended.release()
        }
    }

    private fun drawCorners(image: Mat, corners: List<Point>, color: Scalar, thickness: Int = 8) {
        for (index in corners.indices) {
            Imgproc.line(image, corners[index], corners[(index + 1) % corners.size], color, thickness)
            Imgproc.circle(image, corners[index], 12, color, -1)
        }
    }

    private fun failure(
        reason: String,
        totalStart: Long,
        preprocessMs: Long = 0,
        inferenceMs: Long = 0,
        sourceWidth: Int = 0,
        sourceHeight: Int = 0,
        maskWidth: Int = 0,
        maskHeight: Int = 0,
        pageSide: String?,
        maskCoverage: Double = 0.0,
    ): Map<String, Any> = mapOf(
        "success" to false,
        "modelVersion" to MODEL_VERSION,
        "modelLoadMs" to modelLoadMilliseconds,
        "preprocessMs" to preprocessMs,
        "inferenceTimeMs" to inferenceMs,
        "postprocessMs" to 0,
        "totalMs" to (SystemClock.elapsedRealtime() - totalStart),
        "sourceWidth" to sourceWidth,
        "sourceHeight" to sourceHeight,
        "maskWidth" to maskWidth,
        "maskHeight" to maskHeight,
        "maskCoverage" to maskCoverage,
        "pageSide" to (pageSide ?: "single"),
        "failureReason" to reason,
    )

    private fun sanitizeStem(value: String): String =
        value.replace(Regex("[^A-Za-z0-9_-]"), "_").take(80).ifBlank { "page" }

    override fun close() {
        synchronized(this) {
            interpreter?.close()
            interpreter = null
            inputBuffer = null
            outputBuffer = null
        }
    }

    companion object {
        const val MODEL_VERSION = "v1.2.0"
        const val MODEL_ASSET = "models/fairscan_document_segmentation.tflite"
        const val MASK_THRESHOLD = 0.5
        const val THREAD_COUNT = 2
        const val MIN_COMPONENT_AREA_RATIO = 0.02
        const val MAX_COMPONENT_AREA_RATIO = 0.995
        const val MAX_COMPONENT_ASPECT_RATIO = 8.0
        const val MAX_CURVATURE_CONTOUR_SAMPLES = 192
    }
}
