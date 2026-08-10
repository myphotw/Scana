package com.myphotw.scana

import com.myphotw.scana.imageprocessing.OpenCvDocumentDetector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val detectorExecutor = Executors.newSingleThreadExecutor()
    private var detectorChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        detectorChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                DOCUMENT_DETECTOR_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "detectDocument") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }

                    val imagePath = call.argument<String>("imagePath")
                    if (imagePath.isNullOrBlank()) {
                        result.error("invalid_path", "An image path is required.", null)
                        return@setMethodCallHandler
                    }

                    detectorExecutor.execute {
                        try {
                            val detection = OpenCvDocumentDetector.detect(imagePath)
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
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        detectorChannel?.setMethodCallHandler(null)
        detectorChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        detectorExecutor.shutdown()
        super.onDestroy()
    }

    private companion object {
        const val DOCUMENT_DETECTOR_CHANNEL = "com.myphotw.scana/document_detector"
    }
}
