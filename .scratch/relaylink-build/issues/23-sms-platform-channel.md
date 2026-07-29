# 23 — SMS platform channel (send via SmsManager, receive via SMS receiver)

**What to build:** A Flutter platform channel (`lib/sms/platform_channel.dart`) wrapping Android's `SmsManager` for sending and a `BroadcastReceiver` for receiving. Permission: `SEND_SMS`, `RECEIVE_SMS`, plus a runtime permission flow. On iOS, this returns "unavailable" (Apple blocks programmatic SMS per spec §3.1).

**Blocked by:** #01

**Status:** ready-for-agent

- [x] Method `sendSms(phoneNumber, body)` works (Android), returns true on success
- [x] BroadcastReceiver registered in AndroidManifest, receives incoming SMS, parses body, calls Dart callback
- [x] Runtime permissions requested with rationale before any SMS operation
- [x] iOS: methods exist but return PlatformException with "SMS unavailable on iOS"
- [x] §3.1 capability disclosure includes the SMS status (see #30)