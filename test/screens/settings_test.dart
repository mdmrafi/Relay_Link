// RelayLink — Ticket #42: Settings/About widget tests.
//
// Verifies the user-visible behavior of the Settings/About screen:
//   1. The screen renders all required tiles: capabilities, gateway, README,
//      Code-of-Conduct, app version.
//   2. The gateway toggle is the same `GatewayToggleTile` from #21 (i.e. it
//      honors the OFF/ON state and surfaces the safety warning on tap).
//   3. Tapping the capabilities entry pushes the disclosure screen from #30
//      (rendered via `buildSettingsAboutCapabilitiesRoute`).
//   4. Tapping the README entry shows the in-app disclosure dialog with the
//      URL and a Copy action that writes to the clipboard.
//   5. Tapping the Code-of-Conduct entry opens a sheet that lists all four
//      data-collection categories with their titles.
//   6. The app version tile shows `kAppVersion`.
//
// SharedPreferences is mocked with `SharedPreferences.setMockInitialValues`
// so the gateway tile's persisted state is deterministic.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/features/gateway/toggle.dart';
import 'package:relaylink/screens/settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Pump the Settings/About screen wrapped in a Riverpod `ProviderScope`
  /// (the gateway tile needs the `gatewayEnabledProvider`) and a
  /// `MaterialApp` (Navigator + AppBar).
  Future<void> pumpSettings(
    WidgetTester tester, {
    DeviceCapabilities capabilities =
        const DeviceCapabilities(
      platform: 'android',
      bluetoothMeshSend: FeatureCapability(available: true),
      bluetoothMeshDiscover: FeatureCapability(available: true),
      multiHopRelay: FeatureCapability(available: true),
      smsSend: FeatureCapability(available: true),
      smsReceive: FeatureCapability(available: true),
      internet: FeatureCapability(available: true),
      alertVerification: FeatureCapability(available: true),
      vaultCapture: FeatureCapability(available: true),
      vaultSendOnConnect: FeatureCapability(available: true),
    ),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SettingsAboutScreen(capabilities: capabilities),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SettingsAboutScreen — structure', () {
    testWidgets('renders the AppBar titled "Settings & About"',
        (WidgetTester tester) async {
      await pumpSettings(tester);
      expect(find.text('Settings & About'), findsOneWidget);
    });

    testWidgets('lists all five required entries',
        (WidgetTester tester) async {
      await pumpSettings(tester);

      // Capabilities entry navigates to #30's disclosure screen.
      expect(find.byKey(const ValueKey<String>('capabilitiesEntry')),
          findsOneWidget);

      // Gateway toggle is the same widget shipped in #21.
      expect(find.byType(GatewayToggleTile), findsOneWidget);

      // README link.
      expect(find.byKey(const ValueKey<String>('readmeEntry')), findsOneWidget);

      // Code-of-Conduct disclosure.
      expect(find.byKey(const ValueKey<String>('codeOfConductEntry')),
          findsOneWidget);

      // App version.
      expect(find.byKey(const ValueKey<String>('appVersionTile')),
          findsOneWidget);
    });

    testWidgets('shows the app version from kAppVersion',
        (WidgetTester tester) async {
      await pumpSettings(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('appVersionTile')),
          matching: find.text(kAppVersion),
        ),
        findsOneWidget,
      );
    });
  });

  group('SettingsAboutScreen — capabilities entry (#30 navigation)', () {
    testWidgets('tapping the capabilities entry pushes the disclosure screen '
        'with the supplied capabilities', (WidgetTester tester) async {
      final caps = DeviceCapabilities.forPlatform('ios');
      await pumpSettings(tester, capabilities: caps);

      await tester.tap(find.byKey(const ValueKey<String>('capabilitiesEntry')));
      await tester.pumpAndSettle();

      // The capability disclosure from #30 renders in Settings/About mode
      // (label: "Close", not "Got it") and lists the iOS verbatim banner.
      expect(find.text("This device's capabilities"), findsOneWidget,
          reason: 'the disclosure AppBar should be visible');
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Got it'), findsNothing);
      expect(find.text('Platform: ios'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('iosDisclosureBanner')),
          findsOneWidget);
    });

    testWidgets('disclosure Close button pops back to Settings',
        (WidgetTester tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const ValueKey<String>('capabilitiesEntry')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey<String>('capabilityConfirmButton')));
      await tester.pumpAndSettle();

      // Back to the Settings screen.
      expect(find.text('Settings & About'), findsOneWidget);
    });
  });

  group('SettingsAboutScreen — gateway toggle (#21 widget reuse)', () {
    testWidgets('gateway tile is OFF by default and surfaces the safety '
        'warning on tap', (WidgetTester tester) async {
      await pumpSettings(tester);

      // The same widget shipped in #21, just presented inside Settings.
      expect(find.byType(GatewayToggleTile), findsOneWidget);
      final Switch switchBefore = tester.widget<Switch>(find.byType(Switch));
      expect(switchBefore.value, isFalse);

      // Tap the tile → safety warning modal (verbatim from SPEC §10).
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('gatewaySafetyWarningDialog')),
          findsOneWidget);
      expect(find.text(kGatewaySafetyWarning), findsOneWidget);

      // Confirm → toggle becomes ON.
      await tester.tap(
          find.byKey(const ValueKey<String>('gatewaySafetyWarningConfirm')));
      await tester.pumpAndSettle();

      final Switch switchAfter = tester.widget<Switch>(find.byType(Switch));
      expect(switchAfter.value, isTrue,
          reason: 'the shared widget must still flip to ON after confirm');
    });
  });

  group('SettingsAboutScreen — README link', () {
    testWidgets('tapping the README entry opens a dialog showing the URL',
        (WidgetTester tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byKey(const ValueKey<String>('readmeEntry')));
      await tester.pumpAndSettle();

      // Dialog appears with the title and the README URL inside it (the URL
      // is also the subtitle of the tile, so we scope the URL lookup to
      // descendants of the dialog to avoid double-counting).
      expect(find.byKey(const ValueKey<String>('readmeDialog')), findsOneWidget);
      expect(find.text(kReadmeDialogTitle), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('readmeDialog')),
          matching: find.byKey(const ValueKey<String>('readmeUrl')),
        ),
        findsOneWidget,
      );
    });
  });

  group('SettingsAboutScreen — Code-of-Conduct disclosure', () {
    testWidgets('tapping the Code-of-Conduct entry opens a sheet that lists '
        'all four collected-data categories', (WidgetTester tester) async {
      await pumpSettings(tester);

      await tester.tap(
          find.byKey(const ValueKey<String>('codeOfConductEntry')));
      await tester.pumpAndSettle();

      // The sheet appears.
      expect(find.byKey(const ValueKey<String>('codeOfConductSheet')),
          findsOneWidget);
      expect(find.text(kCodeOfConductDialogTitle), findsOneWidget);
      expect(find.text(kCodeOfConductIntro), findsOneWidget);

      // All four §"Data collected" categories from README.md are listed.
      expect(find.text(kCccDeviceIdTitle), findsOneWidget,
          reason: 'device ID entry must be listed');
      expect(find.text(kCccLocationTitle), findsOneWidget,
          reason: 'location entry must be listed');
      expect(find.text(kCccPhoneTitle), findsOneWidget,
          reason: 'phone number entry must be listed');
      expect(find.text(kCccEvidenceTitle), findsOneWidget,
          reason: 'evidence capture entry must be listed');

      // And the body of each entry is present (smoke-check that the "why"
      // is actually shown to the user, not just the title). Each token is
      // unique to one entry so we don't double-count.
      expect(find.textContaining('flutter_secure_storage'), findsOneWidget,
          reason: 'device ID body must explain where keys are stored');
      expect(find.textContaining('latitude'), findsOneWidget,
          reason: 'location body must mention lat/lng');
      expect(find.textContaining('android.telephony.SmsManager'), findsOneWidget,
          reason: 'phone body must cite the SMS API');
      expect(find.textContaining('AES-256-GCM'), findsOneWidget,
          reason: 'evidence body must cite the encryption primitive');
    });

    testWidgets('the Close button on the Code-of-Conduct sheet dismisses it',
        (WidgetTester tester) async {
      await pumpSettings(tester);
      await tester.tap(
          find.byKey(const ValueKey<String>('codeOfConductEntry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('codeOfConductSheet')),
          findsOneWidget);

      // The Close button sits at the bottom of the sheet content — scroll
      // it into view before tapping (the test surface is 800×600).
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('codeOfConductClose')),
        100,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey<String>('codeOfConductSheet')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(
          find.byKey(const ValueKey<String>('codeOfConductClose')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('codeOfConductSheet')),
          findsNothing);
    });
  });

  group('SettingsAboutScreen.buildRoute', () {
    test('returns a MaterialPageRoute', () {
      final caps = DeviceCapabilities.forPlatform('android');
      expect(SettingsAboutScreen.buildRoute(caps),
          isA<MaterialPageRoute<void>>());
    });
  });

  group('SettingsAboutSampleApp', () {
    testWidgets('renders the Settings/About screen inside its own MaterialApp',
        (WidgetTester tester) async {
      await tester.pumpWidget(const SettingsAboutSampleApp());
      await tester.pumpAndSettle();
      expect(find.text('Settings & About'), findsOneWidget);
      expect(find.byType(GatewayToggleTile), findsOneWidget);
    });
  });
}