// Smoke test for the Ticket #01 scaffold home screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/main.dart';

void main() {
  testWidgets('Home screen displays "RelayLink"', (WidgetTester tester) async {
    await tester.pumpWidget(const RelayLinkApp());

    expect(find.text('RelayLink'), findsOneWidget);
  });
}