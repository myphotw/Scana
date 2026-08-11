package com.myphotw.scana

import android.content.pm.ApplicationInfo
import com.myphotw.scana.imageprocessing.OpenCvDocumentDetector
import com.myphotw.scana.imageprocessing.OpenCvPageCorrector
import com.myphotw.scana.imageprocessing.OpenCvPageCorrector.CurvedCorrectionException
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val detectorExecutor = Executors.newSingleThreadExecutor()
    private var detectorChannel: MethodChannel? = null
    private var correctorChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        detectorChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                DOCUMENT_DETECTOR_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "detectDocument" -> {
                            val imagePath = call.argument<String>("imagePath")
                            val pageSide = call.argument<String>("pageSide")
                            if (imagePath.isNullOrBlank()) {
                                result.error("invalid_path", "An image path is required.", null)
                                return@setMethodCallHandler
                            }
                            runDetection(result) {
                                OpenCvDocumentDetector.detect(
                                    imagePath,
                                    pageSide,
                                    applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0,
                                )
                            }
                        }
                        "detectPreviewFrame" -> {
                            val bytes = call.argument<ByteArray>("bytes")
                            val width = call.argument<Int>("width")
                            val height = call.argument<Int>("height")
                            val rowStride = call.argument<Int>("rowStride")
                            if (bytes == null || width == null || height == null || rowStride == null) {
                                result.error("invalid_frame", "Preview frame is invalid.", null)
                                return@setMethodCallHandler
                            }
                            runDetection(result) {
                                OpenCvDocumentDetector.detectPreview(bytes, width, height, rowStride)
                            }
                        }
                        "splitSpreadCapture" -> {
                            val imagePath = call.argument<String>("imagePath")
                            val overlap = call.argument<Double>("overlapFraction")
                            if (imagePath.isNullOrBlank() || overlap == null) {
                                result.error("invalid_spread", "Spread capture arguments are invalid.", null)
                                return@setMethodCallHandler
                            }
                            runDetection(result) {
                                OpenCvDocumentDetector.splitSpreadCapture(imagePath, overlap)
                            }
                        }
                        "cropSpreadFallback" -> {
                            val imagePath = call.argument<String>("imagePath")
                            val outputImagePath = call.argument<String>("outputImagePath")
                            val left = call.argument<Double>("left")
                            val top = call.argument<Double>("top")
                            val right = call.argument<Double>("right")
                            val bottom = call.argument<Double>("bottom")
                            if (imagePath.isNullOrBlank() ||
                                outputImagePath.isNullOrBlank() ||
                                left == null || top == null || right == null || bottom == null
                            ) {
                                result.error("invalid_spread_crop", "Spread crop arguments are invalid.", null)
                                return@setMethodCallHandler
                            }
                            runDetection(result) {
                                OpenCvDocumentDetector.cropSpreadFallback(
                                    imagePath,
                                    outputImagePath,
                                    left,
                                    top,
                                    right,
                                    bottom,
                                )
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        correctorChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PAGE_CORRECTOR_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "correctPage") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val sourceImagePath = call.argument<String>("sourceImagePath")
                    val outputImagePath = call.argument<String>("outputImagePath")
                    val correctionType = call.argument<String>("correctionType")
                    val pageBoundaryMode = call.argument<String>("pageBoundaryMode")
                    val curvePolicy = call.argument<Map<String, Number>>("curvePolicy")
                    val corners = call.argument<List<Map<String, Number>>>("corners")
                    val pageBoundary = call.argument<Map<String, Any>>("pageBoundary")
                    if (sourceImagePath.isNullOrBlank() ||
                        outputImagePath.isNullOrBlank() ||
                        correctionType.isNullOrBlank() ||
                        pageBoundaryMode.isNullOrBlank() ||
                        curvePolicy == null ||
                        corners == null
                    ) {
                        result.error("invalid_arguments", "Correction arguments are invalid.", null)
                        return@setMethodCallHandler
                    }

                    detectorExecutor.execute {
                        try {
                            val correction =
                                OpenCvPageCorrector.correct(
                                    sourceImagePath,
                                    outputImagePath,
                                    corners,
                                    correctionType,
                                    pageBoundaryMode,
                                    curvePolicy,
                                    pageBoundary,
                                )
                            runOnUiThread { result.success(correction) }
                        } catch (error: Throwable) {
                            runOnUiThread {
                                result.error(
                                    if (error is CurvedCorrectionException) {
                                        error.code
                                    } else {
                                        "correction_failed"
                                    },
                                    error.message ?: "Page correction failed.",
                                    null,
                                )
                            }
                        }
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        detectorChannel?.setMethodCallHandler(null)
        detectorChannel = null
        correctorChannel?.setMethodCallHandler(null)
        correctorChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        detectorExecutor.shutdown()
        super.onDestroy()
    }

    private fun runDetection(
        result: MethodChannel.Result,
        operation: () -> Map<String, Any>,
    ) {
        detectorExecutor.execute {
            try {
                val detection = operation()
                runOnUiThread { result.success(detection) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "detection_failed",
                        error.message ?: "Document detection failed.",
                        null,
                    )
                }
            }
        }
    }

    private companion object {
        const val DOCUMENT_DETECTOR_CHANNEL = "com.myphotw.scana/document_detector"
        const val PAGE_CORRECTOR_CHANNEL = "com.myphotw.scana/page_corrector"
    }
}
