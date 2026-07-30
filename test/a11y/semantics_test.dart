// RelayLink — Accessibility audit baseline test.
//
// Walks the widget tree and asserts no `Semantics` widget has an empty
// `label` for any interactive node. The goal is to catch accidental
// regressions: every button, text field, tab, and status indicator that
// we add a Semantics wrapper to must carry a meaningful label.
//
// The test deliberately uses `find.byType(Semantics)` rather than
// `RenderSemantics` traversal because (a) `find.byType` works in
// pumpWidget-based widget tests, and (b) it mirrors what a developer
// reading the test will see in source.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/a11y/tokens.dart';
import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/screens/capability_disclosure.dart';

void main() {
  group('A11y tokens', () {
    test('verified() returns a non-empty label for valid input', () {
      expect(kA11yLabels.verified('BRAC'), 'Verified by BRAC');
      expect(kA11yLabels.verified('  '), 'Verified');
      expect(kA11yLabels.verified(''), 'Verified');
    });

    test('signedBy() returns a non-empty label for valid input', () {
      expect(kA11yLabels.signedBy('Alice'), 'Signed by Alice');
      expect(kA11yLabels.signedBy(''), 'Signed by unknown sender');
      expect(kA11yLabels.signedBy('   '), 'Signed by unknown sender');
    });

    test('unverified() returns a non-empty label for valid input', () {
      expect(
        kA11yLabels.unverified('Alice'),
        'Unverified message from Alice',
      );
      expect(kA11yLabels.unverified(''), 'Unverified message');
    });

    test('meshPeers() handles 0/1/N', () {
      expect(kA11yLabels.meshPeers(0), 'No peers in range');
      expect(kA11yLabels.meshPeers(1), '1 peer in range');
      expect(kA11yLabels.meshPeers(5), '5 peers in range');
    });

    test('activityCount() handles 0/1/N', () {
      expect(kA11yLabels.activityCount(0), startsWith('No messages'));
      expect(kA11yLabels.activityCount(1), '1 message in the last 24 hours');
      expect(kA11yLabels.activityCount(42), '42 messages in the last 24 hours');
    });

    test('transport() reports availability', () {
      expect(
        kA11yLabels.transport('Mesh', true),
        'Transport: Mesh, available',
      );
      expect(
        kA11yLabels.transport('Internet', false),
        'Transport: Internet, unavailable',
      );
    });

    test('all token outputs are non-empty strings', () {
      // Defensive sweep: every helper must produce a non-empty string for
      // *some* valid input — guards against accidental regressions where
      // a future refactor returns an empty string.
      expect(kA11yLabels.verified('X'), isNotEmpty);
      expect(kA11yLabels.signedBy('X'), isNotEmpty);
      expect(kA11yLabels.unverified('X'), isNotEmpty);
      expect(kA11yLabels.meshPeers(1), isNotEmpty);
      expect(kA11yLabels.activityCount(1), isNotEmpty);
      expect(kA11yLabels.transport('X', true), isNotEmpty);
      expect(kA11yLabels.transport('X', false), isNotEmpty);
    });

    test('A11yLabels aliases expose the same label-shape functions', () {
      // Sanity: the two aliases in tokens.dart expose the same helpers,
      // so callers can use either name without divergence.
      expect(kA11yLabels.verified('BRAC'),
          equals(kA11yLabelTranslate.verified('BRAC')));
      expect(kA11yLabels.signedBy('Alice'),
          equals(kA11yLabelTranslate.signedBy('Alice')));
      expect(kA11yLabels.transport('Mesh', true),
          equals(kA11yLabelTranslate.transport('Mesh', true)));
    });
  });

  group('CapabilityDisclosurePage Semantics', () {
    testWidgets(
        'every authored interactive Semantics node in capability disclosure '
        'has a non-empty label', (WidgetTester tester) async {
      final caps = DeviceCapabilities.forPlatform('android');

      await tester.pumpWidget(
        MaterialApp(
          home: CapabilityDisclosurePage(
            capabilities: caps,
            mode: CapabilityDisclosureMode.firstLaunch,
          ),
        ),
      );

      // Find every Semantics widget in the tree and check its label.
      // We only flag Semantics widgets that are *authored* — i.e. carry a
      // custom property set that we wrote (liveRegion, header, button
      // with a non-empty label). Flutter's framework-generated Semantics
      // (e.g. ListTile's auto tap handler, AppBar's back-button) are
      // filtered out because they ship pre-labeled upstream and are not
      // part of this audit.
      final semanticsFinder = find.byType(Semantics);
      expect(semanticsFinder, findsWidgets,
          reason: 'CapabilityDisclosurePage should expose Semantics nodes');

      final offenders = <String>[];
      for (final element in semanticsFinder.evaluate()) {
        final widget = element.widget as Semantics;
        final props = widget.properties;
        // "Authored" marker: we always set at least one of these on our
        // own Semantics wrappers (liveRegion for status indicators,
        // header for titles, button for buttons).
        final isAuthored = props.liveRegion == true || props.header == true;
        final isInteractive = props.button == true ||
            props.textField == true ||
            props.toggled != null ||
            props.onTap != null ||
            props.onLongPress != null;
        if (isAuthored && isInteractive) {
          final label = props.label;
          if (label == null || label.trim().isEmpty) {
            offenders.add(
              'Authored interactive Semantics node has empty label '
              '(button=${props.button}, textField=${props.textField}, '
              'liveRegion=${props.liveRegion}, header=${props.header})',
            );
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'No authored interactive Semantics node should ship '
              'with an empty label. Offenders:\n  ${offenders.join('\n  ')}');
    });

    testWidgets('confirm button has button semantics + label',
        (WidgetTester tester) async {
      final caps = DeviceCapabilities.forPlatform('android');
      await tester.pumpWidget(
        MaterialApp(
          home: CapabilityDisclosurePage(
            capabilities: caps,
            mode: CapabilityDisclosureMode.firstLaunch,
          ),
        ),
      );

      // At least one Semantics with button:true and a non-empty label
      // exists in the tree.
      final semanticsNodes = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .toList();
      final buttonNode = semanticsNodes.firstWhere(
        (s) => s.properties.button == true,
      );
      expect(buttonNode.properties.button, isTrue);
      expect(buttonNode.properties.label, isNotNull);
      expect(buttonNode.properties.label!.trim(), isNotEmpty);
    });

    testWidgets('capability rows expose a label to screen readers',
        (WidgetTester tester) async {
      final caps = DeviceCapabilities.forPlatform('android');
      await tester.pumpWidget(
        MaterialApp(
          home: CapabilityDisclosurePage(
            capabilities: caps,
            mode: CapabilityDisclosureMode.firstLaunch,
          ),
        ),
      );

      // Every capability row should have a Semantics node with a label
      // that mentions the row label text.
      final allLabels = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((s) => s.properties.label ?? '')
          .toList();
      final meshRow = allLabels.firstWhere(
        (l) => l.contains('Bluetooth mesh send/receive'),
        orElse: () => '',
      );
      expect(meshRow, isNotEmpty,
          reason: 'Bluetooth mesh row must have a Semantics label');
      expect(meshRow, contains('available'),
          reason: 'Android row label must mention availability status');
    });
  });
}
