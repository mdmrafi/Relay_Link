package com.example.relaylink

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import io.flutter.plugin.common.EventChannel

/**
 * Static receiver registered in AndroidManifest.xml so the system can deliver
 * incoming SMS even when the Flutter engine is not currently running. When the
 * Flutter engine is alive, [SmsPlugin] also registers a runtime receiver and
 * the system delivers intents to the highest-priority matching receiver.
 *
 * The receiver stores the most recent SMS body in a static field, which
 * [SmsPlugin] can drain on first listen if it cares about back-history.
 */
class SmsBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        val body = messages.joinToString(separator = "") { it.displayMessageBody }
        if (body.isBlank()) return
        lastBody = body
        Handler(Looper.getMainLooper()).post {
            pendingSink?.success(body)
        }
    }

    companion object {
        @Volatile
        var lastBody: String? = null

        @Volatile
        var pendingSink: EventChannel.EventSink? = null
    }
}