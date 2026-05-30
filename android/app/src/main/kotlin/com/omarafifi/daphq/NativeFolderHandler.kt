package com.omarafifi.daphq

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

class NativeFolderHandler(private val context: Context, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "com.omarafifi.daphq/file_manager").setMethodCallHandler { call, result ->
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

            if (path.contains("/storage/emulated/0/")) {
                val rel = path.substringAfter("/storage/emulated/0/")
                val safUri = Uri.parse("content://com.android.externalstorage.documents/document/primary:${Uri.encode(rel)}")
                intent.setDataAndType(safUri, "vnd.android.document/directory")
                try {
                    context.startActivity(intent)
                    return true
                } catch (e: Exception) {
                }
            }

            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileProvider", file)
            intent.setDataAndType(uri, "vnd.android.document/directory")
            try {
                context.startActivity(intent)
                return true
            } catch (e: Exception) {
            }

            intent.setDataAndType(uri, "*/*")
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
