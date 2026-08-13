package com.myphotw.scana.imageprocessing

import android.os.SystemClock
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.MatOfInt
import org.opencv.core.Point
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Diagnostic paper-edge refinement that uses the AI mask only as a spatial
 * prior. It is deliberately isolated from Scana's production crop decision.
 */
class AiPaperBoundaryRefiner {
    data class EdgeVisibility(
        val edge: String,
        val transitionScore: Double,
        val supportingSampleRatio: Double,
        val borderDistance: Double,
        val occlusionPenalty: Double,
        val confidence: Double,
        val status: String,
        val foregroundBeyond: Boolean = false,
        val paperContinuesBeyond: Boolean = false,
    )

    data class Result(
        val accepted: Boolean,
        val corners: List<Point>?,
        val searchRoi: Rect,
        val rawAreaRatio: Double,
        val refinedAreaRatio: Double,
        val aiContainmentRatio: Double,
        val areaExpansionRatio: Double,
        val paperTransitionScore: Double,
        val mainPageOwnershipScore: Double,
        val outerEnvelopeConsistency: Double,
        val edgeContinuity: Double,
        val adjacentPagePenalty: Double,
        val occlusionPenalty: Double,
        val refinedConfidence: Double,
        val refinedStatus: String,
        val maskToSearchRoiMs: Long,
        val paperCandidateMs: Long,
        val edgeRefineMs: Long,
        val cornerEstimateMs: Long,
        val totalRefineMs: Long,
        val failureReason: String?,
        val paperContour: List<Point>?,
        val envelopeCorners: List<Point>?,
        val finalCorners: List<Point>? = null,
        val finalSource: String? = null,
        val edgeVisibilities: List<EdgeVisibility> = emptyList(),
    )

    private data class PaperCandidate(
        val contour: List<Point>,
        val corners: List<Point>?,
        val containment: Double,
        val expansion: Double,
        val transition: Double,
        val ownership: Double,
        val envelopeConsistency: Double,
        val adjacentPagePenalty: Double,
        val secondPaperRegionPenalty: Double,
        val score: Double,
    )

    private data class EdgeAdjustment(
        val offset: Double,
        val evidence: Double,
        val continuity: Double,
        val occlusionPenalty: Double,
        val reliable: Boolean,
        val conservative: Boolean = false,
        val support: Double = 0.0,
    )

    private data class EdgeEvidence(
        val score: Double,
        val support: Double,
        val continuity: Double,
        val occlusionPenalty: Double,
    )

    fun refine(
        source: Mat,
        aiMask: Mat,
        rawCorners: List<Point>,
        pageSide: String?,
    ): Result {
        val totalStart = SystemClock.elapsedRealtime()
        if (source.empty() || aiMask.empty() || rawCorners.size != 4) {
            return failure(Rect(), totalStart, "invalid_refinement_input")
        }

        val analysisScale = min(1.0, MAX_ANALYSIS_EDGE / max(source.cols(), source.rows()).toDouble())
        val analysis = Mat()
        val mask = Mat()
        val lab = Mat()
        val gray = Mat()
        val gradient = Mat()
        try {
            val analysisSize = Size(
                max(1.0, source.cols() * analysisScale),
                max(1.0, source.rows() * analysisScale),
            )
            Imgproc.resize(source, analysis, analysisSize, 0.0, 0.0, Imgproc.INTER_AREA)
            Imgproc.resize(aiMask, mask, analysisSize, 0.0, 0.0, Imgproc.INTER_NEAREST)
            val scaledRaw = rawCorners.map { Point(it.x * analysisScale, it.y * analysisScale) }

            val roiStart = SystemClock.elapsedRealtime()
            val searchRoi = createSearchRoi(mask, scaledRaw, analysis.cols(), analysis.rows())
            val maskToSearchRoiMs = SystemClock.elapsedRealtime() - roiStart

            Imgproc.cvtColor(analysis, lab, Imgproc.COLOR_BGR2Lab)
            Imgproc.cvtColor(analysis, gray, Imgproc.COLOR_BGR2GRAY)
            buildGradient(gray, gradient)

            val rawArea = polygonArea(scaledRaw).coerceAtLeast(1.0)
            val sourceArea = analysis.cols().toDouble() * analysis.rows()
            val rawAreaRatio = rawArea / sourceArea

            val paperStart = SystemClock.elapsedRealtime()
            val paperCandidate = createPaperCandidate(
                analysis = analysis,
                lab = lab,
                gradient = gradient,
                aiMask = mask,
                searchRoi = searchRoi,
                rawArea = rawArea,
                rawCorners = scaledRaw,
                pageSide = pageSide,
            )
            val paperCandidateMs = SystemClock.elapsedRealtime() - paperStart

            val rawAssessment = assessRawPage(
                rawCorners = scaledRaw,
                rawAreaRatio = rawAreaRatio,
                width = analysis.cols(),
                height = analysis.rows(),
                paperCandidate = paperCandidate,
                pageSide = pageSide,
            )
            if (rawAssessment.partial) {
                val sourceSearchRoi = scaleRectToSource(
                    searchRoi,
                    analysisScale,
                    source.cols(),
                    source.rows(),
                )
                return Result(
                    accepted = false,
                    corners = null,
                    searchRoi = sourceSearchRoi,
                    rawAreaRatio = rawAreaRatio,
                    refinedAreaRatio = rawAreaRatio,
                    aiContainmentRatio = 1.0,
                    areaExpansionRatio = 1.0,
                    paperTransitionScore = paperCandidate?.transition ?: 0.0,
                    mainPageOwnershipScore = paperCandidate?.ownership ?: 1.0,
                    outerEnvelopeConsistency = paperCandidate?.envelopeConsistency ?: 0.0,
                    edgeContinuity = 0.0,
                    adjacentPagePenalty = paperCandidate?.adjacentPagePenalty ?: 0.0,
                    occlusionPenalty = 0.0,
                    refinedConfidence = 0.0,
                    refinedStatus = "rejected_partial_raw",
                    maskToSearchRoiMs = maskToSearchRoiMs,
                    paperCandidateMs = paperCandidateMs,
                    edgeRefineMs = 0,
                    cornerEstimateMs = 0,
                    totalRefineMs = SystemClock.elapsedRealtime() - totalStart,
                    failureReason = rawAssessment.reason,
                    paperContour = paperCandidate?.contour?.map {
                        Point(it.x / analysisScale, it.y / analysisScale)
                    },
                    envelopeCorners = paperCandidate?.corners?.map {
                        Point(it.x / analysisScale, it.y / analysisScale)
                    },
                )
            }

            val edgeStart = SystemClock.elapsedRealtime()
            val adjustments = refineEdges(
                rawCorners = scaledRaw,
                lab = lab,
                gradient = gradient,
                paperCandidate = paperCandidate,
                pageSide = pageSide,
            )
            val edgeRefineMs = SystemClock.elapsedRealtime() - edgeStart

            val cornerStart = SystemClock.elapsedRealtime()
            val edgeCorners = intersectShiftedEdges(scaledRaw, adjustments)
            val paperCorners = paperCandidate?.corners
            val candidateCorners = selectConservativeCorners(
                rawCorners = scaledRaw,
                edgeCorners = edgeCorners,
                paperCorners = paperCorners,
                paperCandidate = paperCandidate,
                reliableEdges = adjustments.count { it.reliable },
            )
            val cornerEstimateMs = SystemClock.elapsedRealtime() - cornerStart

            val transition = adjustments.filter { it.reliable }
                .map { it.evidence }
                .ifEmpty { listOf(paperCandidate?.transition ?: 0.0) }
                .average()
                .coerceIn(0.0, 1.0)
            val edgeContinuity = adjustments.map { it.continuity }.average().coerceIn(0.0, 1.0)
            val occlusionPenalty = adjustments.map { it.occlusionPenalty }.average().coerceIn(0.0, 1.0)
            val sanity = validate(
                rawCorners = scaledRaw,
                refinedCorners = candidateCorners,
                aiMask = mask,
                rawArea = rawArea,
                transition = transition,
                reliableEdges = adjustments.count { it.reliable },
                paperCandidate = paperCandidate,
                adjustments = adjustments,
                pageSide = pageSide,
            )
            val outputCorners = if (sanity.accepted) {
                candidateCorners?.map { Point(it.x / analysisScale, it.y / analysisScale) }
            } else {
                null
            }
            val sourceSearchRoi = scaleRectToSource(
                searchRoi,
                analysisScale,
                source.cols(),
                source.rows(),
            )
            val ownership = paperCandidate?.ownership ?: 1.0
            val envelopeConsistency = paperCandidate?.envelopeConsistency ?: edgeContinuity
            val adjacentPenalty = paperCandidate?.adjacentPagePenalty ?: 0.0
            val confidence = refinedConfidence(
                containment = sanity.containment,
                expansion = sanity.expansion,
                transition = transition,
                envelopeConsistency = envelopeConsistency,
                edgeContinuity = edgeContinuity,
                adjacentPenalty = adjacentPenalty,
                occlusionPenalty = occlusionPenalty,
                geometryAccepted = sanity.accepted,
            )
            val status = refinedStatus(
                reason = sanity.reason,
                accepted = sanity.accepted,
                occlusionPenalty = occlusionPenalty,
                refinedConfidence = confidence,
                conservativeExpansion = adjustments.any { it.conservative },
            )
            val edgeVisibilities = classifyEdgeVisibility(
                rawCorners = scaledRaw,
                candidateCorners = candidateCorners,
                adjustments = adjustments,
                width = analysis.cols(),
                height = analysis.rows(),
                lab = lab,
                gradient = gradient,
                aiMask = mask,
                searchRoi = searchRoi,
            )
            val finalBoundary = visibilitySafeBoundary(
                rawCorners = scaledRaw,
                refinedCorners = candidateCorners,
                refinedAccepted = sanity.accepted,
                adjustments = adjustments,
                visibilities = edgeVisibilities,
                aiMask = mask,
                paperCandidate = paperCandidate,
                pageSide = pageSide,
                searchRoi = searchRoi,
            )
            return Result(
                accepted = sanity.accepted,
                corners = outputCorners,
                searchRoi = sourceSearchRoi,
                rawAreaRatio = rawAreaRatio,
                refinedAreaRatio = sanity.refinedArea / sourceArea,
                aiContainmentRatio = sanity.containment,
                areaExpansionRatio = sanity.expansion,
                paperTransitionScore = transition,
                mainPageOwnershipScore = ownership,
                outerEnvelopeConsistency = envelopeConsistency,
                edgeContinuity = edgeContinuity,
                adjacentPagePenalty = adjacentPenalty,
                occlusionPenalty = occlusionPenalty,
                refinedConfidence = confidence,
                refinedStatus = status,
                maskToSearchRoiMs = maskToSearchRoiMs,
                paperCandidateMs = paperCandidateMs,
                edgeRefineMs = edgeRefineMs,
                cornerEstimateMs = cornerEstimateMs,
                totalRefineMs = SystemClock.elapsedRealtime() - totalStart,
                failureReason = sanity.reason,
                paperContour = paperCandidate?.contour?.map {
                    Point(it.x / analysisScale, it.y / analysisScale)
                },
                envelopeCorners = paperCandidate?.corners?.map {
                    Point(it.x / analysisScale, it.y / analysisScale)
                },
                finalCorners = finalBoundary.first?.map {
                    Point(it.x / analysisScale, it.y / analysisScale)
                },
                finalSource = finalBoundary.second,
                edgeVisibilities = edgeVisibilities,
            )
        } catch (error: Throwable) {
            return failure(Rect(), totalStart, error.message ?: "refinement_exception")
        } finally {
            analysis.release()
            mask.release()
            lab.release()
            gray.release()
            gradient.release()
        }
    }

