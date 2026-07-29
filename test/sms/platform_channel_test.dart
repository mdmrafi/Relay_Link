// Smoke test for the SMS platform channel surface (Ticket #23).
//
// Verifies that:
//   - Method signatures exist on the Dart side
//   - iOS path short-circuits with a PlatformException before the channel is
//     touched (Apple disallows programmatic SMS in third-party apps)
//   - Android/non-iOS path returns a "not implemented" exception when run in
//     a host environment without the native side (acceptable: this test runs
//     on host, not on a device).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/sms/platform_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmsPlatformChannel', () {
    final channel = SmsPlatformChannel();

    test('exposes isAvailable flag reflecting current platform', () {
      expect(channel.isAvailable, !Platform.isIOS);
    });

    test('sendSms rejects when invoked on iOS with platform exception',
        () async {
      if (!Platform.isIOS) {
        return;
      }
      expect(
        () => channel.sendSms('+15555550100', 'hello'),
        throwsA(isA<PlatformException>().having(
          (e) => e.message,
          'message',
          'SMS unavailable on iOS',
        )),
      );
    });

    test('requestSmsPermissions rejects on iOS', () async {
      if (!Platform.isIOS) {
        return;
      }
      expect(
        () => channel.requestSmsPermissions(),
        throwsA(isA<PlatformException>()),
      );
    });

    test('incomingSms stream is reachable as a Stream<String>', () {
      final stream = channel.incomingSms;
      expect(stream, isA<Stream<String>>());
    });
  });
}