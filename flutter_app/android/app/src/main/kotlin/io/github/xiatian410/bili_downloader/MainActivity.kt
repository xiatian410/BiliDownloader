package io.github.xiatian410.bili_downloader

import android.app.Activity
import android.content.Intent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall

class MainActivity : FlutterActivity() {
    private var picker: MethodChannel.Result? = null
    private var notifications: MethodChannel.Result? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine = DownloadRuntime.engine(context)
    override fun shouldDestroyEngineWithHost() = false

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        DownloadRuntime.attach(this)
    }

    fun fileAction(call: MethodCall, result: MethodChannel.Result) {
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

    fun requestDownloadNotifications(result: MethodChannel.Result) {
        val preferences = getSharedPreferences("notifications", MODE_PRIVATE)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            (!preferences.getBoolean("requested", false) || shouldShowRequestPermissionRationale(android.Manifest.permission.POST_NOTIFICATIONS))) {
            if (notifications != null) { result.error("busy", "Permission request is open", null); return }
            notifications = result
            preferences.edit().putBoolean("requested", true).apply()
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 411)
        } else {
            try {
                val intent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                startActivity(intent)
                result.success(null)
            } catch (_: RuntimeException) { result.error("notificationsUnavailable", "Cannot open settings", null) }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 411) { notifications?.success(null); notifications = null }
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
        DownloadRuntime.detach(this)
        notifications?.error("closed", "Activity closed", null)
        notifications = null
        picker?.error("closed", "Activity closed", null)
        picker = null
        super.onDestroy()
    }
}
