package io.github.xiatian410.bili_downloader

import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.io.FilterOutputStream
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class DiskJournal(private val root: File, private val crash: String = "") : ExportJournal {
    var beforeWrite: ((ExportRecord) -> Unit)? = null
    override fun read(id: String) = File(root, "$id.state").takeIf { it.exists() }
        ?.let { ExportRecord.decode(it.readBytes(), id) }
    override fun write(record: ExportRecord) {
        beforeWrite?.invoke(record)
        if (record.complete && crash == "beforeReceipt") Runtime.getRuntime().halt(73)
        FileOutputStream(File(root, "${record.id}.state")).use { it.write(record.encode()); it.fd.sync() }
        if (record.complete && crash == "afterReceipt") Runtime.getRuntime().halt(73)
    }
}

class DiskDocuments(private val root: File, private val crash: String = "") : ExportDocuments {
    var creates = 0
    var rewrites = 0
    var append = false
    var adjustName = false
    var afterCreate: (() -> Unit)? = null
    private fun file(uri: String) = File(java.net.URI(uri))
    override fun find(name: String) = File(root, name).takeIf { it.exists() }?.let { describe(it.toURI().toString()) }
    override fun create(name: String): ExportDocument {
        creates++
        val file = File(root, if (adjustName) "$name (1)" else name)
        check(file.createNewFile())
        if (crash == "create") Runtime.getRuntime().halt(73)
        afterCreate?.invoke()
        return describe(file.toURI().toString())
    }
    override fun describe(uri: String): ExportDocument {
        check(file(uri).isFile)
        return ExportDocument(uri, file(uri).name)
    }
    override fun read(uri: String) = file(uri).inputStream()
    override fun rewrite(uri: String): java.io.OutputStream {
        rewrites++
        val stream = FileOutputStream(file(uri), append)
        return object : FilterOutputStream(stream) {
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                if (crash == "copy") {
                    stream.write(bytes, offset, minOf(4096, length))
                    stream.fd.sync()
                    Runtime.getRuntime().halt(73)
                }
                stream.write(bytes, offset, length)
            }
        }
    }
    override fun delete(uri: String) { check(file(uri).delete()) }
}

/** Independent JVM termination: no catch/finally blocks run in the killed copy. */
object ExportCrashProbe {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args[0])
        RecoverableExport(DiskJournal(root, args[1])).publish(File(root, "source.bin"), "tree/folder",
            "saved.bin", DiskDocuments(File(root, "destination"), args[1]))
        error("Crash injection did not execute")
    }
}

