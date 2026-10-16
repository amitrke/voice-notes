package com.subnext.voicenotes

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File

/**
 * Audio and video another app shared to Voice Notes (the Android share sheet).
 *
 * The shared content URIs are only readable while we hold the intent, so each
 * one is copied into the cache folder right away; Dart then imports the copies.
 */
object SharedAudio {
    /** Copies of the files in [intent], or an empty list if it shares none. */
    fun copyFrom(context: Context, intent: Intent?): List<String> {
        if (intent == null) return emptyList()
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(streamOf(intent))
            Intent.ACTION_SEND_MULTIPLE -> streamsOf(intent)
            else -> emptyList()
        }
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        val copies = ArrayList<String>()
        for (uri in uris) {
            try {
                copies.add(copy(context.contentResolver, uri, dir).absolutePath)
            } catch (e: Exception) {
                // One unreadable file should not lose the others.
            }
        }
        return copies
    }

    @Suppress("DEPRECATION")
    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun streamsOf(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }) ?: emptyList()

    private fun copy(resolver: ContentResolver, uri: Uri, dir: File): File {
        val dest = File(dir, "${System.currentTimeMillis()}_${displayName(resolver, uri)}")
        resolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "cannot open $uri" }
            dest.outputStream().use { out -> input.copyTo(out) }
        }
        return dest
    }

    /** The shared file's own name, made safe, with an extension the decoder can use. */
    private fun displayName(resolver: ContentResolver, uri: Uri): String {
        var name: String? = null
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0)
        }
        var safe = (name ?: "shared").replace(Regex("[^A-Za-z0-9._ -]"), "_")
        if (!safe.contains('.')) {
            val ext = MimeTypeMap.getSingleton()
                .getExtensionFromMimeType(resolver.getType(uri))
            safe += "." + (ext ?: "m4a")
        }
        return safe
    }
}
