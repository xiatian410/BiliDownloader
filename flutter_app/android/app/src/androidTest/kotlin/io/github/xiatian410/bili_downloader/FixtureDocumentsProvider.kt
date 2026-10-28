package io.github.xiatian410.bili_downloader

import android.app.Activity
import android.content.Intent
import android.database.MatrixCursor
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.os.ResultReceiver
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Grants only this test APK's synthetic tree, using normal Android URI grants. */
class FixtureGrantActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val tree = DocumentsContract.buildTreeDocumentUri(
            "io.github.xiatian410.bili_downloader.test.documents", "root")
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        for (target in listOf("io.github.xiatian410.bili_downloader", "com.android.shell")) {
            grantUriPermission(target, tree, flags)
        }
        @Suppress("DEPRECATION")
        val result = intent.getParcelableExtra<ResultReceiver>("grantResult")
        result?.send(RESULT_OK, null)
        finish()
    }
}

/** Test APK provider: actual Binder/file-descriptor traffic, only synthetic data. */
class FixtureDocumentsProvider : DocumentsProvider() {
    private val root get() = File(context!!.filesDir, "documents").apply { mkdirs() }
    private val preferences get() = context!!.getSharedPreferences("fixture", 0)
    private val held = CountDownLatch(1)
    override fun onCreate() = true
    private fun file(id: String): File {
        if (id == "root") return root
        require(id.startsWith("root/"))
        return File(root, id.removePrefix("root/")).canonicalFile.also {
            require(it.path.startsWith(root.canonicalPath + File.separator))
        }
    }
    private fun id(file: File) = if (file == root) "root" else "root/${file.relativeTo(root).path}"
    override fun queryRoots(projection: Array<out String>?) = MatrixCursor(projection ?: arrayOf(
        DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_DOCUMENT_ID,
        DocumentsContract.Root.COLUMN_TITLE, DocumentsContract.Root.COLUMN_FLAGS)).apply {
        addRow(columnNames.map { when (it) {
            DocumentsContract.Root.COLUMN_ROOT_ID, DocumentsContract.Root.COLUMN_DOCUMENT_ID -> "root"
            DocumentsContract.Root.COLUMN_TITLE -> "BiliDownloader test files"
            DocumentsContract.Root.COLUMN_FLAGS -> DocumentsContract.Root.FLAG_SUPPORTS_CREATE
            else -> null
        } }.toTypedArray<Any?>())
    }
    private fun cursor(projection: Array<out String>?) = MatrixCursor(projection ?: arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_FLAGS))
    private fun add(cursor: MatrixCursor, file: File) {
        cursor.addRow(cursor.columnNames.map { when (it) {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> id(file)
            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> file.name
            DocumentsContract.Document.COLUMN_MIME_TYPE -> if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
            DocumentsContract.Document.COLUMN_SIZE -> file.length()
            DocumentsContract.Document.COLUMN_FLAGS -> if (file.isDirectory) DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE else DocumentsContract.Document.FLAG_SUPPORTS_WRITE
            "fixture_writes" -> preferences.getInt("writes", 0)
            "fixture_held" -> if (preferences.getBoolean("held", false)) 1 else 0
            else -> null
        } }.toTypedArray<Any?>())
    }
    override fun queryDocument(documentId: String, projection: Array<out String>?) = cursor(projection).apply {
        val target = file(documentId)
        if (target.exists()) add(this, target)
    }
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?) = cursor(projection).apply {
        for (child in file(parentDocumentId).listFiles() ?: emptyArray()) add(this, child)
    }
    override fun isChildDocument(parentDocumentId: String, documentId: String) =
        file(documentId).path.startsWith(file(parentDocumentId).path + File.separator)
    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        require(!displayName.contains('/') && displayName !in listOf(".", ".."))
        val target = File(file(parentDocumentId), displayName)
        check(if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) target.mkdir() else target.createNewFile())
        return id(target)
    }
    override fun deleteDocument(documentId: String) { require(documentId != "root"); check(file(documentId).deleteRecursively()) }
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        val target = file(documentId)
        if (mode.contains('w')) {
            if (target.name.startsWith("denied-")) throw SecurityException("Fixture revoked access")
            preferences.edit().putInt("writes", preferences.getInt("writes", 0) + 1).commit()
            val interrupt = target.name.startsWith("interrupt-") || target.name == "process-death.bin"
            if (interrupt && !preferences.getBoolean("failed:$documentId", false)) {
                preferences.edit().putBoolean("failed:$documentId", true).commit()
                val pipe = ParcelFileDescriptor.createReliablePipe()
                Thread {
                    try {
                        ParcelFileDescriptor.AutoCloseInputStream(pipe[0]).use { input ->
                            FileOutputStream(target).use { output ->
                                val prefix = ByteArray(4096)
                                var read = 0
                                while (read < prefix.size) {
                                    val n = input.read(prefix, read, prefix.size - read)
                                    check(n > 0)
                                    read += n
                                }
                                output.write(prefix)
                                output.fd.sync()
                                if (target.name == "process-death.bin") {
                                    preferences.edit().putBoolean("held", true).commit()
                                    // The host force-stops the target app, then resumes it.
                                    // This bounded wait exists only inside the synthetic provider.
                                    held.await(60, TimeUnit.SECONDS)
                                }
                                pipe[0].closeWithError("Fixture copy interrupted")
                            }
                        }
                    } catch (_: Exception) { try { pipe[0].close() } catch (_: Exception) { } }
                }.apply { isDaemon = true; start() }
                return pipe[1]
            }
            if (target.name == "process-death.bin") held.countDown()
        }
        return ParcelFileDescriptor.open(target, ParcelFileDescriptor.parseMode(mode))
    }
}
