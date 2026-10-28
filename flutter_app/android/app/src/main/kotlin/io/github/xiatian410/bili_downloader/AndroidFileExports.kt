package io.github.xiatian410.bili_downloader

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.AtomicFile
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.util.concurrent.Executors

/** One writer per process, including Activity replacement. No Activity is retained. */
object AndroidFileExports {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun publish(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val app = context.applicationContext
        io.execute {
            try {
                val source = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                val allowed = listOfNotNull(app.filesDir, app.getExternalFilesDir(null))
                    .map { it.canonicalPath + File.separator }
                require(allowed.any { source.path.startsWith(it) } && source.isFile)
                val tree = Uri.parse(requireNotNull(call.argument<String>("tree")))
                require(tree.scheme == "content")
                val folder = requireNotNull(call.argument<String>("folder"))
                val name = requireNotNull(call.argument<String>("name"))
                fun valid(value: String) = value !in listOf(".", "..") &&
                    !value.contains('/') && !value.contains('\\') && !value.contains('\u0000')
                require(valid(folder) && valid(name) && name.isNotEmpty())
                val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                val resolver = app.contentResolver
                fun documentInfo(uri: Uri): ExportDocument {
                    val cursor = resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                        ?: throw ExportFailure("exportProviderUnavailable")
                    return cursor.use {
                        if (!it.moveToFirst()) throw FileNotFoundException("Export document is missing")
                        ExportDocument(uri.toString(), it.getString(0))
                    }
                }
                fun child(parent: Uri, childName: String): Uri? {
                    val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
                    val cursor = resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                        ?: throw ExportFailure("exportProviderUnavailable")
                    return cursor.use {
                        while (it.moveToNext()) if (it.getString(1) == childName) {
                            return@use DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(0))
                        }
                        null
                    }
                }
                val directory = if (folder.isEmpty()) root else child(root, folder)
                    ?: DocumentsContract.createDocument(resolver, root, DocumentsContract.Document.MIME_TYPE_DIR, folder)
                    ?: throw ExportFailure("saveFailed")
                if (resolver.getType(directory) != DocumentsContract.Document.MIME_TYPE_DIR) throw ExportFailure("exportConflict")
                if (folder.isNotEmpty() && documentInfo(directory).name != folder) throw ExportFailure("exportConflict")
                val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(source.extension.lowercase()) ?: "application/octet-stream"
                val documents = object : ExportDocuments {
                    override fun find(name: String) = child(directory, name)?.let { documentInfo(it) }
                    override fun describe(uri: String) = documentInfo(Uri.parse(uri))
                    override fun create(name: String): ExportDocument {
                        val uri = DocumentsContract.createDocument(resolver, directory, mime, name)
                            ?: throw ExportFailure("saveFailed")
                        return documentInfo(uri)
                    }
                    override fun read(uri: String) = resolver.openInputStream(Uri.parse(uri))
                        ?: throw ExportFailure("exportProviderUnavailable")
                    override fun rewrite(uri: String) = resolver.openOutputStream(Uri.parse(uri), "wt")
                        ?: throw ExportFailure("exportProviderUnavailable")
                    override fun delete(uri: String) { check(DocumentsContract.deleteDocument(resolver, Uri.parse(uri))) }
                }
                val journalDirectory = File(app.filesDir, "export-journal")
                check(journalDirectory.isDirectory || journalDirectory.mkdirs())
                val journal = object : ExportJournal {
                    private fun file(id: String) = AtomicFile(File(journalDirectory, "$id.state"))
                    override fun read(id: String): ExportRecord? {
                        val atomic = file(id)
                        if (!atomic.baseFile.exists() && !File(journalDirectory, "$id.state.bak").exists()) return null
                        val bytes = atomic.openRead().use { it.readBytesBounded(ExportRecord.MAX_BYTES) }
                        return ExportRecord.decode(bytes, id)
                    }
                    override fun write(record: ExportRecord) {
                        val atomic = file(record.id)
                        var stream: FileOutputStream? = null
                        try {
                            stream = atomic.startWrite()
                            stream.write(record.encode())
                            stream.fd.sync()
                            atomic.finishWrite(stream)
                            stream = null
                            // Some platform I/O failures are logged by AtomicFile;
                            // verify the committed record before writing media bytes.
                            val committed = atomic.openRead().use { it.readBytesBounded(ExportRecord.MAX_BYTES) }
                            check(ExportRecord.decode(committed, record.id) == record)
                        } catch (e: Exception) {
                            if (stream != null) atomic.failWrite(stream)
                            throw e
                        }
                    }
                }
                val uri = RecoverableExport(journal).publish(source, "$tree\u0000$folder", name, documents)
                main.post { result.success(uri) }
            } catch (e: Exception) {
                val code = when (e) {
                    is ExportFailure -> e.code
                    is SecurityException -> "exportPermissionLost"
                    is FileNotFoundException -> "outputMissing"
                    else -> "saveFailed"
                }
                main.post { result.error(code, code, null) }
            }
        }
    }

    private fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
        val result = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val n = read(buffer)
            if (n == -1) return result.toByteArray()
            if (n == 0 || result.size() + n > limit) throw ExportFailure("exportHistoryCorrupt")
            result.write(buffer, 0, n)
        }
    }
}
