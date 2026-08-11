package com.myphotw.scana.ocr

import android.graphics.BitmapFactory
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
import java.io.File
import java.util.concurrent.Executors

/** Bundled Korean ML Kit Text Recognition v2. No runtime model download. */
class AndroidLocalOcrService : AutoCloseable {
    private val executor = Executors.newSingleThreadExecutor()
    private val recognizer: TextRecognizer = TextRecognition.getClient(
        KoreanTextRecognizerOptions.Builder().build(),
    )

    fun recognize(
        imagePath: String,
        sourcePageId: String,
        onSuccess: (Map<String, Any>) -> Unit,
        onFailure: (Throwable) -> Unit,
    ) {
        executor.execute {
            var bitmap: android.graphics.Bitmap? = null
            try {
                val source = File(imagePath)
                require(source.isFile) { "The OCR input image is missing." }
                val bounds = BitmapFactory.Options().also { options ->
                    options.inJustDecodeBounds = true
                    BitmapFactory.decodeFile(source.path, options)
                }
                require(bounds.outWidth > 0 && bounds.outHeight > 0) {
                    "The OCR input image could not be decoded."
                }
                val options = BitmapFactory.Options().apply {
                    inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
                    inPreferredConfig = android.graphics.Bitmap.Config.ARGB_8888
                }
                bitmap = BitmapFactory.decodeFile(source.path, options)
                    ?: throw IllegalArgumentException("The OCR input image could not be decoded.")
                val input = InputImage.fromBitmap(bitmap, 0)
                val text = Tasks.await(recognizer.process(input))
                onSuccess(
                    mapOf(
                        "fullText" to text.text,
                        "sourcePageId" to sourcePageId,
                        "sourceWidth" to bitmap.width,
                        "sourceHeight" to bitmap.height,
                        "blocks" to text.textBlocks.map(::blockMap),
                    ),
                )
            } catch (error: Throwable) {
                onFailure(error)
            } finally {
                bitmap?.recycle()
            }
        }
    }

    override fun close() {
        executor.shutdownNow()
        recognizer.close()
    }

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (maxOf(width, height) / sample > MAX_OCR_DIMENSION) {
            sample *= 2
        }
        return sample
    }

    private fun blockMap(block: Text.TextBlock): Map<String, Any> =
        mutableMapOf<String, Any>(
            "text" to block.text,
            "language" to block.recognizedLanguage,
            "lines" to block.lines.map(::lineMap),
        ).apply {
            block.boundingBox?.let { put("boundingBox", rectMap(it)) }
        }

    private fun lineMap(line: Text.Line): Map<String, Any> =
        mutableMapOf<String, Any>(
            "text" to line.text,
            "language" to line.recognizedLanguage,
            "confidence" to line.confidence.toDouble(),
        ).apply {
            line.boundingBox?.let { put("boundingBox", rectMap(it)) }
        }

    private fun rectMap(rect: android.graphics.Rect): Map<String, Int> = mapOf(
        "left" to rect.left,
        "top" to rect.top,
        "right" to rect.right,
        "bottom" to rect.bottom,
    )

    private companion object {
        const val MAX_OCR_DIMENSION = 2048
    }
}
