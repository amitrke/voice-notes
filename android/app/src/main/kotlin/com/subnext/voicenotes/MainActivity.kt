package com.subnext.voicenotes

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var share: MethodChannel? = null

    /** Copies of shared files not yet taken by Dart. Touched on the main thread only. */
    private val pendingShared = ArrayList<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

        // Dart asks for shared files when it starts, and is told when more arrive.
        share = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.subnext.voicenotes/share")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method == "take") {
                        result.success(ArrayList(pendingShared))
                        pendingShared.clear()
                    } else {
                        result.notImplemented()
                    }
                }
            }
        receiveShared(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        receiveShared(intent)
    }

    private fun receiveShared(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND && intent?.action != Intent.ACTION_SEND_MULTIPLE) return
        Thread {
            val copies = SharedAudio.copyFrom(applicationContext, intent)
            if (copies.isEmpty()) return@Thread
            main.post {
                pendingShared.addAll(copies)
                share?.invokeMethod("shared", null)
            }
        }.start()
    }
}
