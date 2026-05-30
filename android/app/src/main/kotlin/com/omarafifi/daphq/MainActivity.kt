package com.omarafifi.daphq

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    private lateinit var shareHandler: NativeShareHandler
    private lateinit var folderHandler: NativeFolderHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        
        folderHandler = NativeFolderHandler(this, messenger)
        shareHandler = NativeShareHandler(this, messenger)

        // Process initial intent
        shareHandler.handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        shareHandler.handleIntent(intent)
    }
}

