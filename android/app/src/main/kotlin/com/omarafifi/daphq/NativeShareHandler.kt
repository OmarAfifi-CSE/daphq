package com.omarafifi.daphq

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

private const val TAG = "NativeShareHandler"

class NativeShareHandler(private val context: Context, messenger: BinaryMessenger) {
    private var eventSink: EventChannel.EventSink? = null
    private val pendingPaths = mutableListOf<String>()
    var wasLaunchedFromShare = false
    
    private var shareJob: Job? = null
    private var isFirstIntent = true
    private val shareScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        MethodChannel(messenger, "com.omarafifi.daphq/share_manager").setMethodCallHandler { call, result ->
            when (call.method) {
                "wasLaunchedFromShare" -> result.success(wasLaunchedFromShare)
                "cancelShare" -> {
                    cancelCurrentShare()
                    cleanShareCache()
                    result.success(true)
                }
                "cleanShareCache" -> {
                    cleanShareCache()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "com.omarafifi.daphq/share_stream").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    synchronized(pendingPaths) {
                        pendingPaths.forEach { eventSink?.success(it) }
                        pendingPaths.clear()
                    }
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            }
        )
    }

    fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action

        if (Intent.ACTION_SEND == action || Intent.ACTION_SEND_MULTIPLE == action) {
            wasLaunchedFromShare = true
            val uris = mutableListOf<Uri>()

            // 1. Extract from ClipData
            val clipData = intent.clipData
            if (clipData != null) {
                for (i in 0 until clipData.itemCount) {
                    clipData.getItemAt(i).uri?.let { uris.add(it) }
                }
            }

            // 2. Extract from EXTRA_STREAM (List)
            try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    val uriList = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    uriList?.let { uris.addAll(it) }
                } else {
                    @Suppress("DEPRECATION")
                    val uriList = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    uriList?.let { uris.addAll(it) }
                }
            } catch (e: Exception) {
                // Not an array list
            }

            // 3. Extract from EXTRA_STREAM (Single)
            try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    val singleUri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    singleUri?.let { uris.add(it) }
                } else {
                    @Suppress("DEPRECATION")
                    val singleUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    singleUri?.let { uris.add(it) }
                }
            } catch (e: Exception) {
                // Not a single Uri
            }

            if (uris.isNotEmpty()) {
                // Ensure unique URIs
                processUris(uris.distinct())
            }
        }
    }

    private fun processUris(uris: List<Uri>) {
        cancelCurrentShare() // Cancel any ongoing share before starting a new one
        
        if (isFirstIntent) {
            cleanShareCache()
            isFirstIntent = false
        }
        
        shareScope.launch {
            val shareCacheDir = File(context.externalCacheDir ?: context.cacheDir, "daphq_shared")
            if (!shareCacheDir.exists()) shareCacheDir.mkdirs()

            uris.forEach { uri ->
                if (!isActive) return@launch // Stop processing if job was cancelled

                val originalName = try {
                    getFileName(uri) ?: "shared_file"
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to resolve shared file name: $e")
                    "shared_file"
                }

                try {
                    // Use deterministic hash of the URI to naturally deduplicate files shared multiple times
                    val uriHash = uri.toString().hashCode().toString(16)
                    val fileName = "${uriHash}_$originalName"
                    val destFile = File(shareCacheDir, fileName)

                    context.contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(destFile).use { output ->
                            input.copyTo(output)
                        }
                    }

                    if (!isActive) {
                        destFile.delete() // Clean up if cancelled during copy
                        return@launch
                    }

                    // Send path to Flutter immediately
                    withContext(Dispatchers.Main) {
                        val path = destFile.absolutePath
                        if (eventSink != null) {
                            eventSink?.success(path)
                        } else {
                            synchronized(pendingPaths) {
                                pendingPaths.add(path)
                            }
                        }
                    }
                } catch (e: Exception) {
                    // Plan T-015: a failed copy must reach the user — the
                    // "done" event alone would silently drop this file.
                    Log.w(TAG, "Failed to copy shared file $originalName: $e")
                    withContext(Dispatchers.Main) {
                        val safeName = originalName.replace("\"", "'")
                        val errorEvent = "{\"status\": \"error\", \"name\": \"$safeName\"}"
                        if (eventSink != null) {
                            eventSink?.success(errorEvent)
                        } else {
                            synchronized(pendingPaths) {
                                pendingPaths.add(errorEvent)
                            }
                        }
                    }
                }
            }

            // Notify Flutter that streaming is done
            if (isActive) {
                withContext(Dispatchers.Main) {
                    if (eventSink != null) {
                        eventSink?.success("{\"status\": \"done\"}")
                    } else {
                        synchronized(pendingPaths) {
                            pendingPaths.add("{\"status\": \"done\"}")
                        }
                    }
                }
            }
        }
    }

    private fun cancelCurrentShare() {
        shareJob?.cancel()
        shareJob = null
    }

    private fun cleanShareCache() {
        try {
            val shareCacheDir = File(context.externalCacheDir ?: context.cacheDir, "daphq_shared")
            if (shareCacheDir.exists()) {
                shareCacheDir.deleteRecursively()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun getFileName(uri: Uri): String? {
        var result: String? = null
        if (uri.scheme == "content") {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index != -1) {
                        result = cursor.getString(index)
                    }
                }
            }
        }
        if (result == null) {
            result = uri.path?.substringAfterLast('/')
        }
        return result
    }
}
