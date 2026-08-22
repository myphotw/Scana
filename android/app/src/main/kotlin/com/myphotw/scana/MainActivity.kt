package com.myphotw.scana

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.google.android.gms.common.GoogleApiAvailability
import com.google.mlkit.common.MlKitException
import com.google.mlkit.vision.documentscanner.GmsDocumentScanner
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.myphotw.scana.imageprocessing.OpenCvDocumentDetector
import com.myphotw.scana.imageprocessing.FairScanDocumentSegmenter
import com.myphotw.scana.imageprocessing.OpenCvPageCorrector
import com.myphotw.scana.imageprocessing.OpenCvPageCorrector.CurvedCorrectionException
import com.myphotw.scana.imageprocessing.OpenCvPageEnhancer
import com.myphotw.scana.ocr.AndroidLocalOcrService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.io.File

class MainActivity : FlutterActivity() {
    private val detectorExecutor = Executors.newSingleThreadExecutor()
    private var detectorChannel: MethodChannel? = null
    private var aiSegmenterChannel: MethodChannel? = null
    private var aiSegmenter: FairScanDocumentSegmenter? = null
    private var correctorChannel: MethodChannel? = null
    private var enhancerChannel: MethodChannel? = null
    private var ocrChannel: MethodChannel? = null
    private var localOcrService: AndroidLocalOcrService? = null
    private var pdfStorageChannel: MethodChannel? = null
    private var pdfDocumentChannel: MethodChannel? = null
    private var debugDiagnosticsChannel: MethodChannel? = null
    private var mlKitScannerChannel: MethodChannel? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private var pendingDirectoryRequestId: Long? = null
    private var nextDirectoryRequestId = 0L
    private var pendingDebugExportResult: MethodChannel.Result? = null
    private var pendingDebugExportSource: File? = null
    private var pendingMlKitScan: PendingMlKitScan? = null
    private var mlKitScanState = MlKitScanState.IDLE
    private var nextMlKitScanRequestId = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        startupLog("onCreate_begin")
        try {
            super.onCreate(savedInstanceState)
            startupLog("onCreate_complete")
        } catch (error: Throwable) {
            startupLog("onCreate_failed", error)
            throw error
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        startupLog("configureFlutterEngine_begin")
        try {
            super.configureFlutterEngine(flutterEngine)
            configureFlutterChannels(flutterEngine)
            startupLog("configureFlutterEngine_complete")
        } catch (error: Throwable) {
            startupLog("configureFlutterEngine_failed", error)
            throw error
        }
    }

