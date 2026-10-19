package com.myphotw.scana.pdfeditor

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PdfPageOrderPolicyTest {
    @Test
    fun acceptsOneFiveTwentyAndOneHundredPageOrders() {
        for (count in listOf(1, 5, 20, 100)) {
            val zeroBased = (count - 1 downTo 0).toList()
            val expected = (count downTo 1).toList().toIntArray()
            assertArrayEquals(
                expected,
                PdfPageOrderPolicy.toOneBased(zeroBased, count),
            )
        }
    }

    @Test
    fun rejectsEmptyDuplicateAndOutOfRangeOrders() {
        assertThrows(IllegalArgumentException::class.java) {
            PdfPageOrderPolicy.toOneBased(emptyList(), 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PdfPageOrderPolicy.toOneBased(listOf(0, 0), 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PdfPageOrderPolicy.toOneBased(listOf(5), 5)
        }
        assertThrows(IllegalArgumentException::class.java) {
            PdfPageOrderPolicy.toOneBased(listOf(0), 0)
        }
    }
}
