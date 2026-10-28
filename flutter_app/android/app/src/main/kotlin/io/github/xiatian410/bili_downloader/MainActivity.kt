package io.github.xiatian410.bili_downloader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var picker: MethodChannel.Result? = null

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
                "publishFile" -> AndroidFileExports.publish(applicationContext, call, result)
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
        super.onDestroy()
    }
}