    private fun configureFlutterChannels(flutterEngine: FlutterEngine) {
        mlKitScannerChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                MLKIT_DOCUMENT_SCANNER_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "startScan") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    mlKitLifecycleLog("native_startScan_received")
                    val sessionId = call.argument<String>("sessionId")
                    val startPageNo = call.argument<Int>("startPageNo")
                    if (sessionId.isNullOrBlank() ||
                        !SAFE_SESSION_ID.matches(sessionId) ||
                        startPageNo == null ||
                        startPageNo < 1
                    ) {
                        result.error(
                            "invalid_mlkit_scan",
                            "ML Kit scan arguments are invalid.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    startMlKitScan(sessionId, startPageNo, result)
                }
            }
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
                            val pageSide = call.argument<String>("pageSide")
                            val sensorOrientation = call.argument<Int>("sensorOrientation")
                            if (bytes == null || width == null || height == null || rowStride == null) {
                                result.error("invalid_frame", "Preview frame is invalid.", null)
                                return@setMethodCallHandler
                            }
                            runDetection(result) {
                                if (pageSide == null || sensorOrientation == null) {
                                    OpenCvDocumentDetector.detectPreview(bytes, width, height, rowStride)
                                } else {
                                    OpenCvDocumentDetector.detectPreviewForPage(bytes, width, height, rowStride, pageSide, sensorOrientation)
                                }
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
        aiSegmenterChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                AI_SEGMENTER_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getModelInfo" -> {
                            runDetection(result) {
                                aiSegmenter().modelInfo()
                            }
                        }
                        "segmentDocument" -> {
                            val imagePath = call.argument<String>("imagePath")
                            val pageSide = call.argument<String>("pageSide")
                            val debugOutputDirectory =
                                call.argument<String>("debugOutputDirectory")
                            val debugStem = call.argument<String>("debugStem") ?: "page"
                            val openCvCorners =
                                call.argument<List<Map<String, Number>>>("openCvCorners")
                            val expectedGuideCorners =
                                call.argument<List<Map<String, Number>>>("expectedGuideCorners")
                            if (imagePath.isNullOrBlank()) {
                                result.error(
                                    "invalid_ai_image_path",
                                    "An AI segmentation image path is required.",
                                    null,
                                )
                                return@setMethodCallHandler
                            }
                            runDetection(result) {
                                aiSegmenter().segment(
                                    imagePath = imagePath,
                                    pageSide = pageSide,
                                    debugArtifactsEnabled = isDebuggable,
                                    debugOutputDirectory = debugOutputDirectory,
                                    debugStem = debugStem,
                                    openCvCorners = openCvCorners,
                                    expectedGuideCorners = expectedGuideCorners,
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
                                    isDebuggable,
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
                                    if (error is CurvedCorrectionException) {
                                        error.details
                                    } else {
                                        null
                                    },
                                )
                            }
                        }
                    }
                }
            }
        enhancerChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PAGE_ENHANCER_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "enhancePage") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val sourceImagePath = call.argument<String>("sourceImagePath")
                    val outputImagePath = call.argument<String>("outputImagePath")
                    val enhancementMode = call.argument<String>("enhancementMode")
                    if (sourceImagePath.isNullOrBlank() ||
                        outputImagePath.isNullOrBlank() ||
                        enhancementMode.isNullOrBlank()
                    ) {
                        result.error(
                            "invalid_enhancement_arguments",
                            "Enhancement arguments are invalid.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    detectorExecutor.execute {
                        try {
                            val enhancement = OpenCvPageEnhancer.enhance(
                                sourceImagePath,
                                outputImagePath,
                                enhancementMode,
                                isDebuggable,
                            )
                            debugLog(
                                "IMAGE_PROCESSING",
                                "Scan Enhancement: ${enhancement["processingMilliseconds"]} ms " +
                                    "mode=$enhancementMode",
                            )
                            if (enhancementMode == "scanColor") {
                                debugLog(
                                    "ENHANCEMENT",
                                    "background_analysis_ms=" +
                                        "${enhancement["backgroundAnalysisMilliseconds"]} " +
                                        "background_normalization_ms=" +
                                        "${enhancement["backgroundNormalizationMilliseconds"]} " +
                                        "background_whitening_ms=" +
                                        "${enhancement["backgroundWhiteningMilliseconds"]} " +
                                        "foreground_enhancement_ms=" +
                                        "${enhancement["foregroundEnhancementMilliseconds"]} " +
                                        "sharpening_ms=" +
                                        "${enhancement["sharpeningMilliseconds"]} " +
                                        "total_enhancement_ms=" +
                                        "${enhancement["totalEnhancementMilliseconds"]}",
                                )
                            }
                            runOnUiThread { result.success(enhancement) }
                        } catch (error: Throwable) {
                            debugLog(
                                "IMAGE_PROCESSING",
                                "Scan Enhancement failed mode=$enhancementMode " +
                                    "error=${error.message}",
                            )
                            runOnUiThread {
                                result.error(
                                    "enhancement_failed",
                                    error.message ?: "Page enhancement failed.",
                                    null,
                                )
                            }
                        }
                    }
                }
            }
        ocrChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                LOCAL_OCR_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "recognizeText") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val imagePath = call.argument<String>("imagePath")
                    val sourcePageId = call.argument<String>("sourcePageId")
                    val service = localOcrService()
                    if (imagePath.isNullOrBlank() ||
                        sourcePageId.isNullOrBlank()
                    ) {
                        result.error(
                            "invalid_ocr_arguments",
                            "OCR arguments are invalid.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    debugLog("OCR", "recognition_start source=$sourcePageId")
                    service.recognize(
                        imagePath = imagePath,
                        sourcePageId = sourcePageId,
                        onSuccess = { value ->
                            debugLog(
                                "OCR",
                                "recognition_complete source=$sourcePageId " +
                                    "blocks=${(value["blocks"] as? List<*>)?.size ?: 0}",
                            )
                            runOnUiThread { result.success(value) }
                        },
                        onFailure = { error ->
                            debugLog(
                                "OCR",
                                "recognition_failed source=$sourcePageId error=${error.message}",
                            )
                            runOnUiThread {
                                result.error(
                                    "ocr_failed",
                                    error.message ?: "Text recognition failed.",
                                    null,
                                )
                            }
                        },
                    )
                }
            }
        pdfStorageChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PDF_STORAGE_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getRecentDirectory" -> result.success(recentDirectoryMap())
                        "chooseDirectory" -> {
                            if (pendingDirectoryResult != null) {
                                debugLog("SAF_NATIVE", "request_rejected reason=picker_busy")
                                result.error(
                                    "directory_picker_busy",
                                    "A directory picker is already open.",
                                    null,
                                )
                                return@setMethodCallHandler
                            }
                            val requestId = ++nextDirectoryRequestId
                            pendingDirectoryResult = result
                            pendingDirectoryRequestId = requestId
                            debugLog("SAF_NATIVE", "request id=$requestId method=chooseDirectory")
                            val initialUri = recentDirectoryUri()
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                                )
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && initialUri != null) {
                                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
                                }
                            }
                            try {
                                debugLog("SAF_NATIVE", "native_picker_started id=$requestId")
                                startActivityForResult(intent, REQUEST_PDF_DIRECTORY)
                            } catch (error: Throwable) {
                                takePendingDirectoryResult()
                                debugLog(
                                    "SAF_NATIVE",
                                    "native_picker_start_failed id=$requestId error=${error.message}",
                                )
                                debugLog(
                                    "SAF_NATIVE",
                                    "method_result_complete id=$requestId outcome=error",
                                )
                                result.error(
                                    "directory_picker_failed",
                                    error.message ?: "The directory picker could not be opened.",
                                    null,
                                )
                            }
                        }
                        "savePdf" -> {
                            val temporaryPdfPath = call.argument<String>("temporaryPdfPath")
                            val directoryUri = call.argument<String>("directoryUri")
                            val fileName = call.argument<String>("fileName")
                            if (temporaryPdfPath.isNullOrBlank() ||
                                directoryUri.isNullOrBlank() ||
                                fileName.isNullOrBlank()
                            ) {
                                result.error("invalid_pdf_save", "PDF save arguments are invalid.", null)
                                return@setMethodCallHandler
                            }
                            runStorage(result) {
                                savePdfToDirectory(
                                    temporaryPdfPath,
                                    Uri.parse(directoryUri),
                                    fileName,
                                )
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
        pdfDocumentChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PDF_DOCUMENT_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "openPdf") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    val documentUri = call.argument<String>("documentUri")
                    if (documentUri.isNullOrBlank()) {
                        result.error("invalid_pdf_uri", "A PDF URI is required.", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(Uri.parse(documentUri), "application/pdf")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    val canOpen = intent.resolveActivity(packageManager) != null
                    if (!canOpen) {
                        result.success(mapOf("opened" to false))
                        return@setMethodCallHandler
                    }
                    try {
                        startActivity(Intent.createChooser(intent, "PDF 파일 열기"))
                        result.success(mapOf("opened" to true))
                    } catch (error: Throwable) {
                        debugLog("PDF_VIEWER", "open_failed error=${error.message}")
                        result.success(mapOf("opened" to false))
                    }
                }
            }
        debugDiagnosticsChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                DEBUG_DIAGNOSTICS_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "exportDebugLog") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    if (!isDebuggable) {
                        result.error("debug_only", "Diagnostic export is debug-only.", null)
                        return@setMethodCallHandler
                    }
                    if (pendingDebugExportResult != null) {
                        result.error("debug_export_busy", "A diagnostic export is already open.", null)
                        return@setMethodCallHandler
                    }
                    val logPath = call.argument<String>("logPath")
                    val suggestedName = call.argument<String>("suggestedName")
                    val source = logPath?.let(::File)
                    if (source == null || !source.isFile) {
                        result.error("debug_log_missing", "The diagnostic log is missing.", null)
                        return@setMethodCallHandler
                    }
                    pendingDebugExportResult = result
                    pendingDebugExportSource = source
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TITLE, suggestedName ?: "scana_debug.txt")
                    }
                    try {
                        debugLog("DIAGNOSTICS_NATIVE", "debug_export_picker_started")
                        startActivityForResult(intent, REQUEST_DEBUG_LOG_EXPORT)
                    } catch (error: Throwable) {
                        takePendingDebugExport()
                        debugLog(
                            "DIAGNOSTICS_NATIVE",
                            "debug_export_picker_failed error=${error.message}",
                        )
                        result.error(
                            "debug_export_failed",
                            error.message ?: "The diagnostic log picker could not be opened.",
                            null,
                        )
                    }
                }
            }
    }

    @Deprecated("Deprecated in Android; retained for FlutterActivity SAF compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_MLKIT_SCAN) {
            completeMlKitScan(resultCode, data)
            return
        }
        if (requestCode == REQUEST_DEBUG_LOG_EXPORT) {
            completeDebugLogExport(resultCode, data)
            return
        }
        if (requestCode != REQUEST_PDF_DIRECTORY) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val requestId = pendingDirectoryRequestId
        debugLog(
            "SAF_NATIVE",
            "native_picker_result id=$requestId resultCode=$resultCode uri=${data?.data}",
        )
        val result = takePendingDirectoryResult() ?: return
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            debugLog("SAF_NATIVE", "method_result_complete id=$requestId outcome=cancelled")
            result.success(null)
            return
        }
        try {
            val permissionFlags = (data?.flags ?: 0) and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, permissionFlags)
            pdfPreferences.edit().putString(PREF_RECENT_DIRECTORY, uri.toString()).apply()
            debugLog("SAF_NATIVE", "method_result_complete id=$requestId outcome=success")
            result.success(directoryMap(uri))
        } catch (error: Throwable) {
            debugLog(
                "SAF_NATIVE",
                "method_result_complete id=$requestId outcome=error error=${error.message}",
            )
            result.error(
                "directory_permission_failed",
                error.message ?: "The selected directory permission could not be retained.",
                null,
            )
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mlKitScannerChannel?.setMethodCallHandler(null)
        mlKitScannerChannel = null
        resetMlKitScan(reason = "flutter_engine_cleanup")?.result?.error(
            "mlkit_scan_cancelled",
            "The Flutter engine was detached while ML Kit scanner was open.",
            null,
        )
        detectorChannel?.setMethodCallHandler(null)
        detectorChannel = null
        aiSegmenterChannel?.setMethodCallHandler(null)
        aiSegmenterChannel = null
        aiSegmenter?.close()
        aiSegmenter = null
        correctorChannel?.setMethodCallHandler(null)
        correctorChannel = null
        enhancerChannel?.setMethodCallHandler(null)
        enhancerChannel = null
        ocrChannel?.setMethodCallHandler(null)
        ocrChannel = null
        localOcrService?.close()
        localOcrService = null
        pdfStorageChannel?.setMethodCallHandler(null)
        pdfStorageChannel = null
        pdfDocumentChannel?.setMethodCallHandler(null)
        pdfDocumentChannel = null
        debugDiagnosticsChannel?.setMethodCallHandler(null)
        debugDiagnosticsChannel = null
        val directoryRequestId = pendingDirectoryRequestId
        takePendingDirectoryResult()?.let { result ->
            debugLog(
                "SAF_NATIVE",
                "method_result_complete id=$directoryRequestId outcome=engine_detached",
            )
            result.error(
                "directory_picker_cancelled",
                "The Flutter engine was detached while the directory picker was open.",
                null,
            )
        }
        takePendingDebugExport()?.first?.error(
            "debug_export_cancelled",
            "The Flutter engine was detached while diagnostic export was open.",
            null,
        )
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        debugLog("APP_LIFECYCLE_NATIVE", "onResume")
    }

    override fun onPause() {
        debugLog("APP_LIFECYCLE_NATIVE", "onPause")
        super.onPause()
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

    @Synchronized
    private fun startMlKitScan(
        sessionId: String,
        startPageNo: Int,
        result: MethodChannel.Result,
    ) {
        if (pendingMlKitScan == null && mlKitScanState != MlKitScanState.IDLE) {
            val staleState = mlKitScanState
            mlKitScanState = MlKitScanState.IDLE
            mlKitLifecycleLog(
                "scan_state_reset",
                "requestId=none from=${staleState.name.lowercase()} reason=missing_pending",
            )
        }
        if (mlKitScanState != MlKitScanState.IDLE || pendingMlKitScan != null) {
            mlKitLifecycleLog(
                "startScan_rejected_already_running",
                "requestedSession=$sessionId requestedStartPageNo=$startPageNo",
            )
            result.error(
                "mlkit_scan_in_progress",
                "An ML Kit scan is already running.",
                mapOf(
                    "state" to mlKitScanState.name.lowercase(),
                    "pendingRequestId" to pendingMlKitScan?.requestId,
                ),
            )
            return
        }
        nextMlKitScanRequestId += 1
        val request = PendingMlKitScan(
            requestId = nextMlKitScanRequestId,
            result = result,
            sessionId = sessionId,
            startPageNo = startPageNo,
            launchStartedElapsedMs = SystemClock.elapsedRealtime(),
        )
        pendingMlKitScan = request
        mlKitScanState = MlKitScanState.PREPARING
        mlKitLifecycleLog(
            "scan_state_preparing",
            "requestId=${request.requestId} session=$sessionId startPageNo=$startPageNo",
        )
        debugLog(
            "MLKIT_SCAN",
            "launch_requested session=$sessionId startPageNo=$startPageNo",
        )
        var preparationStage = "options_build_start"
        try {
            mlKitLifecycleLog(preparationStage, "requestId=${request.requestId}")
            preparationStage = "options_build"
            val scanner = createOfficialSampleScannerClient { options ->
                preparationStage = "get_client"
                runCatching {
                    mlKitLifecycleLog(
                        "get_client_start",
                        "requestId=${request.requestId} optionsNonNull=true " +
                            "optionsClass=${options.javaClass.name} " +
                            "optionsIdentity=${System.identityHashCode(options)}",
                    )
                }
            }
            mlKitLifecycleLog("get_client_success", "requestId=${request.requestId}")

            preparationStage = "get_start_intent"
            mlKitLifecycleLog("get_start_intent_start", "requestId=${request.requestId}")
            val startIntentTask = scanner.getStartScanIntent(this@MainActivity)
            mlKitLifecycleLog(
                "get_start_intent_task_created",
                "requestId=${request.requestId}",
            )

            preparationStage = "listener_registration"
            mlKitLifecycleLog("listener_registration_start", "requestId=${request.requestId}")
            startIntentTask.addOnSuccessListener { intentSender ->
                if (!markMlKitScannerActive(request)) {
                    mlKitLifecycleLog(
                        "getStartScanIntent_success_ignored",
                        "requestId=${request.requestId}",
                    )
                    return@addOnSuccessListener
                }
                mlKitLifecycleLog(
                    "getStartScanIntent_success",
                    "requestId=${request.requestId}",
                )
                try {
                    startIntentSenderForResult(
                        intentSender,
                        REQUEST_MLKIT_SCAN,
                        null,
                        0,
                        0,
                        0,
                    )
                    mlKitLifecycleLog(
                        "scanner_activity_launched",
                        "requestId=${request.requestId}",
                    )
                    debugLog("MLKIT_SCAN", "scanner_activity_started")
                } catch (error: Throwable) {
                    failMlKitLaunch(request, error, "scanner_activity_launch")
                }
            }
            startIntentTask.addOnFailureListener { error ->
                failMlKitLaunch(request, error, "get_start_intent_task_failure")
            }
            mlKitLifecycleLog(
                "listener_registration_success",
                "requestId=${request.requestId}",
            )
        } catch (error: Throwable) {
            failMlKitLaunch(request, error, preparationStage)
        }
    }

    /**
     * Deliberately mirrors Google's minimal Document Scanner sample. Scanner
     * lifecycle, Flutter workflow, OCR, and page processing do not enter this
     * construction path.
     */
    private fun createOfficialSampleScannerClient(
        onOptionsBuilt: (GmsDocumentScannerOptions) -> Unit,
    ): GmsDocumentScanner {
        val options = GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(false)
            .setPageLimit(20)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
        onOptionsBuilt(options)
        return GmsDocumentScanning.getClient(options)
    }

    @Synchronized
    private fun markMlKitScannerActive(request: PendingMlKitScan): Boolean {
        if (pendingMlKitScan !== request || mlKitScanState != MlKitScanState.PREPARING) {
            return false
        }
        mlKitScanState = MlKitScanState.ACTIVE
        return true
    }

    @Synchronized
    private fun markMlKitResultProcessing(): PendingMlKitScan? {
        val pending = pendingMlKitScan ?: return null
        if (mlKitScanState != MlKitScanState.ACTIVE) return null
        mlKitScanState = MlKitScanState.PROCESSING_RESULT
        return pending
    }

    private fun failMlKitLaunch(
        request: PendingMlKitScan,
        error: Throwable,
        stage: String,
    ) {
        val failureState = mlKitScanState.name.lowercase()
        mlKitLifecycleLog(
            "getStartScanIntent_failure",
            "requestId=${request.requestId} stage=$stage " +
                "type=${error.javaClass.name} message=${error.message}",
        )
        val pending = resetMlKitScan(request, reason = "launch_error") ?: return
        val details = mlKitLaunchFailureDetails(
            error,
            stage,
            request.requestId,
            failureState,
        )
        val code = if (error is MlKitException) {
            "mlkit_${error.errorCode}"
        } else {
            "mlkit_${error.javaClass.simpleName.ifBlank { "launch_failure" }}"
        }
        mlKitScannerFailureLog(details, error)
        debugLog(
            "MLKIT_SCAN",
            "launch_failed code=$code type=${details["exceptionClass"]} " +
                "errorCode=${details["errorCode"]} message=${details["message"]}",
        )
        pending.result.error(
            code,
            error.message ?: "ML Kit scanner could not be prepared.",
            details,
        )
    }

    private fun mlKitLaunchFailureDetails(
        error: Throwable,
        stage: String,
        requestId: Long,
        scannerState: String,
    ): Map<String, Any?> {
        val exceptionFrame = error.stackTrace.firstOrNull()
        val scanaFrame = error.stackTrace.firstOrNull { frame ->
            frame.className == MainActivity::class.java.name
        }
        val details = linkedMapOf<String, Any?>(
            "buildMode" to if (isDebuggable) "debug" else "release",
            "requestId" to requestId,
            "scannerState" to scannerState,
            "stage" to stage,
            "exceptionClass" to error.javaClass.name,
            "errorCode" to (error as? MlKitException)?.errorCode,
            "message" to error.message,
            "causeClass" to error.cause?.javaClass?.name,
            "causeMessage" to error.cause?.message,
            "exceptionFile" to exceptionFrame?.fileName,
            "exceptionLineNumber" to exceptionFrame?.lineNumber,
            "exceptionMethod" to exceptionFrame?.methodName,
            "exceptionOriginClass" to exceptionFrame?.className,
            "exceptionLine" to exceptionFrame?.let { frame ->
                "${frame.fileName ?: "unknown"}:${frame.lineNumber}"
            },
            "scanaExceptionLine" to scanaFrame?.let { frame ->
                "${frame.fileName ?: "unknown"}:${frame.lineNumber}"
            },
        )
        runCatching {
            val googleApiAvailability = GoogleApiAvailability.getInstance()
            val googlePlayServicesStatus =
                googleApiAvailability.isGooglePlayServicesAvailable(this@MainActivity)
            val appPackageInfo = runCatching {
                packageManager.getPackageInfo(packageName, 0)
            }.getOrNull()
            val googlePlayServicesPackageInfo = runCatching {
                packageManager.getPackageInfo(GOOGLE_PLAY_SERVICES_PACKAGE, 0)
            }.getOrNull()
            details.putAll(
                mapOf(
                    "googlePlayServicesStatus" to googlePlayServicesStatus,
                    "googlePlayServicesStatusName" to
                        googleApiAvailability.getErrorString(googlePlayServicesStatus),
                    "googlePlayServicesVersionCode" to
                        googlePlayServicesPackageInfo?.compatibleLongVersionCode(),
                    "packageName" to packageName,
                    "versionCode" to appPackageInfo?.compatibleLongVersionCode(),
                    "versionName" to appPackageInfo?.versionName,
                ),
            )
        }.onFailure { diagnosticsError ->
            details["diagnosticsErrorClass"] = diagnosticsError.javaClass.name
            details["diagnosticsErrorMessage"] = diagnosticsError.message
            mlKitLifecycleLog(
                "diagnostics_collection_failure",
                "requestId=$requestId type=${diagnosticsError.javaClass.name} " +
                    "message=${diagnosticsError.message}",
            )
        }
        return details
    }

    private fun android.content.pm.PackageInfo.compatibleLongVersionCode(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else {
            @Suppress("DEPRECATION")
            versionCode.toLong()
        }

    @Synchronized
    private fun mlKitScannerFailureLog(
        details: Map<String, Any?>,
        error: Throwable,
    ) {
        runCatching {
            val directory = File(filesDir, "diagnostics").apply { mkdirs() }
            val entry = buildString {
                append("[MLKIT_SCANNER_FAILURE]\n")
                append("timestamp=").append(System.currentTimeMillis()).append('\n')
                details.forEach { (key, value) ->
                    append(key).append('=').append(value ?: "null").append('\n')
                }
                append("stackTrace=").append(error.stackTraceToString()).append('\n')
            }
            File(directory, "scana_mlkit_scanner.log").appendText(entry)
        }
    }

    @Synchronized
    private fun mlKitLifecycleLog(event: String, details: String = "") {
        runCatching {
            val directory = File(filesDir, "diagnostics").apply { mkdirs() }
            val pendingRequestId = pendingMlKitScan?.requestId ?: "none"
            File(directory, "scana_mlkit_scanner.log").appendText(
                "[MLKIT_SCANNER_LIFECYCLE] " +
                    "timestamp=${System.currentTimeMillis()} " +
                    "event=$event state=${mlKitScanState.name.lowercase()} " +
                    "pendingRequestId=$pendingRequestId $details\n",
            )
        }
    }

    private fun completeMlKitScan(resultCode: Int, data: Intent?) {
        mlKitLifecycleLog("result_received", "resultCode=$resultCode")
        if (resultCode != Activity.RESULT_OK) {
            val pending = pendingMlKitScan ?: run {
                debugLog("MLKIT_SCAN", "result_ignored no_pending_request")
                return
            }
            mlKitLifecycleLog(
                "cancel",
                "requestId=${pending.requestId} resultCode=$resultCode",
            )
            val cancelled = resetMlKitScan(pending, reason = "cancel") ?: return
            val returnedElapsedMs = SystemClock.elapsedRealtime()
            debugLog(
                "MLKIT_SCAN",
                "result_cancelled elapsedMs=${returnedElapsedMs - cancelled.launchStartedElapsedMs}",
            )
            cancelled.result.success(
                mapOf(
                    "status" to "cancelled",
                    "launchStartedElapsedMs" to cancelled.launchStartedElapsedMs,
                    "resultReturnedElapsedMs" to returnedElapsedMs,
                ),
            )
            return
        }
        val pending = markMlKitResultProcessing() ?: run {
            mlKitLifecycleLog(
                "error",
                "message=successful result received outside active state",
            )
            resetMlKitScan(reason = "unexpected_result_state")?.result?.error(
                "mlkit_result_state_invalid",
                "ML Kit scan result arrived in an invalid lifecycle state.",
                null,
            )
            debugLog("MLKIT_SCAN", "result_ignored invalid_state")
            return
        }
        val returnedElapsedMs = SystemClock.elapsedRealtime()
        detectorExecutor.execute {
            try {
                val value = copyMlKitJpegs(pending, data, returnedElapsedMs)
                runOnUiThread {
                    mlKitLifecycleLog(
                        "success",
                        "requestId=${pending.requestId}",
                    )
                    val completed = resetMlKitScan(pending, reason = "success")
                        ?: return@runOnUiThread
                    completed.result.success(value)
                }
            } catch (error: Throwable) {
                debugLog("MLKIT_SCAN", "result_failed error=${error.message}")
                runOnUiThread {
                    mlKitLifecycleLog(
                        "error",
                        "requestId=${pending.requestId} type=${error.javaClass.name} " +
                            "message=${error.message}",
                    )
                    val failed = resetMlKitScan(pending, reason = "result_error")
                        ?: return@runOnUiThread
                    failed.result.error(
                        "mlkit_result_failed",
                        error.message ?: "ML Kit scan result could not be imported.",
                        null,
                    )
                }
            }
        }
    }

    private fun copyMlKitJpegs(
        pending: PendingMlKitScan,
        data: Intent?,
        returnedElapsedMs: Long,
    ): Map<String, Any> {
        val scanResult = GmsDocumentScanningResult.fromActivityResultIntent(data)
        val pages = scanResult?.pages.orEmpty()
        val destinationDirectory = File(
            File(File(filesDir, "scan_sessions"), pending.sessionId),
            "mlkit",
        ).apply { mkdirs() }
        check(destinationDirectory.isDirectory) {
            "ML Kit session directory could not be created."
        }
        val createdFiles = mutableListOf<File>()
        try {
            val copiedPages = pages.mapIndexed { index, page ->
                val pageNo = pending.startPageNo + index
                val destination = File(
                    destinationDirectory,
                    "page_${pageNo.toString().padStart(3, '0')}.jpg",
                )
                check(!destination.exists()) { "ML Kit page already exists: $pageNo" }
                val byteCount = contentResolver.openInputStream(page.imageUri)?.use { input ->
                    destination.outputStream().use { output -> input.copyTo(output) }
                } ?: throw IllegalStateException("ML Kit JPEG could not be opened.")
                createdFiles.add(destination)
                check(byteCount > 0 && destination.length() == byteCount) {
                    "ML Kit JPEG copy was incomplete."
                }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(destination.path, bounds)
                check(bounds.outWidth > 0 && bounds.outHeight > 0) {
                    "ML Kit result is not a readable JPEG image."
                }
                debugLog(
                    "MLKIT_SCAN",
                    "page=$pageNo bytes=$byteCount size=${bounds.outWidth}x${bounds.outHeight}",
                )
                mapOf(
                    "filePath" to destination.absolutePath,
                    "byteCount" to byteCount,
                    "width" to bounds.outWidth,
                    "height" to bounds.outHeight,
                )
            }
            debugLog(
                "MLKIT_SCAN",
                "result_completed pages=${copiedPages.size} " +
                    "elapsedMs=${returnedElapsedMs - pending.launchStartedElapsedMs}",
            )
            return mapOf(
                "status" to "completed",
                "pages" to copiedPages,
                "pageCount" to copiedPages.size,
                "launchStartedElapsedMs" to pending.launchStartedElapsedMs,
                "resultReturnedElapsedMs" to returnedElapsedMs,
            )
        } catch (error: Throwable) {
            createdFiles.forEach { file -> runCatching { file.delete() } }
            throw error
        }
    }

    @Synchronized
    private fun resetMlKitScan(
        expected: PendingMlKitScan? = null,
        reason: String,
    ): PendingMlKitScan? {
        val pending = pendingMlKitScan
        if (pending == null) {
            if (mlKitScanState != MlKitScanState.IDLE) {
                val previousState = mlKitScanState
                mlKitScanState = MlKitScanState.IDLE
                mlKitLifecycleLog(
                    "scan_state_reset",
                    "requestId=none from=${previousState.name.lowercase()} reason=$reason",
                )
            }
            return null
        }
        if (expected != null && pending !== expected) return null
        pendingMlKitScan = null
        val previousState = mlKitScanState
        mlKitScanState = MlKitScanState.IDLE
        mlKitLifecycleLog(
            "scan_state_reset",
            "requestId=${pending.requestId} from=${previousState.name.lowercase()} reason=$reason",
        )
        return pending
    }

    @Synchronized
    private fun aiSegmenter(): FairScanDocumentSegmenter {
        return aiSegmenter ?: FairScanDocumentSegmenter(applicationContext).also {
            aiSegmenter = it
        }
    }

    @Synchronized
    private fun localOcrService(): AndroidLocalOcrService {
        return localOcrService ?: AndroidLocalOcrService().also {
            localOcrService = it
        }
    }

    private fun startupLog(event: String, error: Throwable? = null) {
        runCatching {
            val directory = File(filesDir, "startup").apply { mkdirs() }
            val details = buildString {
                append(System.currentTimeMillis())
                append(' ')
                append(event)
                if (error != null) {
                    append(" type=")
                    append(error.javaClass.name)
                    append(" message=")
                    append(error.message)
                    append('\n')
                    append(error.stackTraceToString())
                }
                append('\n')
            }
            File(directory, "scana_native_startup.log").appendText(details)
        }
    }

    private fun takePendingDirectoryResult(): MethodChannel.Result? {
        val result = pendingDirectoryResult
        pendingDirectoryResult = null
        pendingDirectoryRequestId = null
        return result
    }

    private fun completeDebugLogExport(resultCode: Int, data: Intent?) {
        val (result, source) = takePendingDebugExport() ?: return
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            debugLog("DIAGNOSTICS_NATIVE", "debug_export_result cancelled")
            result.success(mapOf("exported" to false))
            return
        }
        try {
            source.inputStream().use { input ->
                contentResolver.openOutputStream(uri, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: throw IllegalStateException("The diagnostic destination is not writable.")
            }
            debugLog("DIAGNOSTICS_NATIVE", "debug_export_result success uri=$uri")
            result.success(mapOf("exported" to true, "uri" to uri.toString()))
        } catch (error: Throwable) {
            debugLog(
                "DIAGNOSTICS_NATIVE",
                "debug_export_result error=${error.message}",
            )
            result.error(
                "debug_export_failed",
                error.message ?: "The diagnostic log could not be exported.",
                null,
            )
        }
    }

    private fun takePendingDebugExport(): Pair<MethodChannel.Result, File>? {
        val result = pendingDebugExportResult
        val source = pendingDebugExportSource
        pendingDebugExportResult = null
        pendingDebugExportSource = null
        return if (result != null && source != null) result to source else null
    }

    @Synchronized
    private fun debugLog(category: String, message: String) {
        if (!isDebuggable) return
        runCatching {
            val directory = File(filesDir, "debug").apply { mkdirs() }
            File(directory, "scana_debug.log").appendText(
                "[${System.currentTimeMillis()}][$category] $message\n",
            )
        }
    }

    private fun runStorage(
        result: MethodChannel.Result,
        operation: () -> Map<String, Any>,
    ) {
        detectorExecutor.execute {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "pdf_storage_failed",
                        error.message ?: "The PDF could not be saved.",
                        null,
                    )
                }
            }
        }
    }

    private fun savePdfToDirectory(
        temporaryPdfPath: String,
        treeUri: Uri,
        fileName: String,
    ): Map<String, Any> {
        val source = File(temporaryPdfPath)
        require(source.isFile && source.length() > 0) { "The temporary PDF is missing or empty." }
        require(hasPersistedWritePermission(treeUri)) { "The directory permission is no longer valid." }
        val parentDocument = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        val documentUri = DocumentsContract.createDocument(
            contentResolver,
            parentDocument,
            "application/pdf",
            fileName,
        ) ?: throw IllegalStateException("The destination document could not be created.")
        try {
            source.inputStream().use { input ->
                contentResolver.openOutputStream(documentUri, "w")?.use { output ->
                    input.copyTo(output)
                    output.flush()
                } ?: throw IllegalStateException("The destination document is not writable.")
            }
            val byteCount = contentResolver.openAssetFileDescriptor(documentUri, "r")?.use {
                if (it.length >= 0) it.length else source.length()
            } ?: source.length()
            check(byteCount > 0) { "The saved PDF is empty." }
            return mapOf(
                "uri" to documentUri.toString(),
                "displayName" to documentDisplayName(documentUri, fileName),
                "byteCount" to byteCount,
            )
        } catch (error: Throwable) {
            runCatching { DocumentsContract.deleteDocument(contentResolver, documentUri) }
            throw error
        }
    }

    private fun recentDirectoryMap(): Map<String, Any>? {
        val uri = recentDirectoryUri() ?: return null
        return directoryMap(uri)
    }

    private fun recentDirectoryUri(): Uri? {
        val value = pdfPreferences.getString(PREF_RECENT_DIRECTORY, null) ?: return null
        val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return null
        if (!hasPersistedWritePermission(uri)) {
            pdfPreferences.edit().remove(PREF_RECENT_DIRECTORY).apply()
            return null
        }
        return uri
    }

    private fun hasPersistedWritePermission(uri: Uri): Boolean =
        contentResolver.persistedUriPermissions.any { permission ->
            permission.uri == uri && permission.isWritePermission
        }

    private fun directoryMap(uri: Uri): Map<String, Any> = mapOf(
        "uri" to uri.toString(),
        "label" to documentDisplayName(
            DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri),
            ),
            "Selected folder",
        ),
    )

    private fun documentDisplayName(uri: Uri, fallback: String): String {
        return runCatching {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull() ?: fallback
    }

    private val pdfPreferences
        get() = getSharedPreferences(PDF_PREFERENCES, MODE_PRIVATE)

    private val isDebuggable
        get() = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    private companion object {
        enum class MlKitScanState {
            IDLE,
            PREPARING,
            ACTIVE,
            PROCESSING_RESULT,
        }

        data class PendingMlKitScan(
            val requestId: Long,
            val result: MethodChannel.Result,
            val sessionId: String,
            val startPageNo: Int,
            val launchStartedElapsedMs: Long,
        )

        val SAFE_SESSION_ID = Regex("^[A-Za-z0-9_-]+$")
        const val MLKIT_DOCUMENT_SCANNER_CHANNEL =
            "com.myphotw.scana/mlkit_document_scanner"
        const val DOCUMENT_DETECTOR_CHANNEL = "com.myphotw.scana/document_detector"
        const val AI_SEGMENTER_CHANNEL = "com.myphotw.scana/ai_document_segmenter"
        const val PAGE_CORRECTOR_CHANNEL = "com.myphotw.scana/page_corrector"
        const val PAGE_ENHANCER_CHANNEL = "com.myphotw.scana/page_enhancer"
        const val LOCAL_OCR_CHANNEL = "com.myphotw.scana/local_ocr"
        const val PDF_STORAGE_CHANNEL = "com.myphotw.scana/pdf_storage"
        const val PDF_DOCUMENT_CHANNEL = "com.myphotw.scana/pdf_document"
        const val DEBUG_DIAGNOSTICS_CHANNEL = "com.myphotw.scana/debug_diagnostics"
        const val PDF_PREFERENCES = "scana_pdf_storage"
        const val PREF_RECENT_DIRECTORY = "recent_directory_uri"
        const val REQUEST_PDF_DIRECTORY = 4701
        const val REQUEST_DEBUG_LOG_EXPORT = 4702
        const val REQUEST_MLKIT_SCAN = 4703
        const val GOOGLE_PLAY_SERVICES_PACKAGE = "com.google.android.gms"
    }
}
