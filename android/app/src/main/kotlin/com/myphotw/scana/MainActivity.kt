package com.myphotw.scana

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.myphotw.scana.imageprocessing.OpenCvDocumentDetector
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
    private var correctorChannel: MethodChannel? = null
    private var enhancerChannel: MethodChannel? = null
    private var ocrChannel: MethodChannel? = null
    private var localOcrService: AndroidLocalOcrService? = null
    private var pdfStorageChannel: MethodChannel? = null
    private var pdfDocumentChannel: MethodChannel? = null
    private var debugDiagnosticsChannel: MethodChannel? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private var pendingDirectoryRequestId: Long? = null
    private var nextDirectoryRequestId = 0L
    private var pendingDebugExportResult: MethodChannel.Result? = null
    private var pendingDebugExportSource: File? = null

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
        localOcrService = AndroidLocalOcrService()
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
                    val service = localOcrService
                    if (imagePath.isNullOrBlank() ||
                        sourcePageId.isNullOrBlank() ||
                        service == null
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
        detectorChannel?.setMethodCallHandler(null)
        detectorChannel = null
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
        const val DOCUMENT_DETECTOR_CHANNEL = "com.myphotw.scana/document_detector"
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
    }
}
