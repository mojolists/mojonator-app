package com.mojolists.vinted_scout

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Receives text shared from other apps (the eBay or Vinted app's Share button,
 * which passes the listing link) and hands it to Flutter on the "mojo/share"
 * channel: takeInitial for a cold start, "shared" for a share while running.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pending = extract(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mojo/share")
        ch.setMethodCallHandler { call, result ->
            if (call.method == "takeInitial") {
                result.success(pending)
                pending = null
            } else {
                result.notImplemented()
            }
        }
        channel = ch
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extract(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("shared", text) else pending = text
    }

    private fun extract(i: Intent?): String? {
        if (i == null || i.action != Intent.ACTION_SEND) return null
        val type = i.type ?: ""
        if (!type.startsWith("text/")) return null
        val text = i.getStringExtra(Intent.EXTRA_TEXT) ?: ""
        val subject = i.getStringExtra(Intent.EXTRA_SUBJECT) ?: ""
        val all = (subject + "\n" + text).trim()
        return if (all.isEmpty()) null else all
    }
}
