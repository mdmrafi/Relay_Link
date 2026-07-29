// Tests for capability detection (Ticket #29).
//
// We exercise both the Android and iOS branches by building
// `DeviceCapabilities` through the public constructor — the same one the UI
// and Settings screens will use after `detectCapabilities()` returns. This
// keeps the test focused on the *shape* and *values* of the capability table
// (the externally observable behavior) rather than on `Platform.isAndroid`
// mocking, which would test the implementation, not the contract.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/capabilities/detect.dart';

void main() {
  group('FeatureCapability', () {
    test('available with empty reason by default', () {
      const c = FeatureCapability(available: true);
      expect(c.available, isTrue);
      expect(c.reason, isEmpty);
    });

    test('unavailable carries a non-empty reason', () {
      const c = FeatureCapability(
        available: false,
        reason: "Apple doesn't allow apps to send or read SMS automatically",
      );
      expect(c.available, isFalse);
      expect(c.reason, isNotEmpty);
    });
  });

  group('DeviceCapabilities — Android', () {
    final caps = DeviceCapabilities.forPlatform('android');

    test('platform tag is "android"', () {
      expect(caps.platform, equals('android'));
    });

    test('Bluetooth mesh send/receive is available', () {
      expect(caps.bluetoothMeshSend.available, isTrue);
      expect(caps.bluetoothMeshSend.reason, isEmpty);
    });

    test('Bluetooth mesh discovery is available', () {
      expect(caps.bluetoothMeshDiscover.available, isTrue);
      expect(caps.bluetoothMeshDiscover.reason, isEmpty);
    });

    test('Multi-hop store-and-forward relay is available', () {
      expect(caps.multiHopRelay.available, isTrue);
      expect(caps.multiHopRelay.reason, isEmpty);
    });

    test('SMS send is available with no reason', () {
      expect(caps.smsSend.available, isTrue);
      expect(caps.smsSend.reason, isEmpty);
    });

    test('SMS receive is available with no reason', () {
      expect(caps.smsReceive.available, isTrue);
      expect(caps.smsReceive.reason, isEmpty);
    });

    test('Internet (cloud relay) is available', () {
      expect(caps.internet.available, isTrue);
      expect(caps.internet.reason, isEmpty);
    });

    test('ALERT verification (signature check) is available', () {
      expect(caps.alertVerification.available, isTrue);
      expect(caps.alertVerification.reason, isEmpty);
    });

    test('Evidence Vault (capture) is available', () {
      expect(caps.vaultCapture.available, isTrue);
      expect(caps.vaultCapture.reason, isEmpty);
    });

    test('Evidence Vault (send-on-connect) is available', () {
      expect(caps.vaultSendOnConnect.available, isTrue);
      expect(caps.vaultSendOnConnect.reason, isEmpty);
    });

    test('allNineFeaturesHaveResults: every capability has either available=true '
        'or a non-empty reason', () {
      expect(caps.allAvailable, isTrue,
          reason: 'Android is the full-feature platform');
    });
  });

  group('DeviceCapabilities — iOS', () {
    final caps = DeviceCapabilities.forPlatform('ios');

    test('platform tag is "ios"', () {
      expect(caps.platform, equals('ios'));
    });

    test('Bluetooth mesh send/receive is available (mesh subset)', () {
      expect(caps.bluetoothMeshSend.available, isTrue);
      expect(caps.bluetoothMeshSend.reason, isEmpty);
    });

    test('Bluetooth mesh discovery is available (mesh subset)', () {
      expect(caps.bluetoothMeshDiscover.available, isTrue);
      expect(caps.bluetoothMeshDiscover.reason, isEmpty);
    });

    test('Multi-hop store-and-forward relay is available (mesh subset)', () {
      expect(caps.multiHopRelay.available, isTrue);
      expect(caps.multiHopRelay.reason, isEmpty);
    });

    test('SMS send is unavailable with the spec\'s iOS-specific reason', () {
      expect(caps.smsSend.available, isFalse);
      expect(
        caps.smsSend.reason,
        equals(
          "Apple doesn't allow apps to send or read SMS automatically",
        ),
      );
    });

    test('SMS receive is unavailable with the spec\'s iOS-specific reason', () {
      expect(caps.smsReceive.available, isFalse);
      expect(
        caps.smsReceive.reason,
        equals(
          "Apple doesn't allow apps to send or read SMS automatically",
        ),
      );
    });

    test('Internet (cloud relay) is available on iOS (gateway route)', () {
      expect(caps.internet.available, isTrue);
      expect(caps.internet.reason, isEmpty);
    });

    test('ALERT verification is available on iOS (signature check is local)', () {
      expect(caps.alertVerification.available, isTrue);
      expect(caps.alertVerification.reason, isEmpty);
    });

    test('Evidence Vault (capture) is available on iOS (local encryption)', () {
      expect(caps.vaultCapture.available, isTrue);
      expect(caps.vaultCapture.reason, isEmpty);
    });

    test('Evidence Vault (send-on-connect) is available on iOS (via internet)',
        () {
      expect(caps.vaultSendOnConnect.available, isTrue);
      expect(caps.vaultSendOnConnect.reason, isEmpty);
    });

    test('iOS has at least one unavailable feature (SMS) with helpful reasons',
        () {
      expect(caps.smsSend.available, isFalse);
      expect(caps.smsReceive.available, isFalse);
      expect(caps.smsSend.reason, isNotEmpty);
      expect(caps.smsReceive.reason, isNotEmpty);
    });

    test('allNineFeaturesHaveResults: every capability is either available '
        'or carries a non-empty reason', () {
      final features = <String, FeatureCapability>{
        'bluetoothMeshSend': caps.bluetoothMeshSend,
        'bluetoothMeshDiscover': caps.bluetoothMeshDiscover,
        'multiHopRelay': caps.multiHopRelay,
        'smsSend': caps.smsSend,
        'smsReceive': caps.smsReceive,
        'internet': caps.internet,
        'alertVerification': caps.alertVerification,
        'vaultCapture': caps.vaultCapture,
        'vaultSendOnConnect': caps.vaultSendOnConnect,
      };

      // Exactly 9 features per §3.1.
      expect(features.length, equals(9));

      features.forEach((name, cap) {
        expect(
          cap.available || cap.reason.isNotEmpty,
          isTrue,
          reason: '$name must be either available or carry a reason',
        );
      });
    });
  });

  group('DeviceCapabilities — disclosure string', () {
    test('Android disclosure mentions all features', () {
      final caps = DeviceCapabilities.forPlatform('android');
      final s = caps.toDisclosureString();
      expect(s, contains('android'));
      // All 9 labels should appear.
      for (final label in const [
        'Bluetooth mesh send/receive',
        'Bluetooth mesh discovery',
        'Multi-hop store-and-forward relay',
        'SMS send',
        'SMS receive',
        'Internet',
        'ALERT verification',
        'Evidence Vault (capture)',
        'Evidence Vault (send-on-connect)',
      ]) {
        expect(s, contains(label), reason: 'missing $label');
      }
    });

    test('iOS disclosure includes SMS reasons', () {
      final caps = DeviceCapabilities.forPlatform('ios');
      final s = caps.toDisclosureString();
      expect(s, contains('ios'));
      expect(s, contains("Apple doesn't allow apps to send or read SMS"));
    });
  });

  group('detectCapabilities()', () {
    test('returns an Android capabilities object on Android', () {
      if (Platform.isAndroid) {
        final caps = detectCapabilities();
        expect(caps.platform, equals('android'));
      }
    });

    test('returns an iOS capabilities object on iOS', () {
      if (Platform.isIOS) {
        final caps = detectCapabilities();
        expect(caps.platform, equals('ios'));
      }
    });

    test('on desktop / unknown platforms, falls back to a sensible default',
        () {
      // On host (Linux/macOS/Windows CI), Platform is none of android/ios.
      // detectCapabilities() must still return *something* without throwing,
      // because the UI will show it.
      if (!Platform.isAndroid && !Platform.isIOS) {
        final caps = detectCapabilities();
        expect(caps.platform, isNotEmpty);
        // Every feature has either available=true or a non-empty reason.
        for (final cap in <FeatureCapability>[
          caps.bluetoothMeshSend,
          caps.bluetoothMeshDiscover,
          caps.multiHopRelay,
          caps.smsSend,
          caps.smsReceive,
          caps.internet,
          caps.alertVerification,
          caps.vaultCapture,
          caps.vaultSendOnConnect,
        ]) {
          expect(cap.available || cap.reason.isNotEmpty, isTrue);
        }
      }
    });
  });
}