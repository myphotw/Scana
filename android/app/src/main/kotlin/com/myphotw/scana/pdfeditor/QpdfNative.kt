package com.myphotw.scana.pdfeditor

internal object QpdfNative {
    init {
        System.loadLibrary("scana_qpdf")
    }

    fun validate(inputPath: String): Int = validateNative(inputPath)

    fun edit(inputPath: String, outputPath: String, pageNumbers: IntArray): Int =
        editNative(inputPath, outputPath, pageNumbers)

    private external fun validateNative(inputPath: String): Int

    private external fun editNative(
        inputPath: String,
        outputPath: String,
        pageNumbers: IntArray,
    ): Int
}
