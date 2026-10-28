package io.github.xiatian410.bili_downloader

import android.content.Context
import android.content.Intent
import android.app.Activity
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object DeviceExportFixture {
    const val authority = "io.github.xiatian410.bili_downloader.test.documents"
    val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    val tree: Uri get() = DocumentsContract.buildTreeDocumentUri(authority, "root")
    val bytes = ByteArray(131073) { (it % 251).toByte() }
    val report = JSONObject()
    fun source(name: String) = File(context.filesDir, "device-export/$name").apply { parentFile!!.mkdirs() }
    private fun ensureGrant() {
        if (context.contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }) return
        // Instrumentation force-stops the target at startup. Grant afterwards, as
        // the real picker would, and acknowledge via Binder instead of a delay.
        val ready = CountDownLatch(1)
        var accepted = false
        val receiver = object : ResultReceiver(Handler(Looper.getMainLooper())) {
            override fun onReceiveResult(code: Int, data: Bundle?) {
                accepted = code == Activity.RESULT_OK
                ready.countDown()
            }
        }
        context.startActivity(Intent().setClassName("${context.packageName}.test",
            "io.github.xiatian410.bili_downloader.FixtureGrantActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("grantResult", receiver))
        check(ready.await(15, TimeUnit.SECONDS) && accepted) { "Fixture grant was not acknowledged" }
        context.contentResolver.takePersistableUriPermission(tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }
    fun export(name: String, folder: String = ""): String {
        ensureGrant()
        val done = CountDownLatch(1)
        var uri: String? = null
        var error: String? = null
        AndroidFileExports.publish(context, MethodCall("publishFile", mapOf(
            "path" to source(name).path, "tree" to tree.toString(), "folder" to folder, "name" to name)),
            object : MethodChannel.Result {
                override fun success(value: Any?) { uri = value as String; done.countDown() }
                override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
                override fun notImplemented() { error = "notImplemented"; done.countDown() }
            })
        check(done.await(30, TimeUnit.SECONDS)) { "Export callback timed out" }
        if (error != null) throw ExportFailure(error!!)
        return requireNotNull(uri)
    }
    fun writes(): Int {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, "root")
        return context.contentResolver.query(root, arrayOf("fixture_writes"), null, null, null)!!.use {
            check(it.moveToFirst()); it.getInt(0)
        }
    }
    fun saveReport(name: String, value: JSONObject = report) {
        val root = File(context.getExternalFilesDir(null), "test-reports").apply { mkdirs() }
        File(root, name).writeText(value.toString(2))
    }
}

@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class ExportInstrumentationTest {
    private val fixture = DeviceExportFixture
    @After fun report() { fixture.saveReport("device-result.json") }

    @Test fun binderCopyFailureResumesAndCommittedReceiptProtectsExternalChanges() {
        val name = "interrupt-${UUID.randomUUID()}.bin"
        fixture.source(name).writeBytes(fixture.bytes)
        try { fixture.export(name); fail("Expected interrupted pipe") } catch (e: ExportFailure) { assertEquals("saveFailed", e.code) }
        val uri = fixture.export(name)
        assertArrayEquals(fixture.bytes, fixture.context.contentResolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() })
        val writes = fixture.writes()
        assertEquals(uri, fixture.export(name))
        assertEquals(writes, fixture.writes())
        fixture.context.contentResolver.openOutputStream(Uri.parse(uri), "wt")!!.use { it.write(42) }
        val afterEdit = fixture.writes()
        try { fixture.export(name); fail("Expected conflict") } catch (e: ExportFailure) { assertEquals("exportConflict", e.code) }
        assertEquals(afterEdit, fixture.writes())
        assertArrayEquals(byteArrayOf(42), fixture.context.contentResolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() })
        assertArrayEquals(fixture.bytes, fixture.source(name).readBytes())
        fixture.report.put("binderCopyRecovery", true).put("receiptReusedWithoutCopy", true).put("externalEditsPreserved", true)
    }

    @Test fun unicodeFolderAndPermissionFailureUseTheActualAndroidAdapter() {
        val name = "字幕与说明-${UUID.randomUUID()}.srt"
        fixture.source(name).writeBytes(fixture.bytes)
        val uri = fixture.export(name, "媒体文件")
        assertArrayEquals(fixture.bytes, fixture.context.contentResolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() })
        val denied = "denied-${UUID.randomUUID()}.bin"
        fixture.source(denied).writeBytes(fixture.bytes)
        try { fixture.export(denied); fail("Expected permission failure") } catch (e: ExportFailure) { assertEquals("exportPermissionLost", e.code) }
        assertArrayEquals(fixture.bytes, fixture.source(denied).readBytes())
        fixture.report.put("unicodeFolderExport", true).put("providerPermissionFailure", true)
    }

    @Test fun bundledFfmpegEncodesAndDecodesInThe16KiBEnvironment() {
        val pageSize = Os.sysconf(OsConstants._SC_PAGESIZE)
        assertEquals(16384L, pageSize)
        val file = File(fixture.context.cacheDir, "device-ffmpeg.mp4")
        val execute = Class.forName("com.antonkarpenko.ffmpegkit.FFmpegKit").getMethod("execute", String::class.java)
        fun run(command: String) {
            val session = execute.invoke(null, command)
            val code = session.javaClass.getMethod("getReturnCode").invoke(session)
            assertEquals(0, code.javaClass.getMethod("getValue").invoke(code))
        }
        try {
            run("-y -f lavfi -i color=c=blue:s=160x90:r=10 -f lavfi -i sine=frequency=440:sample_rate=44100 -t 1 -c:v mpeg4 -c:a aac ${file.path}")
            assertTrue(file.length() > 0)
            run("-i ${file.path} -map 0:v:0 -map 0:a:0 -f null -")
        } finally { file.delete() }
        fixture.report.put("pageSize", pageSize).put("bundledFfmpegEncodedAndDecoded", true)
    }

    @Test fun windowShowsFlutterDownloadControls() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = instrumentation.uiAutomation
        val ready = CountDownLatch(1)
        fun visible(): Boolean {
            val root = automation.rootInActiveWindow ?: return false
            var visited = 0
            fun contains(node: android.view.accessibility.AccessibilityNodeInfo): Boolean {
                if (++visited > 2000) return false
                if (node.text?.contains("解析链接") == true || node.contentDescription?.contains("解析链接") == true) return true
                for (i in 0 until node.childCount) {
                    val child = node.getChild(i) ?: continue
                    try { if (contains(child)) return true } finally { child.recycle() }
                }
                return false
            }
            return try { contains(root) } finally { root.recycle() }
        }
        automation.setOnAccessibilityEventListener { if (visible()) ready.countDown() }
        try {
            ActivityScenario.launch<MainActivity>(Intent(fixture.context, MainActivity::class.java)).use { scenario ->
                val frame = CountDownLatch(1)
                scenario.onActivity { activity ->
                    val view = activity.findViewById<FlutterView>(FlutterActivity.FLUTTER_VIEW_ID)
                    if (view.hasRenderedFirstFrame()) frame.countDown()
                    else view.addOnFirstFrameRenderedListener(object : FlutterUiDisplayListener {
                        override fun onFlutterUiDisplayed() { frame.countDown() }
                        override fun onFlutterUiNoLongerDisplayed() { }
                    })
                }
                assertTrue("Flutter did not render", frame.await(40, TimeUnit.SECONDS))
                if (visible()) ready.countDown()
                assertTrue("Download controls did not appear", ready.await(20, TimeUnit.SECONDS))
                // Semantics can arrive before the compositor presents that frame.
                // Wait for bounded accessibility idleness before taking the screenshot.
                automation.waitForIdle(500, 5000)
                val image = requireNotNull(automation.takeScreenshot())
                val output = File(fixture.context.getExternalFilesDir(null), "test-reports/android-large-font.png")
                output.parentFile!!.mkdirs()
                output.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
                image.recycle()
            }
        } finally { automation.setOnAccessibilityEventListener(null) }
        fixture.report.put("flutterDownloadControlsVisible", true)
    }
}

/** Invoked separately by the host; begin is deliberately stopped while copying. */
@RunWith(AndroidJUnit4::class)
class ExportProcessDeathTest {
    @Test fun begin() {
        DeviceExportFixture.source("process-death.bin").writeBytes(DeviceExportFixture.bytes)
        DeviceExportFixture.export("process-death.bin")
        fail("Host did not stop the copy")
    }
    @Test fun recover() {
        assertTrue(DeviceExportFixture.context.contentResolver.persistedUriPermissions.any {
            it.uri == DeviceExportFixture.tree && it.isReadPermission && it.isWritePermission
        })
        val uri = DeviceExportFixture.export("process-death.bin")
        assertArrayEquals(DeviceExportFixture.bytes,
            DeviceExportFixture.context.contentResolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() })
        assertArrayEquals(DeviceExportFixture.bytes, DeviceExportFixture.source("process-death.bin").readBytes())
        DeviceExportFixture.saveReport("process-death-result.json", JSONObject().put("forcedStopCopyRecovered", true))
    }
}
