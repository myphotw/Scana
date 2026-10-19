package com.myphotw.scana.pdfeditor

import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QpdfNativeInstrumentedTest {
    @Test
    fun reordersWithoutChangingSource() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, "qpdf_native_test").apply {
            deleteRecursively()
            mkdirs()
        }
        val source = File(directory, "source.pdf")
        val output = File(directory, "output.pdf")
        writePdf(source, listOf(100, 120, 140, 160, 180))
        val original = source.readBytes()

        assertEquals(0, QpdfNative.validate(source.absolutePath))
        assertEquals(
            0,
            QpdfNative.edit(
                source.absolutePath,
                output.absolutePath,
                intArrayOf(3, 1, 5, 2),
            ),
        )
        assertEquals(0, QpdfNative.validate(output.absolutePath))
        assertTrue(output.isFile)
        assertTrue(original.contentEquals(source.readBytes()))
        assertFalse(original.contentEquals(output.readBytes()))

        ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                assertEquals(4, renderer.pageCount)
                val widths = (0 until renderer.pageCount).map { index ->
                    renderer.openPage(index).use { it.width }
                }
                assertEquals(listOf(140, 100, 180, 120), widths)
            }
        }
    }

    private fun writePdf(file: File, widths: List<Int>) {
        val objects = mutableListOf<String>()
        objects += "<< /Type /Catalog /Pages 2 0 R >>"
        val kids = widths.indices.joinToString(" ") { "${it + 3} 0 R" }
        objects += "<< /Type /Pages /Count ${widths.size} /Kids [$kids] >>"
        widths.forEach { width ->
            objects += "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width 200] /Resources << >> >>"
        }
        val builder = StringBuilder("%PDF-1.4\n")
        val offsets = mutableListOf<Int>()
        objects.forEachIndexed { index, value ->
            offsets += builder.toString().toByteArray(StandardCharsets.ISO_8859_1).size
            builder.append("${index + 1} 0 obj\n$value\nendobj\n")
        }
        val xref = builder.toString().toByteArray(StandardCharsets.ISO_8859_1).size
        builder.append("xref\n0 ${objects.size + 1}\n")
        builder.append("0000000000 65535 f \n")
        offsets.forEach { builder.append(String.format("%010d 00000 n \n", it)) }
        builder.append("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R >>\n")
        builder.append("startxref\n$xref\n%%EOF\n")
        file.writeBytes(builder.toString().toByteArray(StandardCharsets.ISO_8859_1))
    }
}