class RecoverableExportTest {
    private lateinit var root: File
    private lateinit var source: File
    private lateinit var destination: File
    private lateinit var journal: DiskJournal
    private lateinit var documents: DiskDocuments
    private val bytes = ByteArray(131073) { (it % 251).toByte() }
    @Before fun prepare() {
        root = Files.createTempDirectory("bili-export-test-").toFile()
        source = File(root, "source.bin").apply { writeBytes(bytes) }
        destination = File(root, "destination").apply { mkdir() }
        journal = DiskJournal(root)
        documents = DiskDocuments(destination)
    }
    @After fun cleanup() { root.deleteRecursively() }
    private fun publish() = RecoverableExport(journal).publish(source, "tree/folder", "saved.bin", documents)
    private fun failure(code: String, action: () -> Unit) {
        try { action(); fail("Expected $code") } catch (e: ExportFailure) { assertEquals(code, e.code) }
    }
    private fun crash(stage: String) {
        val classpath = listOf(ExportCrashProbe::class.java, RecoverableExport::class.java, kotlin.Unit::class.java)
            .map { File(it.protectionDomain.codeSource.location.toURI()).path }.distinct().joinToString(File.pathSeparator)
        val process = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").path,
            "-cp", classpath, ExportCrashProbe::class.java.name, root.path, stage)
            .redirectErrorStream(true).redirectOutput(File(root, "probe.log")).start()
        try {
            assertTrue("Crash probe timeout", process.waitFor(15, TimeUnit.SECONDS))
            assertEquals(File(root, "probe.log").readText(), 73, process.exitValue())
        } finally { if (process.isAlive) process.destroyForcibly() }
        journal = DiskJournal(root)
        documents = DiskDocuments(destination)
    }

    @Test fun completedReceiptReusesVerifiedFileWithoutCopyingAgain() {
        val uri = publish()
        assertArrayEquals(bytes, File(java.net.URI(uri)).readBytes())
        assertEquals(uri, publish())
        assertEquals(1, documents.creates)
        assertEquals(1, documents.rewrites)
        assertTrue(source.exists())
    }
    @Test fun killedCopyRestartsFromThePreservedSourceAndReusesOnlyItsKnownUri() {
        crash("copy")
        assertEquals(4096L, File(destination, "saved.bin").length())
        publish()
        assertArrayEquals(bytes, File(destination, "saved.bin").readBytes())
        assertEquals(0, documents.creates)
        assertEquals(1, documents.rewrites)
        assertArrayEquals(bytes, source.readBytes())
    }
    @Test fun killedBeforeReceiptCommitVerifiesExistingCompleteBytesWithoutCopying() {
        crash("beforeReceipt")
        publish()
        assertEquals(0, documents.creates)
        assertEquals(0, documents.rewrites)
        assertArrayEquals(bytes, File(destination, "saved.bin").readBytes())
    }
    @Test fun killedAfterReceiptCommitReturnsTheSameOutputWithoutCopying() {
        crash("afterReceipt")
        publish()
        assertEquals(0, documents.creates)
        assertEquals(0, documents.rewrites)
    }
    @Test fun unknownDocumentAfterCreateCrashIsPreservedInsteadOfClaimedByName() {
        crash("create")
        failure("exportConflict") { publish() }
        assertEquals(0, documents.creates)
        assertEquals(0, documents.rewrites)
        assertTrue(File(destination, "saved.bin").exists())
        assertArrayEquals(bytes, source.readBytes())
    }
    @Test fun unrelatedExistingDocumentIsNeverOverwrittenEvenIfItsContentMatches() {
        File(destination, "saved.bin").writeBytes(bytes)
        failure("fileExists") { publish() }
        assertEquals(0, documents.rewrites)
        assertEquals(0, documents.creates)
    }
    @Test fun changedPartialDocumentIsPreserved() {
        crash("copy")
        val target = File(destination, "saved.bin")
        target.writeText("external edit")
        failure("exportConflict") { publish() }
        assertEquals("external edit", target.readText())
        assertEquals(0, documents.rewrites)
    }
    @Test fun changedCompletedDocumentIsPreserved() {
        publish()
        val target = File(destination, "saved.bin")
        target.writeText("external edit")
        failure("exportConflict") { publish() }
        assertEquals("external edit", target.readText())
        assertEquals(1, documents.rewrites)
    }
    @Test fun historyFailurePreventsCopyAndCleansOnlyTheFreshEmptyDocument() {
        journal.beforeWrite = { if (it.uri != null) throw java.io.IOException("history full") }
        failure("exportHistoryWriteFailed") { publish() }
        assertEquals(0, documents.rewrites)
        assertFalse(File(destination, "saved.bin").exists())
        assertArrayEquals(bytes, source.readBytes())
        journal.beforeWrite = null
        publish()
    }
    @Test fun corruptHistoryStopsBeforeAnyDestinationMutation() {
        crash("copy")
        val state = root.listFiles()!!.single { it.extension == "state" }
        val corrupt = state.readBytes().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        state.writeBytes(corrupt)
        failure("exportHistoryCorrupt") { publish() }
        assertEquals(0, documents.rewrites)
        assertEquals(4096L, File(destination, "saved.bin").length())
    }
    @Test fun providerFilenameAdjustmentDoesNotSilentlyChangeThePlannedName() {
        documents.adjustName = true
        failure("exportConflict") { publish() }
        assertTrue(destination.listFiles()!!.isEmpty())
        assertEquals(0, documents.rewrites)
    }
    @Test fun providerIgnoringTruncationFailsReadBackVerification() {
        crash("copy")
        documents.append = true
        failure("exportVerificationFailed") { publish() }
        assertTrue(source.exists())
    }
    @Test fun sourceMutationDuringExportDoesNotCommitSuccess() {
        documents.afterCreate = { source.writeBytes(ByteArray(bytes.size) { 99 }) }
        failure("exportSourceChanged") { publish() }
        assertTrue(source.exists())
    }
    @Test fun receiptCodecPreservesUnicodeAndRejectsWrongIdentityOrOversizedRecords() {
        val record = ExportRecord("1".repeat(64), 3, "2".repeat(64), "字幕\n&.srt", "content://fixture/document/1", true)
        assertEquals(record, ExportRecord.decode(record.encode(), record.id))
        failure("exportHistoryCorrupt") { ExportRecord.decode(record.encode(), "3".repeat(64)) }
        failure("exportHistoryCorrupt") { ExportRecord.decode(ByteArray(ExportRecord.MAX_BYTES + 1), record.id) }
    }
}
