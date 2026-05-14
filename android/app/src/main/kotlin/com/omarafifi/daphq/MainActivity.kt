package com.omarafifi.daphq

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.omarafifi.daphq/file_manager"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openFolder") {
                val path = call.argument<String>("path")
                if (path != null) {
                    val success = openFolder(path)
                    if (success) result.success(true) 
                    else result.error("UNAVAILABLE", "Could not open folder", null)
                } else {
                    result.error("INVALID_ARGUMENT", "Path is null", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun openFolder(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false

            val intent = Intent(Intent.ACTION_VIEW)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

            // 1. Try SAF Deep-link (Best for modern Samsung/Google Files)
            if (path.contains("/storage/emulated/0/")) {
                val rel = path.substringAfter("/storage/emulated/0/")
                val safUri = Uri.parse("content://com.android.externalstorage.documents/document/primary:${Uri.encode(rel)}")
                intent.setDataAndType(safUri, "vnd.android.document/directory")
                try {
                    startActivity(intent)
                    return true
                } catch (e: Exception) {
                    // Fall through
                }
            }

            // 2. Try FileProvider with official Directory MIME type
            val uri = FileProvider.getUriForFile(this, "$packageName.fileProvider", file)
            intent.setDataAndType(uri, "vnd.android.document/directory")
            try {
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // Fall through
            }

            // 3. Last resort: Generic viewer
            intent.setDataAndType(uri, "*/*")
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
