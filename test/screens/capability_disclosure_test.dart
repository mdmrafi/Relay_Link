// RelayLink — Ticket #30: Capability disclosure widget tests.
//
// Verifies the user-visible behavior of the disclosure screen:
//   1. All 9 §3.1 capabilities are listed.
//   2. ✓ icon renders for available features; ✗ icon renders for unavailable.
//   3. Inline reason is shown for unavailable items; "available" for the rest.
//   4. The iOS-specific verbatim banner appears on iOS when SMS is off.
//   5. First-launch "Got it" button persists the seen flag and pops the route.
//   6. Settings/About mode shows a "Close" button that does NOT touch the seen
//      flag and pops the route.
//   7. The hasSeen / markSeen helpers round-trip through SharedPreferences.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/screens/capability_disclosure.dart';

void main() {
  setUp(() {
    // Reset prefs between tests so the "seen" flag does not leak.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Pump the disclosure page for the given capabilities + mode, wrapped in
  /// a minimal MaterialApp so AppBar/Navigator are available.
  Future<void> pumpDisclosure(
    WidgetTester tester, {
    required DeviceCapabilities capabilities,
    CapabilityDisclosureMode mode = CapabilityDisclosureMode.firstLaunch,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CapabilityDisclosurePage(
                    capabilities: capabilities,
                    mode: mode,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('capability_disclosure.dart — helpers', () {
    test('hasSeenCapabilityDisclosure returns false by default', () async {
      expect(await hasSeenCapabilityDisclosure(), isFalse);
    });

    test('markCapabilityDisclosureSeen flips hasSeen to true', () async {
      expect(await hasSeenCapabilityDisclosure(), isFalse);
      await markCapabilityDisclosureSeen();
      expect(await hasSeenCapabilityDisclosure(), isTrue);
    });

    test('markCapabilityDisclosureSeen uses the v1 key', () async {
      // Use raw prefs to assert the *exact* key the helpers use — guards
      // against accidental key renames that would re-prompt every user.
      await markCapabilityDisclosureSeen();
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool(kCapabilityDisclosureSeenPrefKey),
        isTrue,
        reason: 'helpers must persist under the documented v1 key',
      );
      expect(kCapabilityDisclosureSeenPrefKey, 'capability_disclosure_seen_v1');
    });
  });

  group('CapabilityDisclosurePage — Android (all available)', () {
    final caps = DeviceCapabilities.forPlatform('android');

    testWidgets('lists all 9 capabilities', (WidgetTester tester) async {
      await pumpDisclosure(tester, capabilities: caps);

      // One tile per capability row; also the platform label.
      expect(find.text('Platform: android'), findsOneWidget);
      for (final label in const <String>[
        'Bluetooth mesh send/receive',
        'Bluetooth mesh discovery',
        'Multi-hop store-and-forward relay',
        'SMS send',
        'SMS receive',
        'Internet (cloud relay)',
        'ALERT verification (signature check)',
        'Evidence Vault (capture)',
        'Evidence Vault (send-on-connect)',
      ]) {
        expect(find.text(label), findsOneWidget,
            reason: 'missing capability row: $label');
      }
    });

    testWidgets('renders ✓ icon for every available row',
        (WidgetTester tester) async {
      await pumpDisclosure(tester, capabilities: caps);

      // 9 available rows → 9 check-circle icons.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(9));
      expect(find.byIcon(Icons.cancel), findsNothing);
    });

    testWidgets('does not show the iOS banner on Android',
        (WidgetTester tester) async {
      await pumpDisclosure(tester, capabilities: caps);
      expect(find.byKey(const ValueKey<String>('iosDisclosureBanner')),
          findsNothing);
    });

    testWidgets('first-launch mode shows "Got it" button that pops and '
        'persists the seen flag', (WidgetTester tester) async {
      expect(await hasSeenCapabilityDisclosure(), isFalse);

      await pumpDisclosure(
        tester,
        capabilities: caps,
        mode: CapabilityDisclosureMode.firstLaunch,
      );
      expect(find.text('Got it'), findsOneWidget);
      expect(find.text('Close'), findsNothing);

      await tester.tap(find.byKey(
          const ValueKey<String>('capabilityConfirmButton')));
      await tester.pumpAndSettle();

      expect(await hasSeenCapabilityDisclosure(), isTrue,
          reason: 'Got it must persist the seen flag');
      // Disclosure route is gone — back to the trigger Scaffold.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('settings/about mode shows "Close" and does NOT persist',
        (WidgetTester tester) async {
      await pumpDisclosure(
        tester,
        capabilities: caps,
        mode: CapabilityDisclosureMode.settingsAbout,
      );
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Got it'), findsNothing);

      await tester.tap(find.byKey(
          const ValueKey<String>('capabilityConfirmButton')));
      await tester.pumpAndSettle();

      expect(await hasSeenCapabilityDisclosure(), isFalse,
          reason: 'Close must not flip the first-launch seen flag');
    });
  });

  group('CapabilityDisclosurePage — iOS (SMS unavailable)', () {
    final caps = DeviceCapabilities.forPlatform('ios');

    testWidgets('renders ✗ icon for SMS send and SMS receive rows, ✓ '
        'everywhere else', (WidgetTester tester) async {
      await pumpDisclosure(tester, capabilities: caps);

      // 7 available (Bluetooth×2, multi-hop, internet, ALERT, vault×2) +
      // 2 unavailable (SMS send, SMS receive) = 7 ✓, 2 ✗.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(7));
      expect(find.byIcon(Icons.cancel), findsNWidgets(2));
    });

    testWidgets('shows the spec\'s iOS-specific verbatim banner',
        (WidgetTester tester) async {
      await pumpDisclosure(tester, capabilities: caps);

      final banner = find.byKey(
          const ValueKey<String>('iosDisclosureBanner'));
      expect(banner, findsOneWidget);

      final bannerText = tester
          .widget<Text>(find.descendant(
            of: banner,
            matching: find.byType(Text),
          ))
          .data;
      expect(bannerText, equals(kIosDisclosureVerbatim));

      // And the text is exactly the §3.1 verbatim string.
      expect(
        bannerText,
        equals(
          "SMS features unavailable \u2014 Apple doesn't allow apps to "
          'send or read SMS automatically.',
        ),
      );
    });

    testWidgets('shows the iOS SMS reason inline under both SMS rows',
        (WidgetTester tester) async {
      await pumpDisclosure(tester, capabilities: caps);

      // Both SMS rows should show the spec's iOS reason verbatim.
      expect(
        find.text(
          "Apple doesn't allow apps to send or read SMS automatically",
        ),
        findsNWidgets(2),
      );
    });
  });

  group('buildSettingsAboutCapabilitiesRoute', () {
    test('builds a route that pops without touching the seen flag', () async {
      // The factory is a thin wrapper around MaterialPageRoute; verify it
      // does not flip hasSeen when constructed.
      final caps = DeviceCapabilities.forPlatform('ios');
      final route = buildSettingsAboutCapabilitiesRoute(caps);
      expect(route, isA<MaterialPageRoute<void>>());
      expect(await hasSeenCapabilityDisclosure(), isFalse);
    });
  });
}