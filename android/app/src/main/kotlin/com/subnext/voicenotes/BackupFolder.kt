package com.subnext.voicenotes

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

/**
 * The folder backups go to (lib/services/backup_folder.dart). By default
 * Documents/Voice Notes, through MediaStore so no storage permission is
 * needed; or a folder the user picks with the system folder picker, which
 * can be on a cloud storage app that offers folders.
 *
 * Its preferences file is not in backup_rules.xml, so a new phone restored
 * from this one's Android backup gets its own id and does not keep a folder
 * permission it does not have.
 */
class BackupFolder(private val activity: Activity) {
    private val context: Context = activity.applicationContext
    private val prefs = context.getSharedPreferences("backup_folder", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var picking: MethodChannel.Result? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "location" -> result.success(location())
            "device" -> result.success(device())
            "pick" -> pick(result)
            "reset" -> {
                tree()?.let { release(it) }
                prefs.edit().remove("tree").apply()
                result.success(location())
            }
            "write" -> io(result) {
                write(call.argument<String>("name")!!, call.argument<String>("text")!!)
                null
            }
            "list" -> io(result) { list() }
            "read" -> io(result) { read(call.argument<String>("name")!!) }
            else -> result.notImplemented()
        }
    }

    private fun io(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("backup", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun device(): Map<String, String> {
        var id = prefs.getString("id", null)
        if (id == null) {
            id = UUID.randomUUID().toString()
            prefs.edit().putString("id", id).apply()
        }
        val name = Settings.Global.getString(context.contentResolver, "device_name")
            ?.takeIf { it.isNotBlank() } ?: Build.MODEL
        return mapOf("name" to name, "id" to id)
    }

    /** The folder the user picked, while this app may still use it. */
    private fun tree(): Uri? {
        val uri = prefs.getString("tree", null)?.let(Uri::parse) ?: return null
        val held = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        return if (held) uri else null
    }

    private fun location(): Map<String, Any> {
        val t = tree()
        if (t != null) {
            return mapOf("label" to (treeLabel(t) ?: "Chosen folder"), "custom" to true, "syncs" to true)
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            mapOf("label" to "Documents › Voice Notes, on this phone", "custom" to false, "syncs" to false)
        } else {
            mapOf("label" to "This phone (Android › data › Voice Notes)", "custom" to false, "syncs" to false)
        }
    }

    private fun treeLabel(tree: Uri): String? {
        val doc = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        return try {
            context.contentResolver.query(
                doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (e: Exception) {
            null
        }
    }

    private fun pick(result: MethodChannel.Result) {
        if (picking != null) return result.error("busy", "Already choosing a folder", null)
        picking = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        )
        try {
            activity.startActivityForResult(intent, REQUEST)
        } catch (e: Exception) {
            picking = null
            result.error("pick", "No folder picker on this phone", null)
        }
    }

    /** From MainActivity.onActivityResult. Returns whether it was ours. */
    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val result = picking ?: return true
        picking = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        try {
            context.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            tree()?.takeIf { it != uri }?.let { release(it) }
            prefs.edit().putString("tree", uri.toString()).apply()
            result.success(location())
        } catch (e: Exception) {
            result.error("pick", "This app cannot keep using that folder. Choose another.", null)
        }
        return true
    }

    private fun release(uri: Uri) {
        try {
            context.contentResolver.releasePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
        }
    }

    // A file in the folder: where to open it, its name and when it changed (ms).
    private data class Entry(val uri: Uri, val name: String, val modified: Long)

    private fun entries(): List<Entry> {
        val t = tree()
        if (t != null) {
            val parent = DocumentsContract.getTreeDocumentId(t)
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(t, parent)
            val cols = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            val out = ArrayList<Entry>()
            context.contentResolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    if (c.getString(3) == DocumentsContract.Document.MIME_TYPE_DIR) continue
                    out.add(
                        Entry(
                            DocumentsContract.buildDocumentUriUsingTree(t, c.getString(0)),
                            c.getString(1) ?: continue,
                            if (c.isNull(2)) 0 else c.getLong(2),
                        )
                    )
                }
            }
            return out
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val files = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
            val cols = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_MODIFIED,
            )
            val out = ArrayList<Entry>()
            context.contentResolver.query(
                files, cols, "${MediaStore.MediaColumns.RELATIVE_PATH} = ?", arrayOf(RELATIVE_PATH), null
            )?.use { c ->
                while (c.moveToNext()) {
                    out.add(
                        Entry(
                            android.content.ContentUris.withAppendedId(files, c.getLong(0)),
                            c.getString(1) ?: continue,
                            c.getLong(2) * 1000,
                        )
                    )
                }
            }
            return out
        }
        return legacyDir().listFiles()?.filter { it.isFile }?.map {
            Entry(Uri.fromFile(it), it.name, it.lastModified())
        } ?: emptyList()
    }

    private fun legacyDir(): File {
        val base = context.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: context.filesDir
        return File(base, "Voice Notes").apply { mkdirs() }
    }

    private fun list(): List<Map<String, Any>> =
        entries().map { mapOf("name" to it.name, "modified" to it.modified) }

    private fun read(name: String): String {
        val e = entries().firstOrNull { it.name == name } ?: throw IllegalStateException("$name is gone")
        return context.contentResolver.openInputStream(e.uri)!!.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private fun write(name: String, text: String) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val existing = entries().firstOrNull { it.name == name }
        val t = tree()
        val target = existing?.uri ?: when {
            t != null -> DocumentsContract.createDocument(
                context.contentResolver,
                DocumentsContract.buildDocumentUriUsingTree(t, DocumentsContract.getTreeDocumentId(t)),
                "application/json",
                name,
            ) ?: throw IllegalStateException("Could not create $name in the chosen folder")
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> context.contentResolver.insert(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "application/json")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
                },
            ) ?: throw IllegalStateException("Could not create $name in Documents")
            else -> {
                File(legacyDir(), name).writeBytes(bytes)
                return
            }
        }
        // "wt" truncates, so a shorter backup leaves no old bytes behind.
        context.contentResolver.openOutputStream(target, "wt")!!.use { it.write(bytes) }
    }

    companion object {
        private const val REQUEST = 4711
        private const val RELATIVE_PATH = "Documents/Voice Notes/"
    }
}
