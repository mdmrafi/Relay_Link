import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Dart interface to RelayLink's native SMS transport.
class SmsPlatformChannel {
  static const MethodChannel _channel = MethodChannel('relaylink/sms');
  static const EventChannel _eventChannel = EventChannel('relaylink/sms/incoming');

  /// Whether SMS is potentially available on this platform.
  bool get isAvailable => !Platform.isIOS;

  /// Sends [body] to [phoneNumber] through the device's SMS service.
  ///
  /// On iOS this throws a [PlatformException] because Apple does not permit
  /// programmatic SMS sending.
  Future<bool> sendSms(String phoneNumber, String body) async {
    _ensureSupported();
    final result = await _channel.invokeMethod<bool>('sendSms', {
      'phoneNumber': phoneNumber,
      'body': body,
    });
    return result ?? false;
  }

  /// Requests SEND_SMS and RECEIVE_SMS runtime permissions.
  Future<Map<String, bool>> requestSmsPermissions() async {
    _ensureSupported();
    final result = await _channel.invokeMapMethod<String, bool>(
      'requestSmsPermissions',
    );
    return result ?? const <String, bool>{};
  }

  /// Emits the body of each received SMS.
  Stream<String> get incomingSms => _eventChannel
      .receiveBroadcastStream()
      .map((event) => event as String);

  void _ensureSupported() {
    if (Platform.isIOS) {
      throw PlatformException(
        code: 'unavailable',
        message: 'SMS unavailable on iOS',
      );
    }
  }
}
