package com.subnext.voicenotes

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val main = Handler(Looper.getMainLooper())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.subnext.voicenotes/audio")
            .setMethodCallHandler { call, result ->
                if (call.method != "toWav16kMono") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val src = call.argument<String>("src")
                val dest = call.argument<String>("dest")
                if (src == null || dest == null) {
                    result.error("args", "src and dest are required", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        AudioConverter.toWav16kMono(src, dest)
                        main.post { result.success(dest) }
                    } catch (e: Exception) {
                        main.post { result.error("convert", e.message, null) }
                    }
                }.start()
            }
    }
}
