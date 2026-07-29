package com.example.relaylink

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class SmsPlugin(
    private val activity: Activity,
    private val context: Context,
) {
    companion object {
        const val METHOD_CHANNEL = "relaylink/sms"
        const val EVENT_CHANNEL = "relaylink/sms/incoming"
        const val PERMISSION_REQUEST_CODE = 9001
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    fun register(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> handleSendSms(call, result)
                "requestSmsPermissions" -> handleRequestPermissions(result)
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                    SmsBroadcastReceiver.pendingSink = sink
                    SmsBroadcastReceiver.lastBody?.let { body ->
                        mainHandler.post {
                            sink.success(body)
                            SmsBroadcastReceiver.lastBody = null
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    SmsBroadcastReceiver.pendingSink = null
                    eventSink = null
                }
            }
        )
    }

    private fun handleSendSms(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val phoneNumber = call.argument<String>("phoneNumber")
        val body = call.argument<String>("body")
        if (phoneNumber.isNullOrBlank() || body.isNullOrBlank()) {
            result.error("invalid_args", "phoneNumber and body are required", null)
            return
        }
        if (!hasPermission(Manifest.permission.SEND_SMS)) {
            result.error(
                "permission_denied",
                "SEND_SMS permission not granted",
                null,
            )
            return
        }
        try {
            val manager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            manager.sendTextMessage(phoneNumber, null, body, null, null)
            result.success(true)
        } catch (t: Throwable) {
            result.error("send_failed", t.message ?: "SMS send failed", null)
        }
    }

    private fun handleRequestPermissions(result: MethodChannel.Result) {
        val needsSend = !hasPermission(Manifest.permission.SEND_SMS)
        val needsReceive = !hasPermission(Manifest.permission.RECEIVE_SMS)
        if (!needsSend && !needsReceive) {
            result.success(
                mapOf(
                    "send" to true,
                    "receive" to true,
                )
            )
            return
        }
        val permissions = mutableListOf<String>()
        if (needsSend) permissions.add(Manifest.permission.SEND_SMS)
        if (needsReceive) permissions.add(Manifest.permission.RECEIVE_SMS)
        pendingResult = result
        ActivityCompat.requestPermissions(
            activity,
            permissions.toTypedArray(),
            PERMISSION_REQUEST_CODE,
        )
    }

    @Volatile
    private var pendingResult: MethodChannel.Result? = null

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val result = pendingResult ?: return
        pendingResult = null
        val sendGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.SEND_SMS,
        ) == PackageManager.PERMISSION_GRANTED
        val receiveGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECEIVE_SMS,
        ) == PackageManager.PERMISSION_GRANTED
        result.success(
            mapOf(
                "send" to sendGranted,
                "receive" to receiveGranted,
            )
        )
    }

    private fun hasPermission(name: String): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            name,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
