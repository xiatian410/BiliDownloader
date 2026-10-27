package io.github.xiatian410.bili_downloader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var picker: MethodChannel.Result? = null
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "bili_downloader/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    if (picker != null) result.error("busy", "A folder picker is already open", null)
                    else {
                        picker = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                        )
                        startActivityForResult(intent, 410)
                    }
                }
                "publishFile" -> io.execute {
                    var created: Uri? = null
                    try {
                        val source = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                        val allowed = listOfNotNull(filesDir, getExternalFilesDir(null)).map { it.canonicalPath + File.separator }
                        require(allowed.any { source.path.startsWith(it) }) { "Source is outside application storage" }
                        val tree = Uri.parse(requireNotNull(call.argument<String>("tree")))
                        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                        val folder = requireNotNull(call.argument<String>("folder"))
                        val name = requireNotNull(call.argument<String>("name"))
                        require(!folder.contains('/') && !name.contains('/') && folder != ".." && name != "..")
                        val directory = child(root, tree, folder) ?: DocumentsContract.createDocument(contentResolver, root, DocumentsContract.Document.MIME_TYPE_DIR, folder)
                            ?: error("Cannot create destination folder")
                        check(child(directory, tree, name) == null) { "Destination already exists" }
                        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(source.extension.lowercase()) ?: "application/octet-stream"
                        created = DocumentsContract.createDocument(contentResolver, directory, mime, name) ?: error("Cannot create destination file")
                        contentResolver.openOutputStream(created, "w")!!.use { output -> source.inputStream().use { it.copyTo(output) } }
                        val uri = created.toString()
                        runOnUiThread { result.success(uri) }
                    } catch (e: Exception) {
                        created?.let { try { DocumentsContract.deleteDocument(contentResolver, it) } catch (_: Exception) {} }
                        runOnUiThread { result.error("saveFailed", e.message, null) }
                    }
                }
                "openDirectory" -> {
                    try {
                        val path = requireNotNull(call.argument<String>("path"))
                        if (!path.startsWith("content://")) {
                            result.error("openFailed", "Choose a system folder in Settings to export downloads", null)
                        } else {
                            val uri = Uri.parse(path)
                            val doc = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
                            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(doc, DocumentsContract.Document.MIME_TYPE_DIR).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success(null)
                        }
                    } catch (e: Exception) { result.error("openFailed", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun child(parent: Uri, tree: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(1) == name) return DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0))
        }
        return null
    }

    @Deprecated("Activity result API used by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 410) return
        val result = picker ?: return
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        try {
            contentResolver.takePersistableUriPermission(uri, data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            result.success(uri.toString())
        } catch (e: Exception) { result.error("permission", e.message, null) }
    }

    override fun onDestroy() {
        picker?.error("closed", "Activity closed", null)
        picker = null
        io.shutdown()
        super.onDestroy()
    }
}
