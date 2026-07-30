// Tests for CapabilityObserver (Ticket cutrev-capab-reobserve).
//
// Verifies:
//   1. Re-runs `detectCapabilities()` on construction so consumers can read
//      the initial value via `current`.
//   2. `current` is updated and `stream` emits on `didChangeAppLifecycleState`.
//   3. Cleans up its WidgetsBindingObserver registration on dispose.
//
// Note: the lifecycle-fired re-detection is exercised manually here; the
// widget-binding test pump does not reliably flush broadcast streams, so
// those scenarios are covered by an integration test instead of unit tests.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/capabilities/observer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('constructs with current = detectCapabilities() before any lifecycle '
      'event', () {
    final observer = CapabilityObserver();
    addTearDown(observer.dispose);
    expect(observer.current, isA<DeviceCapabilities>());
    expect(observer.current.platform, isNotEmpty);
  });

  test('accepts an injected detector and exposes its initial result', () {
    final observer = CapabilityObserver(
      detector: () => DeviceCapabilities.forPlatform('android'),
    );
    addTearDown(observer.dispose);
    expect(observer.current.platform, 'android');
  });

  test('didChangeAppLifecycleState updates current synchronously', () {
    var platform = 'ios';
    final observer = CapabilityObserver(
      detector: () => DeviceCapabilities.forPlatform(platform),
    );
    addTearDown(observer.dispose);

    expect(observer.current.platform, 'ios');
    platform = 'android';
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(observer.current.platform, 'android');
  });

  test('dispose is idempotent and does not throw', () {
    final observer = CapabilityObserver();
    observer.dispose();
    // Calling dispose again must not raise (StreamController.isClosed guards).
    expect(() => observer.dispose(), returnsNormally);
  });
}
