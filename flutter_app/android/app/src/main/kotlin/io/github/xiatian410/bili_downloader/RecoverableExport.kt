package io.github.xiatian410.bili_downloader

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.Properties

class ExportFailure(val code: String) : Exception(code)

data class ExportDocument(val uri: String, val name: String)

interface ExportDocuments {
    fun find(name: String): ExportDocument?
    fun create(name: String): ExportDocument
    fun describe(uri: String): ExportDocument
    fun read(uri: String): InputStream
    fun rewrite(uri: String): OutputStream
    fun delete(uri: String)
}

interface ExportJournal {
    fun read(id: String): ExportRecord?
    fun write(record: ExportRecord)
}

private fun digest(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

data class ExportRecord(
    val id: String,
    val size: Long,
    val sha256: String,
    val name: String,
    val uri: String? = null,
    val complete: Boolean = false,
) {
    fun encode(): ByteArray {
        val fields = Properties().also { fields ->
            fields.setProperty("id", id)
            fields.setProperty("size", size.toString())
            fields.setProperty("sha256", sha256)
            fields.setProperty("name", name)
            fields.setProperty("uri", uri ?: "")
            fields.setProperty("complete", complete.toString())
        }
        val payload = ByteArrayOutputStream().also { fields.store(it, null) }.toByteArray()
        val bytes = "BILI_EXPORT_1\n${digest(payload)}\n".toByteArray(Charsets.US_ASCII) + payload
        if (bytes.size > MAX_BYTES) throw ExportFailure("exportHistoryWriteFailed")
        return bytes
    }

    companion object {
        const val MAX_BYTES = 64 * 1024
        fun decode(bytes: ByteArray, expectedId: String): ExportRecord {
            try {
                require(bytes.size <= MAX_BYTES)
                val headerLength = "BILI_EXPORT_1\n".length + 65
                require(bytes.size > headerLength)
                val header = bytes.copyOfRange(0, headerLength).toString(Charsets.US_ASCII)
                val payload = bytes.copyOfRange(headerLength, bytes.size)
                require(header == "BILI_EXPORT_1\n${digest(payload)}\n")
                val fields = Properties().apply { payload.inputStream().use { load(it) } }
                require(fields.getProperty("id") == expectedId && expectedId.matches(Regex("[a-f0-9]{64}")))
                val size = fields.getProperty("size").toLong()
                val hash = fields.getProperty("sha256")
                val name = fields.getProperty("name")
                val complete = fields.getProperty("complete")
                val uri = fields.getProperty("uri").ifEmpty { null }
                require(size >= 0 && hash.matches(Regex("[a-f0-9]{64}")))
                require(name.isNotEmpty() && complete in listOf("true", "false"))
                require(complete != "true" || uri != null)
                return ExportRecord(expectedId, size, hash, name, uri, complete == "true")
            } catch (e: Exception) {
                throw ExportFailure("exportHistoryCorrupt")
            }
        }
    }
}

/** The caller serializes operations. Never infer ownership from a filename. */
class RecoverableExport(private val journal: ExportJournal) {
    private fun save(record: ExportRecord) {
        try { journal.write(record) } catch (e: Exception) { throw ExportFailure("exportHistoryWriteFailed") }
    }

    fun publish(source: File, destinationIdentity: String, name: String, documents: ExportDocuments): String {
        require(source.isFile && name.isNotEmpty())
        val size = source.length()
        val expectedHash = hash(source.inputStream(), size) ?: throw ExportFailure("exportSourceChanged")
        val id = digest(listOf(source.canonicalPath, destinationIdentity, name, size.toString(), expectedHash)
            .joinToString("\u0000").toByteArray(Charsets.UTF_8))
        var record = try { journal.read(id) } catch (e: ExportFailure) { throw e }
            catch (e: Exception) { throw ExportFailure("exportHistoryCorrupt") }
        if (record == null) {
            if (documents.find(name) != null) throw ExportFailure("fileExists")
            record = ExportRecord(id, size, expectedHash, name)
            save(record)
        }
        if (record.size != size || record.sha256 != expectedHash || record.name != name) {
            throw ExportFailure("exportHistoryCorrupt")
        }
        if (record.uri == null) {
            // A crash during createDocument may leave a document whose URI was
            // never committed. Preserve it: its name alone cannot prove ownership.
            if (documents.find(name) != null) throw ExportFailure("exportConflict")
            val created = documents.create(name)
            try {
                if (created.name != name) throw ExportFailure("exportConflict")
                record = record.copy(uri = created.uri)
                save(record)
            } catch (e: Exception) {
                // No media bytes have been written; this newly returned URI is ours.
                try { documents.delete(created.uri) } catch (_: Exception) { }
                throw e
            }
        }
        val uri = record.uri!!
        if (documents.describe(uri).name != name) throw ExportFailure("exportConflict")
        val presentHash = hash(documents.read(uri), size)
        if (presentHash == expectedHash) {
            if (!record.complete) save(record.copy(complete = true))
            return uri
        }
        if (record.complete) throw ExportFailure("exportConflict")
        // A partially copied document must still be a prefix of this exact source.
        // External edits or a provider's reused document ID must not be overwritten.
        if (!isPrefix(documents.read(uri), source, size)) throw ExportFailure("exportConflict")
        documents.rewrite(uri).use { output ->
            val copied = MessageDigest.getInstance("SHA-256")
            var count = 0L
            source.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buffer)
                    if (n == -1) break
                    if (n == 0 || count + n > size) throw ExportFailure("exportSourceChanged")
                    output.write(buffer, 0, n)
                    copied.update(buffer, 0, n)
                    count += n
                }
            }
            if (count != size || hex(copied.digest()) != expectedHash) throw ExportFailure("exportSourceChanged")
            output.flush()
        }
        // A provider may ignore truncation, transform data or fail while closing.
        // Only read-back of the complete bytes can commit a successful export.
        if (hash(documents.read(uri), size) != expectedHash) throw ExportFailure("exportVerificationFailed")
        save(record.copy(complete = true))
        return uri
    }

    private fun hash(input: InputStream, expectedSize: Long): String? = input.use {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var count = 0L
        while (true) {
            val n = it.read(buffer)
            if (n == -1) break
            if (n == 0 || count + n > expectedSize) return@use null
            count += n
            digest.update(buffer, 0, n)
        }
        if (count == expectedSize) hex(digest.digest()) else null
    }

    private fun isPrefix(input: InputStream, source: File, limit: Long): Boolean = input.use { existing ->
        DataInputStream(source.inputStream()).use original@ { original ->
            val left = ByteArray(64 * 1024)
            val right = ByteArray(64 * 1024)
            var count = 0L
            while (true) {
                val n = existing.read(left)
                if (n == -1) break
                if (n == 0 || count + n > limit) return@original false
                original.readFully(right, 0, n)
                for (i in 0 until n) if (left[i] != right[i]) return@original false
                count += n
            }
            true
        }
    }
}
