package io.github.xiatian410.bili_downloader

import android.app.NotificationManager
import android.content.pm.ServiceInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class BackgroundDownloadTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private lateinit var engine: FlutterEngine
    private fun launch(): ActivityScenario<MainActivity> = ActivityScenario.launch(MainActivity::class.java).also { scenario ->
        scenario.onActivity { host ->
            val accessor = io.flutter.embedding.android.FlutterActivity::class.java.getDeclaredMethod("getFlutterEngine")
            accessor.isAccessible = true
            engine = accessor.invoke(host) as FlutterEngine
        }
    }
    private fun call(method: String): Map<*, *> {
        val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        instrumentation.runOnMainSync {
            MethodChannel(engine.dartExecutor.binaryMessenger, "bili_downloader/device_fixture").invokeMethod(method, null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) { value = result; done.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { error = "$code: $message"; done.countDown() }
                    override fun notImplemented() { error = "Fixture channel missing"; done.countDown() }
                })
        }
        assertTrue("Dart $method did not answer", done.await(45, TimeUnit.SECONDS))
        assertNull(error, error)
        return value as? Map<*, *> ?: emptyMap<Any, Any>()
    }
    private fun report(key: String) {
        val file = java.io.File(context.getExternalFilesDir(null), "test-reports/background-result.json")
        val report = if (file.exists()) JSONObject(file.readText()) else JSONObject()
        report.put(key, true)
        DeviceExportFixture.saveReport("background-result.json", report)
    }
    private fun service(): DownloadService? = DownloadService::class.java.getDeclaredField("instance").let {
        it.isAccessible = true
        it.get(null) as? DownloadService
    }
    private fun assertStopped() {
        // Stop request is asynchronous. Only this test waits, bounded to five seconds.
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (service() != null && System.nanoTime() < deadline) Thread.sleep(25)
        assertNull("Foreground service outlived the queue", service())
    }

    @Test fun a_downloadSurvivesActivityDestructionWithoutNotificationPermission() {
        assertFalse(context.getSystemService(NotificationManager::class.java).areNotificationsEnabled())
        val scenario = launch()
        val before = call("start")
        assertNotNull(service())
        scenario.close()
        assertTrue(engine.dartExecutor.isExecutingDart)
        val result = call("finish")
        assertEquals(true, result["verified"])
        assertEquals(true, result["decoded"])
        assertEquals(before["id"], result["id"])
        assertEquals(before["queue"], result["queue"])
        assertStopped()
        launch().use {
            val restored = call("identity")
            assertEquals(before["queue"], restored["queue"])
            assertEquals(before["id"], restored["id"])
        }
        report("activityDestroyedDownloadCompleted")
        report("notificationDeniedDownloadCompleted")
        report("sameEngineAndQueueReattached")
    }

    @Test fun b_notificationPausesAndExplicitResumeUsesRange() {
        instrumentation.uiAutomation.executeShellCommand("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS").use {
            java.io.FileInputStream(it.fileDescriptor).readBytes()
        }
        val scenario = launch()
        val before = call("start")
        val notifications = context.getSystemService(NotificationManager::class.java).activeNotifications
        assertEquals(1, notifications.size)
        val pause = notifications.single().notification.actions.single().actionIntent
        scenario.close()
        pause.send()
        val paused = call("paused")
        assertEquals("paused", paused["state"])
        assertEquals(before["id"], paused["id"])
        assertStopped()
        launch().use {
            call("resume")
            val result = call("finish")
            assertEquals(true, result["verified"])
            assertEquals(true, result["rangeResumed"])
            assertEquals(before["id"], result["id"])
        }
        assertStopped()
        report("notificationPauseAndRangeResume")
    }

    @Test fun c_systemTimeoutStopsServiceAndRetainsPausedTask() {
        val scenario = launch()
        call("start")
        scenario.close()
        instrumentation.runOnMainSync {
            requireNotNull(service()).onTimeout(1, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        }
        val paused = call("paused")
        assertEquals("paused", paused["state"])
        assertEquals("backgroundExpired", paused["error"])
        assertTrue((paused["received"] as Number).toLong() > 0)
        assertStopped()
        report("timeoutCallbackPausesQueue")
    }
}
