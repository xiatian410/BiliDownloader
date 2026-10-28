package io.github.xiatian410.bili_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel

/** Owns only process priority and notification; Dart retains the only queue. */
class DownloadService : Service() {
    companion object {
        private const val CHANNEL = "downloads"
        private const val NOTIFICATION = 410
        private const val PAUSE = "io.github.xiatian410.bili_downloader.PAUSE"
        private val main = Handler(Looper.getMainLooper())
        private var instance: DownloadService? = null
        private var pending: MethodChannel.Result? = null
        private var labels: Map<*, *> = emptyMap<Any, Any>()
        private var deadline: Runnable? = null

        fun begin(context: Context, values: Map<*, *>?, result: MethodChannel.Result) {
            labels = values ?: emptyMap<Any, Any>()
            if (pending != null) { result.error("busy", "Service is starting", null); return }
            pending = result
            // A single bounded startup deadline, removed on acknowledgment.
            deadline = Runnable {
                failStart()
                context.stopService(Intent(context, DownloadService::class.java))
            }.also { main.postDelayed(it, 8000) }
            try {
                val intent = Intent(context, DownloadService::class.java)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (_: RuntimeException) { failStart() }
        }

        private fun failStart() {
            deadline?.let(main::removeCallbacks); deadline = null
            pending?.error("backgroundUnavailable", "Foreground service unavailable", null)
            pending = null
        }

        fun update(values: Map<*, *>?) { instance?.refresh(values ?: return) }
        fun end(context: Context) {
            instance?.expectedStop = true
            context.stopService(Intent(context, DownloadService::class.java))
        }
    }

    private var expectedStop = false
    private var lastUpdate = 0L
    private var previous: Map<*, *>? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE) {
            // Keep service alive until cancellation and durable checkpoints finish.
            if (instance === this && !expectedStop) DownloadRuntime.pause()
            else { expectedStop = true; stopSelf() }
            return START_NOT_STICKY
        }
        instance = this
        expectedStop = false
        if (pending == null) { expectedStop = true; stopSelf(); return START_NOT_STICKY }
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel(CHANNEL, label(labels, "title"), NotificationManager.IMPORTANCE_LOW)
                )
            }
            val notification = notification(labels)
            if (Build.VERSION.SDK_INT >= 29) {
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                if (Build.VERSION.SDK_INT >= 35) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                startForeground(NOTIFICATION, notification, type)
            } else startForeground(NOTIFICATION, notification)
            deadline?.let(main::removeCallbacks); deadline = null
            pending?.success(null); pending = null
        } catch (_: RuntimeException) {
            failStart()
            expectedStop = true
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun label(values: Map<*, *>, key: String) = (values[key] as? String)?.take(160) ?: "BiliDownloader"

    private fun notification(values: Map<*, *>): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val pause = PendingIntent.getService(this, 1, Intent(this, DownloadService::class.java).setAction(PAUSE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val progress = (values["progress"] as? Number)?.toInt() ?: -1
        return builder.setSmallIcon(R.drawable.ic_download_notification)
            .setContentTitle(label(values, "title")).setContentText(label(values, "text"))
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS).setVisibility(Notification.VISIBILITY_PRIVATE)
            .setProgress(100, progress.coerceIn(0, 100), progress < 0)
            .addAction(Notification.Action.Builder(null, label(values, "pause"), pause).build()).build()
    }

    private fun refresh(values: Map<*, *>) {
        if (expectedStop || values == previous) return
        val now = SystemClock.elapsedRealtime()
        // Event-driven, no timer/polling. Bound notification writes to 1 per second.
        if (lastUpdate != 0L && now - lastUpdate < 1000) return
        previous = values.toMap(); lastUpdate = now
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification(values))
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        expectedStop = true
        DownloadRuntime.pause("backgroundExpired")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        if (!expectedStop) DownloadRuntime.pause("backgroundUnavailable")
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
