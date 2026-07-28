package com.pipilot.pi_pilot

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val systemChannel = "com.pipilot.pi_pilot/system"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startKeepAlive" -> {
                        KeepAliveService.start(applicationContext)
                        result.success(null)
                    }
                    "stopKeepAlive" -> {
                        BridgeWatcher.stop()
                        KeepAliveService.stop(applicationContext)
                        result.success(null)
                    }
                    // 切后台时由 Dart 交出连接参数,之后连接由原生线程独立维护
                    "startWatcher" -> {
                        val host = call.argument<String>("host")
                        val port = call.argument<Int>("port")
                        val token = call.argument<String>("token")
                        val sourceId = call.argument<String>("sourceId")
                        val clientId = call.argument<String>("clientId")
                        if (host.isNullOrEmpty() || port == null || token.isNullOrEmpty() ||
                            sourceId.isNullOrEmpty() || clientId.isNullOrEmpty()
                        ) {
                            result.error("invalid_args", "watcher config incomplete", null)
                        } else {
                            BridgeWatcher.start(
                                context = applicationContext,
                                host = host,
                                port = port,
                                token = token,
                                sourceId = sourceId,
                                vibrate = call.argument<Boolean>("vibrate") ?: false,
                                clientId = clientId,
                            )
                            result.success(null)
                        }
                    }
                    "stopWatcher" -> {
                        BridgeWatcher.stop()
                        result.success(null)
                    }
                    "log" -> {
                        Log.i("PiPilotDart", call.argument<String>("message").orEmpty())
                        result.success(null)
                    }
                    "openNotificationSettings" -> {
                        openNotificationSettings(call.argument<String>("channelId"))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun openNotificationSettings(channelId: String?) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && channelId != null) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, channelId)
            }
        } else {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
        }

        try {
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName"),
                ),
            )
        }
    }
}
