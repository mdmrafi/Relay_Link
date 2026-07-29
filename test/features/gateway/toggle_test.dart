// RelayLink — Ticket #21: Gateway toggle widget tests.
//
// These tests verify the user-visible behavior of the gateway toggle:
//   1. The tile shows the correct title and reflects the current state.
//   2. Tapping when OFF shows the safety warning modal (verbatim from
//      SPEC §10).
//   3. Pressing "Confirm" in the safety warning enables the toggle.
//   4. Pressing "Cancel" does NOT enable the toggle.
//   5. Tapping when ON shows a "Turn off?" confirmation dialog.
//   6. Pressing "Turn off" disables the toggle.
//   7. The toggle state persists across app restarts (via SharedPreferences).
//
// SharedPreferences is mocked with `SharedPreferences.setMockInitialValues`
// so the tests do not require platform plugins.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/features/gateway/toggle.dart';

void main() {
  // Each test gets a clean SharedPreferences mock so persisted state from
  // one test does not leak into another.
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Pumps the widget under test wrapped in a Riverpod `ProviderScope` so
  /// the singleton `gatewayEnabledProvider` is fresh per test.
  Future<void> pumpGatewayToggle(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: GatewayToggleTile(),
          ),
        ),
      ),
    );
    // Allow the async `_load()` call in the notifier to resolve so the
    // initial state is settled before the test interacts with the tile.
    await tester.pumpAndSettle();
  }

  group('GatewayToggleTile', () {
    testWidgets('renders the settings tile with the correct title and OFF '
        'state by default', (WidgetTester tester) async {
      await pumpGatewayToggle(tester);

      expect(find.byType(GatewayToggleTile), findsOneWidget);
      expect(find.text(kGatewayToggleTitle), findsOneWidget);
      // SwitchListTile is the actual interactive widget.
      expect(find.byType(SwitchListTile), findsOneWidget);
      // The Switch child should be off (no value).
      final Switch switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.value, isFalse);
    });

    testWidgets('tapping when OFF shows the safety warning modal with the '
        'verbatim spec text', (WidgetTester tester) async {
      await pumpGatewayToggle(tester);

      // Tap the tile (the row itself is the tap target; tapping its center
      // triggers the onChanged callback).
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      // The safety warning dialog must appear, with the verbatim text.
      expect(find.byKey(const ValueKey<String>('gatewaySafetyWarningDialog')),
          findsOneWidget);
      expect(find.text(kGatewaySafetyWarning), findsOneWidget);
      expect(find.text(kGatewaySafetyWarningTitle), findsOneWidget);
      expect(find.text(kGatewayEnableConfirmLabel), findsOneWidget);
      expect(find.text(kGatewayEnableCancelLabel), findsOneWidget);

      // The toggle must still be OFF — the warning hasn't been confirmed.
      final Switch switchBefore =
          tester.widget<Switch>(find.byType(Switch));
      expect(switchBefore.value, isFalse);
    });

    testWidgets('pressing "Confirm" in the safety warning enables the toggle',
        (WidgetTester tester) async {
      await pumpGatewayToggle(tester);

      // Open the warning.
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      // Confirm it.
      await tester.tap(
          find.byKey(const ValueKey<String>('gatewaySafetyWarningConfirm')));
      await tester.pumpAndSettle();

      // The dialog should be gone, and the toggle should be ON.
      expect(find.byKey(const ValueKey<String>('gatewaySafetyWarningDialog')),
          findsNothing);
      final Switch switchAfter = tester.widget<Switch>(find.byType(Switch));
      expect(switchAfter.value, isTrue);
    });

    testWidgets('pressing "Cancel" in the safety warning leaves the toggle OFF',
        (WidgetTester tester) async {
      await pumpGatewayToggle(tester);

      // Open the warning.
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      // Cancel it.
      await tester.tap(
          find.byKey(const ValueKey<String>('gatewaySafetyWarningCancel')));
      await tester.pumpAndSettle();

      // The dialog should be gone, and the toggle should still be OFF.
      expect(find.byKey(const ValueKey<String>('gatewaySafetyWarningDialog')),
          findsNothing);
      final Switch switchAfter = tester.widget<Switch>(find.byType(Switch));
      expect(switchAfter.value, isFalse);
    });

    testWidgets('tapping when ON shows the "Turn off?" confirmation dialog',
        (WidgetTester tester) async {
      // Pre-seed prefs as ON so the notifier loads with enabled=true.
      SharedPreferences.setMockInitialValues(<String, Object>{
        kGatewayEnabledPrefKey: true,
      });

      await pumpGatewayToggle(tester);

      // After loading, the switch should be ON.
      Switch switchBefore = tester.widget<Switch>(find.byType(Switch));
      expect(switchBefore.value, isTrue);

      // Tap the tile.
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      // The "Turn off?" dialog should appear.
      expect(find.byKey(const ValueKey<String>('gatewayDisableDialog')),
          findsOneWidget);
      expect(find.text(kGatewayDisableDialogTitle), findsOneWidget);
      expect(find.text(kGatewayDisableDialogBody), findsOneWidget);
      expect(find.text(kGatewayDisableConfirmLabel), findsOneWidget);
      expect(find.text(kGatewayDisableCancelLabel), findsOneWidget);

      // The toggle should still be ON (we haven't confirmed yet).
      switchBefore = tester.widget<Switch>(find.byType(Switch));
      expect(switchBefore.value, isTrue);
    });

    testWidgets('pressing "Turn off" in the disable dialog disables the toggle',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kGatewayEnabledPrefKey: true,
      });

      await pumpGatewayToggle(tester);

      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      await tester.tap(
          find.byKey(const ValueKey<String>('gatewayDisableConfirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('gatewayDisableDialog')),
          findsNothing);
      final Switch switchAfter = tester.widget<Switch>(find.byType(Switch));
      expect(switchAfter.value, isFalse);
    });

    testWidgets('pressing "Keep on" in the disable dialog keeps the toggle ON',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kGatewayEnabledPrefKey: true,
      });

      await pumpGatewayToggle(tester);

      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();

      await tester.tap(
          find.byKey(const ValueKey<String>('gatewayDisableCancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('gatewayDisableDialog')),
          findsNothing);
      final Switch switchAfter = tester.widget<Switch>(find.byType(Switch));
      expect(switchAfter.value, isTrue);
    });

    testWidgets('safety warning text matches SPEC §10 verbatim',
        (WidgetTester tester) async {
      // Pin the exact wording from SPEC.md (Implementation Decisions >
      // Gateway mode > Safety note on enable). If SPEC.md is updated, this
      // test should be updated to match — and the const in toggle.dart
      // should be updated in lockstep.
      const String expectedVerbatim =
          'Acting as a Gateway relays encrypted mesh traffic through your '
          'internet connection on behalf of nearby devices. In a monitored '
          'or hostile network environment, this can make your device '
          'identifiable as a bridge point.';
      expect(kGatewaySafetyWarning, equals(expectedVerbatim));

      // And the dialog must actually render that text.
      await pumpGatewayToggle(tester);
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();
      expect(find.text(expectedVerbatim), findsOneWidget);
    });

    testWidgets('toggle state persists across app restarts',
        (WidgetTester tester) async {
      // First "session": enable the toggle.
      await pumpGatewayToggle(tester);
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey<String>('gatewaySafetyWarningConfirm')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byType(Switch)).value,
        isTrue,
      );

      // Second "session": rebuild the widget tree (simulates app restart)
      // with the SAME SharedPreferences mock — the toggle should come back
      // ON.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: GatewayToggleTile(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byType(Switch)).value,
        isTrue,
      );
    });

    testWidgets('disable action persists OFF across app restarts',
        (WidgetTester tester) async {
      // Start with ON persisted.
      SharedPreferences.setMockInitialValues(<String, Object>{
        kGatewayEnabledPrefKey: true,
      });

      // First session: disable.
      await pumpGatewayToggle(tester);
      await tester.tap(find.byType(GatewayToggleTile));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey<String>('gatewayDisableConfirm')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byType(Switch)).value,
        isFalse,
      );

      // Second session: rebuild — should still be OFF.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: GatewayToggleTile(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(find.byType(Switch)).value,
        isFalse,
      );
    });

    testWidgets('sample app renders the toggle tile',
        (WidgetTester tester) async {
      // The public sample `GatewayToggleSampleApp` (used in standalone /
      // demo / testing scenarios) should build a MaterialApp containing the
      // toggle tile.
      await tester.pumpWidget(const GatewayToggleSampleApp());
      await tester.pumpAndSettle();
      expect(find.byType(GatewayToggleTile), findsOneWidget);
      expect(find.text(kGatewayToggleTitle), findsOneWidget);
    });
  });
}
