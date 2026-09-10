package com.blindbus.driver

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "blind_bus_driver/profile").setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("vehicle_profile", MODE_PRIVATE)
            when (call.method) {
                "load" -> result.success(prefs.getString("profile", null))
                "save" -> {
                    val value = call.argument<String>("profile")
                    if (value == null) result.error("INVALID", "등록 정보가 없습니다.", null)
                    else if (prefs.edit().putString("profile", value).commit()) result.success(null)
                    else result.error("SAVE_FAILED", "저장하지 못했습니다.", null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