    /**
     * Edge visibility is intentionally independent per side. A missing paper /
     * background transition means "unknown", never permission to crop inward.
     */
    private fun classifyEdgeVisibility(
        rawCorners: List<Point>,
        candidateCorners: List<Point>?,
        adjustments: List<EdgeAdjustment>,
        width: Int,
        height: Int,
        lab: Mat,
        gradient: Mat,
        aiMask: Mat,
        searchRoi: Rect,
    ): List<EdgeVisibility> {
        val names = listOf("top", "right", "bottom", "left")
        val corners = candidateCorners ?: rawCorners
        return names.indices.map { index ->
            val adjustment = adjustments[index]
            val start = corners[index]
            val end = corners[(index + 1) % 4]
            val midpoint = Point((start.x + end.x) / 2.0, (start.y + end.y) / 2.0)
            val borderDistance = when (index) {
                0 -> midpoint.y / height.coerceAtLeast(1)
                1 -> (width - midpoint.x) / width.coerceAtLeast(1)
                2 -> (height - midpoint.y) / height.coerceAtLeast(1)
                else -> midpoint.x / width.coerceAtLeast(1)
            }.coerceIn(0.0, 1.0)
            val confidence = (
                adjustment.evidence * 0.46 +
                    adjustment.support * 0.28 +
                    adjustment.continuity * 0.18 +
                    (1.0 - adjustment.occlusionPenalty) * 0.08
                ).coerceIn(0.0, 1.0)
            val beyond = if (index == 2) {
                analyzeBelowBottom(
                    corners = corners,
                    lab = lab,
                    gradient = gradient,
                    aiMask = aiMask,
                    searchRoi = searchRoi,
                )
            } else {
                BottomBeyondEvidence(false, false)
            }
            val status = when {
                adjustment.occlusionPenalty >= EDGE_OCCLUDED_THRESHOLD -> "occluded"
                index == 2 &&
                    (beyond.foreground || beyond.paperContinues) &&
                    adjustment.evidence < EDGE_CONFIRMED_TRANSITION -> "unknown"
                borderDistance <= EDGE_BORDER_THRESHOLD &&
                    adjustment.evidence < EDGE_CONFIRMED_TRANSITION -> "out_of_frame"
                adjustment.reliable &&
                    adjustment.evidence >= EDGE_CONFIRMED_TRANSITION &&
                    adjustment.support >= EDGE_CONFIRMED_SUPPORT -> "confirmed"
                adjustment.evidence >= EDGE_WEAK_TRANSITION ||
                    adjustment.support >= EDGE_WEAK_SUPPORT -> "weak"
                else -> "unknown"
            }
            EdgeVisibility(
                edge = names[index],
                transitionScore = adjustment.evidence,
                supportingSampleRatio = adjustment.support,
                borderDistance = borderDistance,
                occlusionPenalty = adjustment.occlusionPenalty,
                confidence = confidence,
                status = status,
                foregroundBeyond = beyond.foreground,
                paperContinuesBeyond = beyond.paperContinues,
            )
        }
    }

    private data class BottomBeyondEvidence(
        val foreground: Boolean,
        val paperContinues: Boolean,
    )

    /**
     * Looks only inside the AI ownership/search ROI. Text edges or a bright,
     * low-chroma paper field below a proposed bottom edge prove that the line
     * is not a safe physical page boundary.
     */
    private fun analyzeBelowBottom(
        corners: List<Point>,
        lab: Mat,
        gradient: Mat,
        aiMask: Mat,
        searchRoi: Rect,
    ): BottomBeyondEvidence {
        if (corners.size != 4) return BottomBeyondEvidence(false, false)
        if (searchRoi.width < 2 || searchRoi.height < 2) {
            return BottomBeyondEvidence(false, false)
        }
        val roiRight = searchRoi.x + searchRoi.width
        val left = max(corners[3].x, corners[0].x).roundToInt()
            .coerceIn(searchRoi.x, roiRight - 2)
        val right = min(corners[2].x, corners[1].x).roundToInt()
            .coerceIn(left + 1, roiRight)
        val bottomY = max(corners[2].y, corners[3].y).roundToInt()
        val startY = max(bottomY + 1, searchRoi.y)
        val endY = min(
            searchRoi.y + searchRoi.height,
            bottomY + max(6, (lab.rows() * BOTTOM_ANALYSIS_DEPTH).roundToInt()),
        )
        if (endY <= startY || right <= left) {
            return BottomBeyondEvidence(false, false)
        }
        var samples = 0
        var edgeSamples = 0
        var darkSamples = 0
        var paperSamples = 0
        var maskSamples = 0
        val stride = max(1, min(lab.cols(), lab.rows()) / 320)
        var y = startY
        while (y < endY) {
            var x = left
            while (x < right) {
                val labPixel = lab.get(y, x)
                if (labPixel != null) {
                    samples++
                    if ((gradient.get(y, x)?.firstOrNull() ?: 0.0) >= BOTTOM_EDGE_THRESHOLD) {
                        edgeSamples++
                    }
                    if (labPixel[0] <= BOTTOM_DARK_LUMINANCE) darkSamples++
                    if (labPixel[0] >= BOTTOM_PAPER_LUMINANCE &&
                        abs(labPixel[1] - 128.0) <= BOTTOM_PAPER_CHROMA &&
                        abs(labPixel[2] - 128.0) <= BOTTOM_PAPER_CHROMA
                    ) paperSamples++
                    if ((aiMask.get(y, x)?.firstOrNull() ?: 0.0) > 0.0) maskSamples++
                }
                x += stride
            }
            y += stride
        }
        if (samples == 0) return BottomBeyondEvidence(false, false)
        val foregroundRatio = max(
            max(
                edgeSamples.toDouble() / samples,
                darkSamples.toDouble() / samples,
            ),
            maskSamples.toDouble() / samples,
        )
        val paperRatio = paperSamples.toDouble() / samples
        return BottomBeyondEvidence(
            foreground = foregroundRatio >= BOTTOM_FOREGROUND_RATIO,
            paperContinues = paperRatio >= BOTTOM_PAPER_RATIO,
        )
    }

