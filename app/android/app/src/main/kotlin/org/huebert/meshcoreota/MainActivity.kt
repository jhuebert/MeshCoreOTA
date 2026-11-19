package org.huebert.meshcoreota

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      "org.huebert.meshcoreota/screen"
    ).setMethodCallHandler { call, result ->
      if (call.method == "setScreenOn") {
        val enabled = call.argument<Boolean>("enabled") == true
        if (enabled) {
          window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
          window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        result.success(null)
      } else {
        result.notImplemented()
      }
    }
  }
}
