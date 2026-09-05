package com.connexia.connexia

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "connexia/tunnels",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "keepAliveStart" -> {
                    startTunnelKeepAlive()
                    result.success(null)
                }
                "keepAliveStop" -> {
                    stopService(Intent(this, TunnelForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startTunnelKeepAlive() {
        // The service runs without the notification being visible, but
        // asking once means most users actually see the "tunnel active"
        // notification instead of a silent one.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                1010,
            )
        }
        val intent = Intent(this, TunnelForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