    /** Builds one production-safe polygon by combining the best evidence per edge. */
    private fun visibilitySafeBoundary(
        rawCorners: List<Point>,
        refinedCorners: List<Point>?,
        refinedAccepted: Boolean,
        adjustments: List<EdgeAdjustment>,
        visibilities: List<EdgeVisibility>,
        aiMask: Mat,
        paperCandidate: PaperCandidate?,
        pageSide: String?,
        searchRoi: Rect,
    ): Pair<List<Point>?, String?> {
        if ((paperCandidate?.ownership ?: 1.0) < MIN_MAIN_PAGE_OWNERSHIP ||
            (paperCandidate?.adjacentPagePenalty ?: 0.0) >= ADJACENT_REJECTION_THRESHOLD
        ) return Pair(null, null)

        if (refinedAccepted && refinedCorners != null &&
            visibilities.all { it.status == "confirmed" }
        ) return Pair(refinedCorners, "ai_refined")

        val minDimension = min(aiMask.cols(), aiMask.rows()).toDouble()
        val safeAdjustments = adjustments.mapIndexed { index, adjustment ->
            val visibility = visibilities[index]
            val spineEdge = (pageSide == "left" && index == 1) ||
                (pageSide == "right" && index == 3)
            val sourceMaximum = minDimension * if (spineEdge) SPINE_OUTWARD_LIMIT else OUTWARD_LIMIT
            val start = rawCorners[index]
            val end = rawCorners[(index + 1) % 4]
            val midpoint = Point((start.x + end.x) / 2.0, (start.y + end.y) / 2.0)
            val roiOutward = when (index) {
                0 -> midpoint.y - searchRoi.y
                1 -> searchRoi.x + searchRoi.width - midpoint.x
                2 -> searchRoi.y + searchRoi.height - midpoint.y
                else -> midpoint.x - searchRoi.x
            }.coerceAtLeast(0.0)
            val frameOutward = when (index) {
                0 -> midpoint.y
                1 -> aiMask.cols() - midpoint.x
                2 -> aiMask.rows() - midpoint.y
                else -> midpoint.x
            }.coerceAtLeast(0.0)
            val maximum = when {
                spineEdge -> sourceMaximum
                visibility.status == "out_of_frame" -> max(sourceMaximum, frameOutward)
                index == 2 &&
                    (visibility.foregroundBeyond || visibility.paperContinuesBeyond) ->
                    max(sourceMaximum, roiOutward)
                else -> sourceMaximum
            }
            val minimumSafe = minDimension * when (visibility.status) {
                "confirmed" -> 0.0
                "weak" -> if (index == 2) BOTTOM_WEAK_SAFE_MARGIN else WEAK_SAFE_MARGIN
                "occluded" -> if (index == 2) BOTTOM_UNKNOWN_SAFE_MARGIN else OCCLUDED_SAFE_MARGIN
                "out_of_frame" -> if (index == 2) BOTTOM_UNKNOWN_SAFE_MARGIN else UNKNOWN_SAFE_MARGIN
                else -> if (index == 2) BOTTOM_UNKNOWN_SAFE_MARGIN else UNKNOWN_SAFE_MARGIN
            }
            adjustment.copy(offset = max(adjustment.offset, minimumSafe).coerceAtMost(maximum))
        }
        val hasRefinementEvidence = paperCandidate != null || visibilities.any {
            it.status == "confirmed" || it.status == "weak" || it.status == "occluded"
        }
        if (hasRefinementEvidence) {
            val hybrid = clampToSource(
                intersectShiftedEdges(rawCorners, safeAdjustments),
                aiMask.cols(),
                aiMask.rows(),
            )
            if (isVisibilitySafeGeometry(rawCorners, hybrid, aiMask)) {
                return Pair(hybrid, "ai_hybrid")
            }
        }

        // A sane raw AI polygon remains useful, but receives proportional
        // outward padding (largest at the bottom) before production cropping.
        val rawFallbackOffsets = listOf(
            WEAK_SAFE_MARGIN,
            WEAK_SAFE_MARGIN,
            BOTTOM_UNKNOWN_SAFE_MARGIN,
            WEAK_SAFE_MARGIN,
        ).mapIndexed { index, ratio ->
            val spineEdge = (pageSide == "left" && index == 1) ||
                (pageSide == "right" && index == 3)
            EdgeAdjustment(
                offset = minDimension * if (spineEdge) min(ratio, SPINE_OUTWARD_LIMIT) else ratio,
                evidence = 0.0,
                continuity = 0.0,
                occlusionPenalty = 0.0,
                reliable = false,
            )
        }
        val rawFallback = clampToSource(
            intersectShiftedEdges(rawCorners, rawFallbackOffsets),
            aiMask.cols(),
            aiMask.rows(),
        )
        return if (isVisibilitySafeGeometry(rawCorners, rawFallback, aiMask)) {
            Pair(rawFallback, "ai_raw_fallback")
        } else {
            Pair(null, null)
        }
    }

    private fun clampToSource(
        corners: List<Point>?,
        width: Int,
        height: Int,
    ): List<Point>? = corners?.map { point ->
        Point(
            point.x.coerceIn(0.0, width.toDouble()),
            point.y.coerceIn(0.0, height.toDouble()),
        )
    }

    private fun isVisibilitySafeGeometry(
        rawCorners: List<Point>,
        candidate: List<Point>?,
        aiMask: Mat,
    ): Boolean {
        if (candidate == null || candidate.size != 4 || candidate.any {
                !it.x.isFinite() || !it.y.isFinite() ||
                    it.x !in 0.0..aiMask.cols().toDouble() ||
                    it.y !in 0.0..aiMask.rows().toDouble()
            }
        ) return false
        val contour = MatOfPoint(*candidate.toTypedArray())
        return try {
            val ratio = polygonArea(candidate) / polygonArea(rawCorners).coerceAtLeast(1.0)
            Imgproc.isContourConvex(contour) && ratio in FINAL_MIN_AREA_RATIO..FINAL_MAX_AREA_RATIO
        } finally {
            contour.release()
        }
    }

    private data class Sanity(
        val accepted: Boolean,
        val reason: String?,
        val refinedArea: Double,
        val containment: Double,
        val expansion: Double,
    )

    private data class RawPageAssessment(
        val partial: Boolean,
        val reason: String? = null,
    )

    private fun assessRawPage(
        rawCorners: List<Point>,
        rawAreaRatio: Double,
        width: Int,
        height: Int,
        paperCandidate: PaperCandidate?,
        pageSide: String?,
    ): RawPageAssessment {
        val bounds = boundingRect(rawCorners)
        val horizontalExtent = bounds.width.toDouble() / width.coerceAtLeast(1)
        val verticalExtent = bounds.height.toDouble() / height.coerceAtLeast(1)
        val bottomProximity = (bounds.y + bounds.height).toDouble() / height.coerceAtLeast(1)
        val polygon = MatOfPoint2f(*rawCorners.toTypedArray())
        val coversCenter = try {
            Imgproc.pointPolygonTest(
                polygon,
                Point(width / 2.0, height / 2.0),
                false,
            ) >= 0.0
        } finally {
            polygon.release()
        }
        val rectangularity = polygonArea(rawCorners) /
            (bounds.width.toDouble() * bounds.height).coerceAtLeast(1.0)
        val insetOnAllSides = bounds.x > width * 0.06 &&
            bounds.y > height * 0.06 &&
            bounds.x + bounds.width < width * 0.94 &&
            bounds.y + bounds.height < height * 0.90
        val largeInternalRectangle = rectangularity >= 0.84 &&
            insetOnAllSides &&
            (paperCandidate?.expansion ?: 1.0) >= PARTIAL_RAW_PAPER_EXPANSION
        val severeExtent = horizontalExtent < MIN_RAW_HORIZONTAL_EXTENT ||
            verticalExtent < MIN_RAW_VERTICAL_EXTENT
        val contextHorizontalLimit = if (pageSide == null) 0.72 else 0.64
        val detachedInternal = largeInternalRectangle &&
            horizontalExtent < contextHorizontalLimit &&
            verticalExtent < 0.70 &&
            bottomProximity < 0.78
        val tinyOffCenter = rawAreaRatio < MIN_RAW_AREA_RATIO &&
            !coversCenter && verticalExtent < 0.52
        return if (severeExtent || detachedInternal || tinyOffCenter) {
            RawPageAssessment(true, "partial_ai_raw")
        } else {
            RawPageAssessment(false)
        }
    }

    private fun scaleRectToSource(
        value: Rect,
        scale: Double,
        sourceWidth: Int,
        sourceHeight: Int,
    ): Rect {
        val left = floor(value.x / scale).toInt().coerceIn(0, sourceWidth - 1)
        val top = floor(value.y / scale).toInt().coerceIn(0, sourceHeight - 1)
        return Rect(
            left,
            top,
            ceil(value.width / scale).toInt().coerceIn(1, sourceWidth - left),
            ceil(value.height / scale).toInt().coerceIn(1, sourceHeight - top),
        )
    }

