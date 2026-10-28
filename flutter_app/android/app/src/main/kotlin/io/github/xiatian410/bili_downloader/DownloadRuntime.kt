package io.github.xiatian410.bili_downloader

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/** One engine/queue per process. Activity attachment does not own its lifetime. */
internal object DownloadRuntime {
    private var engine: FlutterEngine? = null
    private var activity = WeakReference<MainActivity>(null)
    private var execution: MethodChannel? = null

    fun engine(context: Context): FlutterEngine = engine ?: FlutterEngine(context.applicationContext).also { created ->
        engine = created
        val app = context.applicationContext
        MethodChannel(created.dartExecutor.binaryMessenger, "bili_downloader/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "publishFile" -> AndroidFileExports.publish(app, call, result)
                "pickDirectory", "openDirectory" -> {
                    val host = activity.get()
                    if (host == null) result.error("closed", "Open the app to choose a folder", null)
                    else host.fileAction(call, result)
                }
                else -> result.notImplemented()
            }
        }
        execution = MethodChannel(created.dartExecutor.binaryMessenger, "bili_downloader/execution").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> DownloadService.begin(app, call.arguments as? Map<*, *>, result)
                    "update" -> { DownloadService.update(call.arguments as? Map<*, *>); result.success(null) }
                    "stop" -> { DownloadService.end(app); result.success(null) }
                    "notifications" -> {
                        val host = activity.get()
                        if (host == null) result.error("closed", "Open the app to allow notifications", null)
                        else host.requestDownloadNotifications(result)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun attach(host: MainActivity) { activity = WeakReference(host) }
    fun detach(host: MainActivity) { if (activity.get() === host) activity.clear() }
    fun pause(reason: String? = null) { execution?.invokeMethod("pause", reason) }
}
