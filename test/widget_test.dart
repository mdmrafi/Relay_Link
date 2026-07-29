// Smoke test for the Ticket #01 scaffold home screen.
// Ticket #30 wraps the home in a first-launch disclosure gate that
// asynchronously loads the "seen" flag from shared_preferences. The
// disclosure is presented only when the flag is false, so we seed the
// seen flag and pump past the gate before asserting.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/main.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Pretend the user has already seen the capability disclosure so
      // the overlay doesn't push a route that hides the home screen.
      'capability_disclosure_seen_v1': true,
    });
  });

  testWidgets('Home screen displays "RelayLink"', (WidgetTester tester) async {
    await tester.pumpWidget(const RelayLinkApp());
    // Pump past the first-launch gate's async shared_preferences load.
    await tester.pumpAndSettle();

    expect(find.text('RelayLink'), findsOneWidget);
  });
}