    private fun createSearchRoi(
        aiMask: Mat,
        rawCorners: List<Point>,
        width: Int,
        height: Int,
    ): Rect {
        val nonZero = MatOfPoint()
        return try {
            Core.findNonZero(aiMask, nonZero)
            val base = if (nonZero.empty()) {
                boundingRect(rawCorners)
            } else {
                Imgproc.boundingRect(nonZero)
            }
            val expandX = max(base.width * SEARCH_EXPANSION_X, width * MIN_SEARCH_EXPANSION).roundToInt()
            val expandY = max(base.height * SEARCH_EXPANSION_Y, height * MIN_SEARCH_EXPANSION).roundToInt()
            val left = (base.x - expandX).coerceAtLeast(0)
            val top = (base.y - expandY).coerceAtLeast(0)
            val right = (base.x + base.width + expandX).coerceAtMost(width)
            val bottom = (base.y + base.height + expandY).coerceAtMost(height)
            Rect(left, top, max(1, right - left), max(1, bottom - top))
        } finally {
            nonZero.release()
        }
    }

    private fun createPaperCandidate(
        analysis: Mat,
        lab: Mat,
        gradient: Mat,
        aiMask: Mat,
        searchRoi: Rect,
        rawArea: Double,
        rawCorners: List<Point>,
        pageSide: String?,
    ): PaperCandidate? {
        val roiLab = lab.submat(searchRoi)
        val roiGradient = gradient.submat(searchRoi)
        val aiRoi = aiMask.submat(searchRoi)
        val channels = mutableListOf<Mat>()
        val bright = Mat()
        val lowChroma = Mat()
        val paper = Mat()
        val ownershipPrior = Mat()
        val ownedPaper = Mat()
        val hierarchy = Mat()
        val contours = mutableListOf<MatOfPoint>()
        val paperHierarchy = Mat()
        val paperContours = mutableListOf<MatOfPoint>()
        val paperCopy = Mat()
        try {
            Core.split(roiLab, channels)
            Imgproc.threshold(channels[0], bright, 0.0, 255.0, Imgproc.THRESH_BINARY + Imgproc.THRESH_OTSU)
            Core.inRange(roiLab, Scalar(0.0, 82.0, 82.0), Scalar(255.0, 174.0, 174.0), lowChroma)
            Core.bitwise_and(bright, lowChroma, paper)
            val kernelSize = oddKernel(max(3, min(searchRoi.width, searchRoi.height) / 70))
            val kernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_ELLIPSE,
                Size(kernelSize.toDouble(), kernelSize.toDouble()),
            )
            try {
                Imgproc.morphologyEx(paper, paper, Imgproc.MORPH_CLOSE, kernel)
                Imgproc.morphologyEx(paper, paper, Imgproc.MORPH_OPEN, kernel)
            } finally {
                kernel.release()
            }
            val ownershipKernelSize = oddKernel(max(5, min(searchRoi.width, searchRoi.height) / 9))
            val ownershipKernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_ELLIPSE,
                Size(ownershipKernelSize.toDouble(), ownershipKernelSize.toDouble()),
            )
            try {
                Imgproc.dilate(aiRoi, ownershipPrior, ownershipKernel)
                Core.bitwise_and(paper, ownershipPrior, ownedPaper)
            } finally {
                ownershipKernel.release()
            }
            Imgproc.findContours(ownedPaper, contours, hierarchy, Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_SIMPLE)
            val aiPixels = Core.countNonZero(aiRoi).toDouble().coerceAtLeast(1.0)
            val aiMoments = Imgproc.moments(aiRoi, true)
            val centroid = if (abs(aiMoments.m00) > 1e-6) {
                Point(aiMoments.m10 / aiMoments.m00, aiMoments.m01 / aiMoments.m00)
            } else {
                Point(searchRoi.width / 2.0, searchRoi.height / 2.0)
            }
            paper.copyTo(paperCopy)
            Imgproc.findContours(
                paperCopy,
                paperContours,
                paperHierarchy,
                Imgproc.RETR_EXTERNAL,
                Imgproc.CHAIN_APPROX_SIMPLE,
            )
            val secondPaperPenalty = secondPaperRegionPenalty(
                contours = paperContours,
                aiCentroid = centroid,
                roiSize = searchRoi.size(),
                pageSide = pageSide,
            )
            val rawBounds = boundingRect(rawCorners).let {
                Rect(it.x - searchRoi.x, it.y - searchRoi.y, it.width, it.height)
            }
            return contours.mapNotNull { contour ->
                val area = abs(Imgproc.contourArea(contour))
                val expansion = area / rawArea
                if (expansion !in MIN_PAPER_AREA_RATIO..MAX_PAPER_AREA_RATIO) return@mapNotNull null
                val curve = MatOfPoint2f(*contour.toArray())
                val ownsCentroid = try {
                    Imgproc.pointPolygonTest(curve, centroid, false) >= 0.0
                } finally {
                    curve.release()
                }
                if (!ownsCentroid) return@mapNotNull null

                val candidateMask = Mat.zeros(searchRoi.size(), CvType.CV_8UC1)
                val intersection = Mat()
                val contourEdge = Mat.zeros(searchRoi.size(), CvType.CV_8UC1)
                try {
                    Imgproc.drawContours(candidateMask, listOf(contour), 0, Scalar(255.0), Imgproc.FILLED)
                    Core.bitwise_and(candidateMask, aiRoi, intersection)
                    val containment = Core.countNonZero(intersection) / aiPixels
                    if (containment < MIN_PAPER_CONTAINMENT) return@mapNotNull null
                    val candidatePixels = Core.countNonZero(candidateMask).toDouble().coerceAtLeast(1.0)
                    val aiIntersection = Core.countNonZero(intersection).toDouble()
                    val componentIntersection = (aiIntersection / candidatePixels).coerceIn(0.0, 1.0)
                    val candidateMoments = Imgproc.moments(candidateMask, true)
                    val candidateCentroid = if (abs(candidateMoments.m00) > 1e-6) {
                        Point(candidateMoments.m10 / candidateMoments.m00, candidateMoments.m01 / candidateMoments.m00)
                    } else {
                        centroid
                    }
                    val centroidDistance = hypot(
                        candidateCentroid.x - centroid.x,
                        candidateCentroid.y - centroid.y,
                    ) / hypot(searchRoi.width.toDouble(), searchRoi.height.toDouble()).coerceAtLeast(1.0)
                    val centroidProximity = (1.0 - centroidDistance / MAX_OWNERSHIP_CENTROID_DISTANCE)
                        .coerceIn(0.0, 1.0)
                    val ownership =
                        containment * 0.55 + centroidProximity * 0.25 + componentIntersection * 0.20
                    if (ownership < MIN_MAIN_PAGE_OWNERSHIP) return@mapNotNull null
                    Imgproc.drawContours(contourEdge, listOf(contour), 0, Scalar(255.0), 2)
                    val transition = (Core.mean(roiGradient, contourEdge).`val`[0] / 96.0).coerceIn(0.0, 1.0)
                    val expansionScore = (1.0 - abs(expansion - IDEAL_PAPER_EXPANSION) / 0.75).coerceIn(0.0, 1.0)
                    val candidateBounds = Imgproc.boundingRect(contour)
                    val baseAdjacentPenalty = adjacentPagePenalty(
                        expansion = expansion,
                        candidateBounds = candidateBounds,
                        rawBounds = rawBounds,
                        candidateMask = candidateMask,
                        aiCentroid = centroid,
                        pageSide = pageSide,
                    )
                    val expansionRisk = ((expansion - 1.12) / 0.34).coerceIn(0.0, 1.0)
                    val adjacentPenalty = max(
                        baseAdjacentPenalty,
                        secondPaperPenalty * expansionRisk,
                    )
                    val globalContour = contour.toArray().map {
                        Point(it.x + searchRoi.x, it.y + searchRoi.y)
                    }
                    val envelope = estimateOuterEnvelopeCorners(
                        contour = globalContour,
                        rawCorners = rawCorners,
                        width = analysis.cols(),
                        height = analysis.rows(),
                        pageSide = pageSide,
                    )
                    val envelopeConsistency = envelopeConsistency(globalContour, envelope)
                    PaperCandidate(
                        contour = globalContour,
                        corners = envelope,
                        containment = containment,
                        expansion = expansion,
                        transition = transition,
                        ownership = ownership,
                        envelopeConsistency = envelopeConsistency,
                        adjacentPagePenalty = adjacentPenalty,
                        secondPaperRegionPenalty = secondPaperPenalty,
                        score = (
                            containment * 0.31 +
                                ownership * 0.24 +
                                expansionScore * 0.13 +
                                transition * 0.16 +
                                envelopeConsistency * 0.16 -
                                adjacentPenalty * 0.45
                            ).coerceIn(0.0, 1.0),
                    )
                } finally {
                    candidateMask.release()
                    intersection.release()
                    contourEdge.release()
                }
            }.maxByOrNull { it.score }
        } finally {
            roiLab.release()
            roiGradient.release()
            aiRoi.release()
            channels.forEach(Mat::release)
            bright.release()
            lowChroma.release()
            paper.release()
            ownershipPrior.release()
            ownedPaper.release()
            hierarchy.release()
            contours.forEach(Mat::release)
            paperHierarchy.release()
            paperContours.forEach(Mat::release)
            paperCopy.release()
        }
    }

    private fun secondPaperRegionPenalty(
        contours: List<MatOfPoint>,
        aiCentroid: Point,
        roiSize: Size,
        pageSide: String?,
    ): Double {
        if (contours.size < 2) return 0.0
        val roiArea = (roiSize.width * roiSize.height).coerceAtLeast(1.0)
        val components = contours.mapNotNull { contour ->
            val area = abs(Imgproc.contourArea(contour))
            if (area / roiArea < SECOND_PAPER_MIN_AREA) return@mapNotNull null
            val moments = Imgproc.moments(contour)
            if (abs(moments.m00) < 1e-6) return@mapNotNull null
            Triple(contour, area, Point(moments.m10 / moments.m00, moments.m01 / moments.m00))
        }
        if (components.size < 2) return 0.0
        val main = components.minByOrNull { (_, _, center) ->
            hypot(center.x - aiCentroid.x, center.y - aiCentroid.y)
        } ?: return 0.0
        val second = components.filter { it.first !== main.first }.maxByOrNull { it.second }
            ?: return 0.0
        val areaRatio = (second.second / main.second.coerceAtLeast(1.0)).coerceIn(0.0, 1.0)
        val onSpineSide = when (pageSide) {
            "left" -> second.third.x > main.third.x
            "right" -> second.third.x < main.third.x
            else -> abs(second.third.x - main.third.x) > roiSize.width * 0.18
        }
        if (!onSpineSide) return areaRatio * 0.25
        val separation = (abs(second.third.x - main.third.x) / roiSize.width.coerceAtLeast(1.0))
            .coerceIn(0.0, 1.0)
        return (areaRatio * 0.72 + separation * 0.28).coerceIn(0.0, 1.0)
    }

    private fun adjacentPagePenalty(
        expansion: Double,
        candidateBounds: Rect,
        rawBounds: Rect,
        candidateMask: Mat,
        aiCentroid: Point,
        pageSide: String?,
    ): Double {
        val rawWidth = rawBounds.width.toDouble().coerceAtLeast(1.0)
        val leftOvershoot = max(0.0, (rawBounds.x - candidateBounds.x).toDouble()) / rawWidth
        val rightOvershoot = max(
            0.0,
            (candidateBounds.x + candidateBounds.width - (rawBounds.x + rawBounds.width)).toDouble(),
        ) / rawWidth
        val spineOvershoot = when (pageSide) {
            "left" -> rightOvershoot
            "right" -> leftOvershoot
            else -> min(leftOvershoot, rightOvershoot) * 0.45
        }
        val growthPenalty = ((expansion - ADJACENT_GROWTH_START) / ADJACENT_GROWTH_RANGE)
            .coerceIn(0.0, 1.0)
        val valleyPenalty = narrowConnectionPenalty(candidateMask, aiCentroid, pageSide)
        return (growthPenalty * 0.42 +
            (spineOvershoot / MAX_SAFE_SPINE_OVERSHOOT).coerceIn(0.0, 1.0) * 0.38 +
            valleyPenalty * 0.20).coerceIn(0.0, 1.0)
    }

    private fun narrowConnectionPenalty(
        candidateMask: Mat,
        centroid: Point,
        pageSide: String?,
    ): Double {
        if (pageSide == null || candidateMask.empty()) return 0.0
        val start = centroid.x.roundToInt().coerceIn(0, candidateMask.cols() - 1)
        val end = if (pageSide == "left") candidateMask.cols() - 1 else 0
        val direction = if (end >= start) 1 else -1
        val counts = mutableListOf<Double>()
        var column = start
        while (column != end) {
            val view = candidateMask.col(column)
            try {
                counts += Core.countNonZero(view).toDouble()
            } finally {
                view.release()
            }
            column += direction
        }
        if (counts.size < 8) return 0.0
        val trim = max(1, (counts.size * 0.12).roundToInt())
        val core = counts.drop(trim).dropLast(trim)
        if (core.size < 4) return 0.0
        val reference = percentile(core, 0.75).coerceAtLeast(1.0)
        val minimum = percentile(core, 0.10)
        return (1.0 - minimum / reference).coerceIn(0.0, 1.0)
    }

    /**
     * Fits an outward-biased envelope from robust contour projections. Local
     * indentations (finger/clip/print) cannot become a page edge because each
     * edge uses a high percentile instead of one extreme or one segment.
     */
    private fun estimateOuterEnvelopeCorners(
        contour: List<Point>,
        rawCorners: List<Point>,
        width: Int,
        height: Int,
        pageSide: String? = null,
    ): List<Point>? {
        if (contour.size < 4 || rawCorners.size != 4) return null
        val minDimension = min(width, height).toDouble()
        val offsets = rawCorners.indices.map { index ->
            val start = rawCorners[index]
            val end = rawCorners[(index + 1) % 4]
            val dx = end.x - start.x
            val dy = end.y - start.y
            val length = hypot(dx, dy).coerceAtLeast(1.0)
            val tangent = Point(dx / length, dy / length)
            val outward = Point(tangent.y, -tangent.x)
            val projections = contour.mapNotNull { point ->
                val along = (point.x - start.x) * tangent.x + (point.y - start.y) * tangent.y
                if (along !in -length * ENVELOPE_END_TOLERANCE..length * (1.0 + ENVELOPE_END_TOLERANCE)) {
                    null
                } else {
                    (point.x - start.x) * outward.x + (point.y - start.y) * outward.y
                }
            }.filter { it >= 0.0 }
            val spine = (pageSide == "left" && index == 1) || (pageSide == "right" && index == 3)
            val limit = minDimension * if (spine) SPINE_OUTWARD_LIMIT else OUTWARD_LIMIT
            if (projections.isEmpty()) 0.0 else percentile(projections, ENVELOPE_PERCENTILE).coerceIn(0.0, limit)
        }
        val adjustments = offsets.map { EdgeAdjustment(it, 1.0, 1.0, 0.0, true) }
        return intersectShiftedEdges(rawCorners, adjustments)?.let {
            orderCorners(it, width, height)
        }
    }

    private fun envelopeConsistency(contour: List<Point>, corners: List<Point>?): Double {
        if (corners == null || contour.size < 8) return 0.0
        val edgeScores = corners.indices.map { index ->
            val start = corners[index]
            val end = corners[(index + 1) % 4]
            val length = hypot(end.x - start.x, end.y - start.y).coerceAtLeast(1.0)
            val distances = contour.map { point ->
                abs((end.y - start.y) * point.x - (end.x - start.x) * point.y + end.x * start.y - end.y * start.x) / length
            }
            val scale = percentile(distances, 0.75).coerceAtLeast(1.0)
            val near = distances.count { it <= scale * 0.45 }.toDouble() / distances.size
            near.coerceIn(0.0, 1.0)
        }
        return edgeScores.average().coerceIn(0.0, 1.0)
    }

    private fun refineEdges(
        rawCorners: List<Point>,
        lab: Mat,
        gradient: Mat,
        paperCandidate: PaperCandidate?,
        pageSide: String?,
    ): List<EdgeAdjustment> {
        val minDimension = min(lab.cols(), lab.rows()).toDouble()
        return rawCorners.indices.map { index ->
            val start = rawCorners[index]
            val end = rawCorners[(index + 1) % rawCorners.size]
            val length = hypot(end.x - start.x, end.y - start.y).coerceAtLeast(1.0)
            val normal = Point((end.y - start.y) / length, -(end.x - start.x) / length)
            val spineEdge = (pageSide == "left" && index == 1) || (pageSide == "right" && index == 3)
            val maxOutward = minDimension * if (spineEdge) SPINE_OUTWARD_LIMIT else OUTWARD_LIMIT
            val step = max(1.0, minDimension * SEARCH_STEP)
            val probe = max(2.0, minDimension * PROBE_DISTANCE)
            val evidenceCandidates = mutableListOf<EdgeAdjustment>()
            var offset = 0.0
            while (offset <= maxOutward + 0.1) {
                val evidence = edgeEvidence(start, end, normal, offset, probe, lab, gradient)
                if (evidence.support >= MIN_EDGE_SUPPORT) {
                    val outwardPreference = max(0.0, offset / maxOutward) * 0.04
                    evidenceCandidates += EdgeAdjustment(
                        offset,
                        (evidence.score + outwardPreference).coerceIn(0.0, 1.0),
                        evidence.continuity,
                        evidence.occlusionPenalty,
                        evidence.score >= MIN_EDGE_EVIDENCE &&
                            evidence.occlusionPenalty <= MAX_ACCEPTED_EDGE_OCCLUSION,
                        support = evidence.support,
                    )
                }
                offset += step
            }
            var best = evidenceCandidates.maxByOrNull { it.evidence }
                ?: EdgeAdjustment(0.0, 0.0, 0.0, 1.0, false)
            val paperOffset = paperCandidate?.corners?.let {
                val paperStart = it[index]
                val paperEnd = it[(index + 1) % it.size]
                val rawMid = Point((start.x + end.x) / 2.0, (start.y + end.y) / 2.0)
                val paperMid = Point((paperStart.x + paperEnd.x) / 2.0, (paperStart.y + paperEnd.y) / 2.0)
                (paperMid.x - rawMid.x) * normal.x + (paperMid.y - rawMid.y) * normal.y
            }
            if (paperOffset != null && paperOffset in 0.0..maxOutward &&
                paperCandidate.score >= MIN_PAPER_SCORE &&
                paperCandidate.expansion <= MAX_PAPER_CORNER_EXPANSION
            ) {
                val paperEvidence = edgeEvidence(start, end, normal, paperOffset, probe, lab, gradient)
                if (paperEvidence.score >= MIN_EDGE_EVIDENCE * 0.8 &&
                    (best.reliable.not() || paperOffset > best.offset - step * 2)
                ) {
                    best = EdgeAdjustment(
                        offset = max(paperOffset, minDimension * MIN_OUTER_MARGIN),
                        evidence = max(best.evidence, paperEvidence.score),
                        continuity = max(best.continuity, paperEvidence.continuity),
                        occlusionPenalty = min(best.occlusionPenalty, paperEvidence.occlusionPenalty),
                        reliable = paperEvidence.occlusionPenalty <= MAX_ACCEPTED_EDGE_OCCLUSION,
                        support = max(best.support, paperEvidence.support),
                    )
                }
            }
            // A partial object over the bottom edge must not pull the boundary
            // inward. Keep the raw baseline or the stable paper envelope.
            if (index == 2 && best.occlusionPenalty > MAX_ACCEPTED_EDGE_OCCLUSION) {
                val safePaperOffset = paperOffset?.takeIf {
                    it in 0.0..maxOutward &&
                        (paperCandidate?.adjacentPagePenalty ?: 1.0) < 0.45
                }
                best = if (safePaperOffset != null) {
                    EdgeAdjustment(
                        safePaperOffset,
                        paperCandidate?.transition ?: 0.0,
                        paperCandidate?.envelopeConsistency ?: 0.0,
                        best.occlusionPenalty,
                        paperCandidate?.score ?: 0.0 >= MIN_PAPER_SCORE,
                        support = best.support,
                    )
                } else {
                    EdgeAdjustment(
                        0.0,
                        best.evidence,
                        best.continuity,
                        best.occlusionPenalty,
                        false,
                        support = best.support,
                    )
                }
            }
            val adjacentRisk = (paperCandidate?.adjacentPagePenalty ?: 0.0) *
                if (spineEdge) 1.0 else 0.58
            val transitionFactor = ((best.evidence - MIN_ACCEPTED_TRANSITION) /
                EDGE_TRANSITION_RANGE).coerceIn(0.0, 1.0)
            val ownershipFactor = (((paperCandidate?.ownership ?: 1.0) - MIN_MAIN_PAGE_OWNERSHIP) /
                (1.0 - MIN_MAIN_PAGE_OWNERSHIP)).coerceIn(0.0, 1.0)
            val safety = (
                transitionFactor * 0.42 +
                    best.continuity.coerceIn(0.0, 1.0) * 0.18 +
                    ownershipFactor * 0.20 +
                    (1.0 - adjacentRisk.coerceIn(0.0, 1.0)) * 0.14 +
                    (1.0 - best.occlusionPenalty.coerceIn(0.0, 1.0)) * 0.06
                ).coerceIn(0.0, 1.0)
            val allowedOffset = maxOutward * safety
            val appliedOffset = min(best.offset, allowedOffset)
            best.copy(
                offset = appliedOffset,
                reliable = best.reliable &&
                    (paperCandidate?.ownership ?: 1.0) >= MIN_MAIN_PAGE_OWNERSHIP &&
                    adjacentRisk < ADJACENT_REJECTION_THRESHOLD,
                conservative = appliedOffset + 0.1 < best.offset,
            )
        }
    }

    /** Returns robust evidence and the fraction of supporting sample points. */
    private fun edgeEvidence(
        start: Point,
        end: Point,
        outward: Point,
        offset: Double,
        probe: Double,
        lab: Mat,
        gradient: Mat,
    ): EdgeEvidence {
        val scores = mutableListOf<Double>()
        val insideSamples = mutableListOf<DoubleArray>()
        var supports = 0
        for (sample in 1..EDGE_SAMPLES) {
            val t = sample.toDouble() / (EDGE_SAMPLES + 1)
            val x = start.x + (end.x - start.x) * t + outward.x * offset
            val y = start.y + (end.y - start.y) * t + outward.y * offset
            val inside = sampleLab(lab, x - outward.x * probe, y - outward.y * probe) ?: continue
            val outside = sampleLab(lab, x + outward.x * probe, y + outward.y * probe) ?: continue
            val gx = x.roundToInt().coerceIn(0, gradient.cols() - 1)
            val gy = y.roundToInt().coerceIn(0, gradient.rows() - 1)
            val edge = (gradient.get(gy, gx)?.firstOrNull() ?: 0.0) / 96.0
            val delta = sqrt(
                (inside[0] - outside[0]) * (inside[0] - outside[0]) +
                    (inside[1] - outside[1]) * (inside[1] - outside[1]) +
                    (inside[2] - outside[2]) * (inside[2] - outside[2]),
            ) / 58.0
            val luminance = abs(inside[0] - outside[0]) / 52.0
            val score = (delta * 0.50 + luminance * 0.25 + edge * 0.25).coerceIn(0.0, 1.0)
            scores += score
            insideSamples += inside
            if (score >= MIN_SAMPLE_EVIDENCE) supports++
        }
        if (scores.isEmpty()) return EdgeEvidence(0.0, 0.0, 0.0, 1.0)
        val medianScore = median(scores)
        val scoreMad = median(scores.map { abs(it - medianScore) }).coerceAtLeast(0.025)
        val luminanceMedian = median(insideSamples.map { it[0] })
        val chromaMedianA = median(insideSamples.map { it[1] })
        val chromaMedianB = median(insideSamples.map { it[2] })
        val colorDistances = insideSamples.map {
            sqrt(
                (it[0] - luminanceMedian) * (it[0] - luminanceMedian) +
                    (it[1] - chromaMedianA) * (it[1] - chromaMedianA) +
                    (it[2] - chromaMedianB) * (it[2] - chromaMedianB),
            )
        }
        val colorMedian = median(colorDistances)
        val colorMad = median(colorDistances.map { abs(it - colorMedian) }).coerceAtLeast(2.0)
        val inliers = scores.indices.filter { index ->
            abs(scores[index] - medianScore) <= scoreMad * ROBUST_MAD_LIMIT &&
                colorDistances[index] <= colorMedian + colorMad * ROBUST_MAD_LIMIT
        }
        val robustScores = inliers.map { scores[it] }.sorted()
        val robustScore = trimmedMean(robustScores, EDGE_TRIM_FRACTION)
        val discontinuities = inliers.zipWithNext().count { (first, second) ->
            abs(scores[first] - scores[second]) > MAX_LOCAL_SCORE_JUMP
        }
        val outlierRatio = 1.0 - inliers.size.toDouble() / scores.size
        val discontinuityRatio = if (inliers.size < 2) 1.0 else discontinuities.toDouble() / (inliers.size - 1)
        val occlusionPenalty = (outlierRatio * 0.70 + discontinuityRatio * 0.30).coerceIn(0.0, 1.0)
        val continuity = (1.0 - discontinuityRatio).coerceIn(0.0, 1.0)
        return EdgeEvidence(
            score = robustScore,
            support = supports.toDouble() / scores.size,
            continuity = continuity,
            occlusionPenalty = occlusionPenalty,
        )
    }

    private fun sampleLab(image: Mat, x: Double, y: Double): DoubleArray? {
        val ix = x.roundToInt()
        val iy = y.roundToInt()
        if (ix !in 1 until image.cols() - 1 || iy !in 1 until image.rows() - 1) return null
        val total = DoubleArray(3)
        var count = 0
        for (row in iy - 1..iy + 1) {
            for (column in ix - 1..ix + 1) {
                val value = image.get(row, column) ?: continue
                for (channel in 0..2) total[channel] += value[channel]
                count++
            }
        }
        if (count == 0) return null
        for (channel in 0..2) total[channel] /= count
        return total
    }

    private fun intersectShiftedEdges(
        corners: List<Point>,
        adjustments: List<EdgeAdjustment>,
    ): List<Point>? {
        if (corners.size != 4 || adjustments.size != 4) return null
        val shifted = corners.indices.map { index ->
            val start = corners[index]
            val end = corners[(index + 1) % corners.size]
            val length = hypot(end.x - start.x, end.y - start.y).coerceAtLeast(1.0)
            val normal = Point((end.y - start.y) / length, -(end.x - start.x) / length)
            val offset = adjustments[index].offset
            Pair(
                Point(start.x + normal.x * offset, start.y + normal.y * offset),
                Point(end.x + normal.x * offset, end.y + normal.y * offset),
            )
        }
        return corners.indices.map { index ->
            lineIntersection(shifted[(index + 3) % 4], shifted[index]) ?: return null
        }
    }

    private fun lineIntersection(first: Pair<Point, Point>, second: Pair<Point, Point>): Point? {
        val x1 = first.first.x
        val y1 = first.first.y
        val x2 = first.second.x
        val y2 = first.second.y
        val x3 = second.first.x
        val y3 = second.first.y
        val x4 = second.second.x
        val y4 = second.second.y
        val denominator = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
        if (abs(denominator) < 1e-6) return null
        val determinant1 = x1 * y2 - y1 * x2
        val determinant2 = x3 * y4 - y3 * x4
        return Point(
            (determinant1 * (x3 - x4) - (x1 - x2) * determinant2) / denominator,
            (determinant1 * (y3 - y4) - (y1 - y2) * determinant2) / denominator,
        )
    }

    private fun selectConservativeCorners(
        rawCorners: List<Point>,
        edgeCorners: List<Point>?,
        paperCorners: List<Point>?,
        paperCandidate: PaperCandidate?,
        reliableEdges: Int,
    ): List<Point>? {
        if (edgeCorners != null && reliableEdges >= MIN_RELIABLE_EDGES) return edgeCorners
        if (paperCorners != null && paperCandidate != null &&
            paperCandidate.score >= MIN_PAPER_SCORE &&
            paperCandidate.expansion <= MAX_PAPER_CORNER_EXPANSION
        ) {
            return paperCorners
        }
        return if (edgeCorners != null && polygonArea(edgeCorners) >= polygonArea(rawCorners) * 0.98) {
            edgeCorners
        } else {
            null
        }
    }

    private fun validate(
        rawCorners: List<Point>,
        refinedCorners: List<Point>?,
        aiMask: Mat,
        rawArea: Double,
        transition: Double,
        reliableEdges: Int,
        paperCandidate: PaperCandidate?,
        adjustments: List<EdgeAdjustment>,
        pageSide: String?,
    ): Sanity {
        if (refinedCorners == null || refinedCorners.size != 4) {
            return Sanity(false, "refined_corners_unavailable", rawArea, 1.0, 1.0)
        }
        if (refinedCorners.any {
                !it.x.isFinite() || !it.y.isFinite() ||
                    it.x !in 0.0..aiMask.cols().toDouble() || it.y !in 0.0..aiMask.rows().toDouble()
            }
        ) return Sanity(false, "refined_corners_out_of_bounds", rawArea, 0.0, 1.0)

        val contour = MatOfPoint(*refinedCorners.toTypedArray())
        val polygonMask = Mat.zeros(aiMask.size(), CvType.CV_8UC1)
        val intersection = Mat()
        try {
            if (!Imgproc.isContourConvex(contour)) {
                return Sanity(false, "refined_boundary_not_convex", rawArea, 0.0, 1.0)
            }
            val refinedArea = polygonArea(refinedCorners)
            val expansion = refinedArea / rawArea
            if (expansion < MIN_REFINED_AREA_RATIO) {
                return Sanity(false, "excessive_inward_refinement", refinedArea, 0.0, expansion)
            }
            if (expansion > MAX_REFINED_AREA_RATIO) {
                val reason = if ((paperCandidate?.adjacentPagePenalty ?: 0.0) >= ADJACENT_REJECTION_THRESHOLD) {
                    "adjacent_page_merge"
                } else {
                    "excessive_refinement_expansion"
                }
                return Sanity(false, reason, refinedArea, 0.0, expansion)
            }
            Imgproc.fillConvexPoly(polygonMask, contour, Scalar(255.0))
            Core.bitwise_and(polygonMask, aiMask, intersection)
            val aiPixels = Core.countNonZero(aiMask).toDouble().coerceAtLeast(1.0)
            val containment = Core.countNonZero(intersection) / aiPixels
            if (containment < MIN_REFINED_CONTAINMENT) {
                return Sanity(false, "ai_foreground_clipped", refinedArea, containment, expansion)
            }
            if ((paperCandidate?.ownership ?: 1.0) < MIN_MAIN_PAGE_OWNERSHIP) {
                return Sanity(false, "main_page_ownership_lost", refinedArea, containment, expansion)
            }
            if ((paperCandidate?.adjacentPagePenalty ?: 0.0) >= ADJACENT_REJECTION_THRESHOLD) {
                return Sanity(false, "adjacent_page_merge", refinedArea, containment, expansion)
            }
            val topReliable = adjustments.getOrNull(0)?.reliable == true
            val bottomReliable = adjustments.getOrNull(2)?.reliable == true
            val outerIndex = when (pageSide) {
                "left" -> 3
                "right" -> 1
                else -> null
            }
            val outerReliable = outerIndex == null || adjustments.getOrNull(outerIndex)?.reliable == true
            val essentialGeometryReliable = if (pageSide == null) {
                reliableEdges >= MIN_RELIABLE_EDGES
            } else {
                outerReliable && (topReliable || bottomReliable) && reliableEdges >= MIN_SPREAD_RELIABLE_EDGES
            }
            val bottomOcclusion = adjustments.getOrNull(2)?.occlusionPenalty ?: 0.0
            if (bottomOcclusion > MAX_UNRESOLVED_OCCLUSION &&
                (paperCandidate == null || paperCandidate.score < MIN_PAPER_SCORE)
            ) {
                return Sanity(false, "occlusion_unresolved", refinedArea, containment, expansion)
            }
            if (!essentialGeometryReliable &&
                (paperCandidate == null || paperCandidate.score < MIN_PAPER_SCORE)
            ) return Sanity(false, "paper_transition_unreliable", refinedArea, containment, expansion)
            if (transition < MIN_ACCEPTED_TRANSITION && paperCandidate?.transition ?: 0.0 < MIN_ACCEPTED_TRANSITION) {
                return Sanity(false, "paper_transition_weak", refinedArea, containment, expansion)
            }
            return Sanity(true, null, refinedArea, containment, expansion)
        } finally {
            contour.release()
            polygonMask.release()
            intersection.release()
        }
    }

    private fun refinedConfidence(
        containment: Double,
        expansion: Double,
        transition: Double,
        envelopeConsistency: Double,
        edgeContinuity: Double,
        adjacentPenalty: Double,
        occlusionPenalty: Double,
        geometryAccepted: Boolean,
    ): Double {
        val expansionScore = (1.0 - abs(expansion - IDEAL_PAPER_EXPANSION) / 0.55).coerceIn(0.0, 1.0)
        val geometry = if (geometryAccepted) 1.0 else 0.0
        return (
            containment.coerceIn(0.0, 1.0) * 0.24 +
                expansionScore * 0.13 +
                transition.coerceIn(0.0, 1.0) * 0.14 +
                envelopeConsistency.coerceIn(0.0, 1.0) * 0.14 +
                edgeContinuity.coerceIn(0.0, 1.0) * 0.13 +
                geometry * 0.12 -
                adjacentPenalty.coerceIn(0.0, 1.0) * 0.18 -
                occlusionPenalty.coerceIn(0.0, 1.0) * 0.12
            ).coerceIn(0.0, 1.0)
    }

    private fun refinedStatus(
        reason: String?,
        accepted: Boolean,
        occlusionPenalty: Double,
        refinedConfidence: Double,
        conservativeExpansion: Boolean,
    ): String {
        if (accepted) {
            if (conservativeExpansion || refinedConfidence < CONSERVATIVE_CONFIDENCE_THRESHOLD) {
                return "accepted_conservative"
            }
            return if (occlusionPenalty >= OCCLUSION_RECOVERED_THRESHOLD) {
                "accepted_occlusion_recovered"
            } else {
                "accepted"
            }
        }
        return when (reason) {
            "partial_ai_raw" -> "rejected_partial_raw"
            "adjacent_page_merge", "main_page_ownership_lost" -> "rejected_adjacent_page"
            "occlusion_unresolved" -> "rejected_occlusion"
            "excessive_refinement_expansion" -> "rejected_expansion"
            "excessive_inward_refinement" -> "rejected_shrink"
            "ai_foreground_clipped" -> "rejected_foreground_clipped"
            "refined_boundary_not_convex", "refined_corners_out_of_bounds" -> "rejected_geometry"
            else -> "raw_fallback"
        }
    }

    private fun estimateConservativeCorners(
        contour: List<Point>,
        width: Int,
        height: Int,
    ): List<Point>? {
        if (contour.size < 4) return null
        val points = MatOfPoint(*contour.toTypedArray())
        val hullIndices = MatOfInt()
        val hull = MatOfPoint()
        val hull2f = MatOfPoint2f()
        try {
            Imgproc.convexHull(points, hullIndices)
            val sourcePoints = points.toArray()
            hull.fromList(hullIndices.toArray().map { sourcePoints[it] })
            hull2f.fromArray(*hull.toArray())
            val perimeter = Imgproc.arcLength(hull2f, true)
            for (epsilon in listOf(0.008, 0.012, 0.018, 0.025, 0.04)) {
                val approximated = MatOfPoint2f()
                try {
                    Imgproc.approxPolyDP(hull2f, approximated, perimeter * epsilon, true)
                    if (approximated.total() == 4L) {
                        return orderCorners(approximated.toArray().toList(), width, height)
                    }
                } finally {
                    approximated.release()
                }
            }
            val rect = Imgproc.minAreaRect(hull2f)
            val corners = arrayOf(Point(), Point(), Point(), Point())
            rect.points(corners)
            return orderCorners(corners.toList(), width, height)
        } finally {
            points.release()
            hullIndices.release()
            hull.release()
            hull2f.release()
        }
    }

    private fun orderCorners(points: List<Point>, width: Int, height: Int): List<Point>? {
        if (points.size != 4) return null
        val top = points.sortedBy { it.y }.take(2).sortedBy { it.x }
        val bottom = points.sortedBy { it.y }.takeLast(2).sortedBy { it.x }
        val ordered = listOf(top[0], top[1], bottom[1], bottom[0])
        return ordered.takeIf { values ->
            values.all { it.x.isFinite() && it.y.isFinite() && it.x in 0.0..width.toDouble() && it.y in 0.0..height.toDouble() }
        }
    }

    private fun buildGradient(gray: Mat, output: Mat) {
        val blurred = Mat()
        val gx = Mat()
        val gy = Mat()
        try {
            Imgproc.GaussianBlur(gray, blurred, Size(5.0, 5.0), 0.0)
            Imgproc.Sobel(blurred, gx, CvType.CV_32F, 1, 0)
            Imgproc.Sobel(blurred, gy, CvType.CV_32F, 0, 1)
            Core.magnitude(gx, gy, output)
        } finally {
            blurred.release()
            gx.release()
            gy.release()
        }
    }

    private fun boundingRect(points: List<Point>): Rect {
        val left = floor(points.minOf { it.x }).toInt()
        val top = floor(points.minOf { it.y }).toInt()
        val right = ceil(points.maxOf { it.x }).toInt()
        val bottom = ceil(points.maxOf { it.y }).toInt()
        return Rect(left, top, max(1, right - left), max(1, bottom - top))
    }

    private fun polygonArea(points: List<Point>): Double {
        var area = 0.0
        for (index in points.indices) {
            val next = points[(index + 1) % points.size]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return abs(area) / 2.0
    }

    private fun median(values: List<Double>): Double = percentile(values, 0.5)

    private fun percentile(values: List<Double>, quantile: Double): Double {
        if (values.isEmpty()) return 0.0
        val sorted = values.sorted()
        val position = quantile.coerceIn(0.0, 1.0) * (sorted.size - 1)
        val lower = floor(position).toInt()
        val upper = ceil(position).toInt()
        if (lower == upper) return sorted[lower]
        val fraction = position - lower
        return sorted[lower] * (1.0 - fraction) + sorted[upper] * fraction
    }

    private fun trimmedMean(values: List<Double>, fraction: Double): Double {
        if (values.isEmpty()) return 0.0
        val trim = floor(values.size * fraction.coerceIn(0.0, 0.45)).toInt()
        val retained = values.drop(trim).dropLast(trim)
        return if (retained.isEmpty()) median(values) else retained.average()
    }

    private fun oddKernel(value: Int): Int = if (value % 2 == 0) value + 1 else value

    private fun failure(searchRoi: Rect, started: Long, reason: String) = Result(
        accepted = false,
        corners = null,
        searchRoi = searchRoi,
        rawAreaRatio = 0.0,
        refinedAreaRatio = 0.0,
        aiContainmentRatio = 0.0,
        areaExpansionRatio = 1.0,
        paperTransitionScore = 0.0,
        mainPageOwnershipScore = 0.0,
        outerEnvelopeConsistency = 0.0,
        edgeContinuity = 0.0,
        adjacentPagePenalty = 0.0,
        occlusionPenalty = 0.0,
        refinedConfidence = 0.0,
        refinedStatus = "raw_fallback",
        maskToSearchRoiMs = 0,
        paperCandidateMs = 0,
        edgeRefineMs = 0,
        cornerEstimateMs = 0,
        totalRefineMs = SystemClock.elapsedRealtime() - started,
        failureReason = reason,
        paperContour = null,
        envelopeCorners = null,
    )

    companion object {
        const val MAX_ANALYSIS_EDGE = 1280.0
        const val SEARCH_EXPANSION_X = 0.10
        const val SEARCH_EXPANSION_Y = 0.14
        const val MIN_SEARCH_EXPANSION = 0.02
        const val MIN_PAPER_AREA_RATIO = 0.90
        const val MAX_PAPER_AREA_RATIO = 1.85
        const val IDEAL_PAPER_EXPANSION = 1.16
        const val MIN_PAPER_CONTAINMENT = 0.82
        const val MIN_PAPER_SCORE = 0.56
        const val MAX_PAPER_CORNER_EXPANSION = 1.48
        const val PARTIAL_RAW_PAPER_EXPANSION = 1.38
        const val MIN_RAW_HORIZONTAL_EXTENT = 0.28
        const val MIN_RAW_VERTICAL_EXTENT = 0.34
        const val MIN_RAW_AREA_RATIO = 0.045
        const val SECOND_PAPER_MIN_AREA = 0.035
        const val MAX_OWNERSHIP_CENTROID_DISTANCE = 0.32
        const val MIN_MAIN_PAGE_OWNERSHIP = 0.66
        const val ADJACENT_GROWTH_START = 1.24
        const val ADJACENT_GROWTH_RANGE = 0.34
        const val MAX_SAFE_SPINE_OVERSHOOT = 0.12
        const val ADJACENT_REJECTION_THRESHOLD = 0.66
        const val OUTWARD_LIMIT = 0.10
        const val SPINE_OUTWARD_LIMIT = 0.055
        const val MIN_OUTER_MARGIN = 0.006
        const val SEARCH_STEP = 0.003
        const val PROBE_DISTANCE = 0.004
        const val EDGE_SAMPLES = 13
        const val MIN_SAMPLE_EVIDENCE = 0.22
        const val MIN_EDGE_SUPPORT = 0.38
        const val MIN_EDGE_EVIDENCE = 0.24
        const val ROBUST_MAD_LIMIT = 2.8
        const val EDGE_TRIM_FRACTION = 0.18
        const val MAX_LOCAL_SCORE_JUMP = 0.34
        const val MAX_ACCEPTED_EDGE_OCCLUSION = 0.48
        const val MAX_UNRESOLVED_OCCLUSION = 0.62
        const val OCCLUSION_RECOVERED_THRESHOLD = 0.16
        const val MIN_RELIABLE_EDGES = 2
        const val MIN_SPREAD_RELIABLE_EDGES = 2
        const val MIN_REFINED_AREA_RATIO = 0.96
        const val MAX_REFINED_AREA_RATIO = 1.55
        const val MIN_REFINED_CONTAINMENT = 0.94
        const val MIN_ACCEPTED_TRANSITION = 0.18
        const val EDGE_TRANSITION_RANGE = 0.34
        const val CONSERVATIVE_CONFIDENCE_THRESHOLD = 0.58
        const val ENVELOPE_END_TOLERANCE = 0.08
        const val ENVELOPE_PERCENTILE = 0.88
        const val EDGE_CONFIRMED_TRANSITION = 0.30
        const val EDGE_CONFIRMED_SUPPORT = 0.46
        const val EDGE_WEAK_TRANSITION = 0.16
        const val EDGE_WEAK_SUPPORT = 0.28
        const val EDGE_OCCLUDED_THRESHOLD = 0.48
        const val EDGE_BORDER_THRESHOLD = 0.025
        const val WEAK_SAFE_MARGIN = 0.012
        const val OCCLUDED_SAFE_MARGIN = 0.030
        const val UNKNOWN_SAFE_MARGIN = 0.040
        const val BOTTOM_WEAK_SAFE_MARGIN = 0.035
        const val BOTTOM_UNKNOWN_SAFE_MARGIN = 0.070
        const val BOTTOM_ANALYSIS_DEPTH = 0.12
        const val BOTTOM_EDGE_THRESHOLD = 28.0
        const val BOTTOM_DARK_LUMINANCE = 112.0
        const val BOTTOM_PAPER_LUMINANCE = 135.0
        const val BOTTOM_PAPER_CHROMA = 38.0
        const val BOTTOM_FOREGROUND_RATIO = 0.018
        const val BOTTOM_PAPER_RATIO = 0.45
        const val FINAL_MIN_AREA_RATIO = 0.96
        const val FINAL_MAX_AREA_RATIO = 1.70
    }
}
