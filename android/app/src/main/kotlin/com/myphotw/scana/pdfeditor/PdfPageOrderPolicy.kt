package com.myphotw.scana.pdfeditor

internal object PdfPageOrderPolicy {
    fun toOneBased(pageOrder: List<Int>, originalPageCount: Int): IntArray {
        require(originalPageCount > 0) { "The source PDF has no pages." }
        require(pageOrder.isNotEmpty()) { "All PDF pages cannot be deleted." }
        require(pageOrder.distinct().size == pageOrder.size) {
            "Duplicate PDF pages are not allowed."
        }
        require(pageOrder.all { it in 0 until originalPageCount }) {
            "A PDF page index is out of range."
        }
        return pageOrder.map { it + 1 }.toIntArray()
    }
}
