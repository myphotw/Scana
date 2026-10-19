package com.myphotw.scana.pdfeditor

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.min
import kotlin.math.roundToInt

/** Native host for editing an existing PDF. It never touches ScanSession data. */
class ExistingPdfEditorPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val workspaceRoot = File(activity.cacheDir, "existing_pdf_editor")
    private var pendingPickResult: MethodChannel.Result? = null

    init {
        workspaceRoot.mkdirs()
        channel.setMethodCallHandler(::handle)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_OPEN_PDF) return false
        val result = pendingPickResult ?: return true
        pendingPickResult = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return true
        }
        executor.execute {
            try {
                val flags = ((data?.flags ?: 0) and Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (flags != 0) {
                    runCatching { activity.contentResolver.takePersistableUriPermission(uri, flags) }
                }
                val imported = importPdf(uri)
                activity.runOnUiThread { result.success(imported) }
            } catch (error: Throwable) {
                activity.runOnUiThread {
                    result.error(
                        "pdf_import_failed",
                        error.message ?: "PDF를 불러올 수 없습니다.",
                        null,
                    )
                }
            }
        }
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pendingPickResult?.error(
            "pdf_picker_cancelled",
            "PDF 선택 중 화면이 종료되었습니다.",
            null,
        )
        pendingPickResult = null
        executor.shutdown()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickPdf" -> openPicker(result)
            "renderThumbnail" -> runAsync(result) { renderThumbnail(call) }
            "exportPdf" -> runAsync(result) { exportPdf(call) }
            "discardOutput" -> runAsync(result) {
                val directory = sessionDirectory(call.requireString("sessionId"))
                val output = File(call.requireString("outputPath")).canonicalFile
                require(output.parentFile == directory.canonicalFile && output.name.startsWith("edited_")) {
                    "PDF 임시 출력 경로가 잘못되었습니다."
                }
                !output.exists() || output.delete()
            }
            "cleanup" -> runAsync(result) {
                sessionDirectory(call.requireString("sessionId")).deleteRecursively()
                true
            }
            else -> result.notImplemented()
        }
    }

    private fun openPicker(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("pdf_picker_busy", "PDF 선택기가 이미 열려 있습니다.", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/pdf"
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        try {
            activity.startActivityForResult(intent, REQUEST_OPEN_PDF)
        } catch (error: Throwable) {
            pendingPickResult = null
            result.error(
                "pdf_picker_failed",
                error.message ?: "PDF 선택기를 열 수 없습니다.",
                null,
            )
        }
    }

    private fun importPdf(uri: Uri): Map<String, Any> {
        val sessionId = UUID.randomUUID().toString()
        val directory = sessionDirectory(sessionId).apply { mkdirs() }
        val source = File(directory, "source.pdf")
        try {
            activity.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(source).use { output -> input.copyTo(output) }
            } ?: throw IllegalArgumentException("선택한 PDF를 읽을 수 없습니다.")
            require(source.length() >= MINIMUM_PDF_BYTES) { "선택한 PDF가 비어 있습니다." }
            val qpdfStatus = QpdfNative.validate(source.absolutePath)
            require(qpdfStatus == QPDF_SUCCESS) {
                "암호로 보호되었거나 손상된 PDF는 현재 편집할 수 없습니다."
            }
            val pageCount = pageCount(source)
            require(pageCount > 0) { "페이지가 없는 PDF는 편집할 수 없습니다." }
            return mapOf(
                "sessionId" to sessionId,
                "sourcePath" to source.absolutePath,
                "displayName" to displayName(uri),
                "pageCount" to pageCount,
                "byteCount" to source.length(),
            )
        } catch (error: Throwable) {
            directory.deleteRecursively()
            throw error
        }
    }

    private fun renderThumbnail(call: MethodCall): Map<String, Any> {
        val directory = sessionDirectory(call.requireString("sessionId"))
        val source = File(directory, "source.pdf")
        require(source.isFile) { "PDF 편집 세션이 만료되었습니다." }
        val pageIndex = call.requireInt("pageIndex")
        val maximumWidth = call.requireInt("maximumWidth").coerceIn(64, 1024)
        val maximumHeight = call.requireInt("maximumHeight").coerceIn(64, 1440)
        val thumbnail = File(directory, "thumb_${pageIndex}_${maximumWidth}_$maximumHeight.png")
        if (!thumbnail.isFile || thumbnail.length() == 0L) {
            openRenderer(source).use { renderer ->
                require(pageIndex in 0 until renderer.pageCount) { "PDF 페이지 번호가 잘못되었습니다." }
                renderer.openPage(pageIndex).use { page ->
                    val scale = min(
                        maximumWidth.toDouble() / page.width,
                        maximumHeight.toDouble() / page.height,
                    ).coerceAtMost(1.5)
                    val width = (page.width * scale).roundToInt().coerceAtLeast(1)
                    val height = (page.height * scale).roundToInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(android.graphics.Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        FileOutputStream(thumbnail).use { output ->
                            check(bitmap.compress(Bitmap.CompressFormat.PNG, 90, output)) {
                                "PDF 썸네일을 저장할 수 없습니다."
                            }
                        }
                    } finally {
                        bitmap.recycle()
                    }
                }
            }
        }
        return mapOf("path" to thumbnail.absolutePath, "pageIndex" to pageIndex)
    }

    private fun exportPdf(call: MethodCall): Map<String, Any> {
        val directory = sessionDirectory(call.requireString("sessionId"))
        val source = File(directory, "source.pdf")
        require(source.isFile) { "PDF 편집 세션이 만료되었습니다." }
        val originalPageCount = pageCount(source)
        val rawOrder = call.argument<List<*>>("pageOrder")
            ?: throw IllegalArgumentException("PDF 페이지 순서가 없습니다.")
        val order = rawOrder.map {
            (it as? Number)?.toInt()
                ?: throw IllegalArgumentException("PDF 페이지 순서가 잘못되었습니다.")
        }
        val oneBasedOrder = PdfPageOrderPolicy.toOneBased(order, originalPageCount)
        val output = File(directory, "edited_${System.nanoTime()}.pdf")
        try {
            val status = QpdfNative.edit(
                source.absolutePath,
                output.absolutePath,
                oneBasedOrder,
            )
            require(status == QPDF_SUCCESS) { "PDF 페이지를 저장할 수 없습니다." }
            require(output.isFile && output.length() >= MINIMUM_PDF_BYTES) {
                "편집된 PDF가 생성되지 않았습니다."
            }
            require(QpdfNative.validate(output.absolutePath) == QPDF_SUCCESS) {
                "편집된 PDF의 유효성 검사에 실패했습니다."
            }
            require(pageCount(output) == order.size) {
                "편집된 PDF의 페이지 수가 예상과 다릅니다."
            }
            return mapOf(
                "outputPath" to output.absolutePath,
                "pageCount" to order.size,
                "byteCount" to output.length(),
            )
        } catch (error: Throwable) {
            output.delete()
            throw error
        }
    }

    private fun pageCount(file: File): Int = openRenderer(file).use { it.pageCount }

    private fun openRenderer(file: File): PdfRenderer = PdfRenderer(
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY),
    )

    private fun sessionDirectory(sessionId: String): File {
        require(SESSION_ID.matches(sessionId)) { "PDF 편집 세션 ID가 잘못되었습니다." }
        val directory = File(workspaceRoot, sessionId)
        require(directory.canonicalFile.parentFile == workspaceRoot.canonicalFile) {
            "PDF 편집 작업 경로가 잘못되었습니다."
        }
        return directory
    }

    private fun displayName(uri: Uri): String = runCatching {
        activity.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()?.takeIf { it.isNotBlank() } ?: "document.pdf"

    private fun runAsync(result: MethodChannel.Result, operation: () -> Any) {
        executor.execute {
            try {
                val value = operation()
                activity.runOnUiThread { result.success(value) }
            } catch (error: Throwable) {
                activity.runOnUiThread {
                    result.error(
                        "pdf_editor_failed",
                        error.message ?: "PDF 편집 작업에 실패했습니다.",
                        null,
                    )
                }
            }
        }
    }

    private fun MethodCall.requireString(name: String): String =
        argument<String>(name)?.takeIf { it.isNotBlank() }
            ?: throw IllegalArgumentException("$name 값이 없습니다.")

    private fun MethodCall.requireInt(name: String): Int =
        argument<Number>(name)?.toInt()
            ?: throw IllegalArgumentException("$name 값이 없습니다.")

    private companion object {
        const val CHANNEL = "com.myphotw.scana/existing_pdf_editor"
        const val REQUEST_OPEN_PDF = 4704
        const val QPDF_SUCCESS = 0
        const val MINIMUM_PDF_BYTES = 8L
        val SESSION_ID = Regex("^[0-9a-fA-F-]{36}$")
    }
}
