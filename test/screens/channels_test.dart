// RelayLink — Ticket #41 channels screen widget tests.
//
// Verifies the user-visible behavior of `ChannelsScreen`:
//   1. Renders one row per joined channel (always `public` once
//      `ChannelKeyStore.init()` has run).
//   2. The row matching `activeChannelId` shows the "active" hint and a
//      filled radio icon.
//   3. The `public` row shows the lock icon (cannot leave).
//   4. Tapping a non-public row fires `onActiveChannelChanged` with that
//      channel id; tapping the already-active row is a no-op.
//   5. Create flow: dialog → name → key generated → row appears → invite
//      overlay shown.
//   6. Create flow rejects invalid names (with, comma, empty).
//   7. Join flow: injected scan callback returns payload → row added →
//      list refreshed.
//   8. Join flow: malformed payload surfaces an error under the button,
//      no row added.
//   9. Join button is disabled when no scan callback is injected.
//  10. `parseChannelInvite` round-trips and rejects garbage payloads.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/channels/keys.dart';
import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/screens/channels.dart';

void main() {
  late ChannelKeyStore store;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = ChannelKeyStore.withStorage(const FlutterSecureStorage());
    await store.init();
  });

  /// Pump [child] into a `MaterialApp` + `Scaffold` so AppBar /
  /// Navigator / Dialog all work.
  Future<void> pumpChannels(
    WidgetTester tester, {
    required Widget child,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Standard wiring: an in-memory `activeChannelId` + a recorder for
  /// the `onActiveChannelChanged` callback. Returns the active id
  /// holder and the list of picked ids so each test can assert.
  ({ValueNotifier<String> active, List<String> picked}) wire({
    String initialActive = kPublicChannelId,
  }) {
    final picked = <String>[];
    final active = ValueNotifier<String>(initialActive);
    return (
      active: active,
      picked: picked,
    );
  }

  Widget buildScreen({
    required ValueNotifier<String> active,
    required List<String> picked,
    ScanQrCallback? scanQr,
    Widget Function(BuildContext, String, List<int>)? showQrInvite,
  }) {
    return ChannelsScreen(
      keyStore: store,
      activeChannelId: active.value,
      onActiveChannelChanged: (id) {
        picked.add(id);
        active.value = id;
      },
      scanQr: scanQr,
      showQrInvite: showQrInvite,
    );
  }

  group('parseChannelInvite', () {
    test('round-trips a known channel + key', () {
      final key = Uint8List.fromList(List<int>.filled(32, 7));
      final payload = 'ops:${base64.encode(key)}';
      final parsed = parseChannelInvite(payload);
      expect(parsed, isNotNull);
      expect(parsed!.channelId, 'ops');
      expect(parsed.key, equals(key));
    });

    test('accepts URL-safe base64 with missing padding', () {
      final key = Uint8List.fromList(List<int>.filled(32, 1));
      // Strip '=' padding and switch to URL-safe chars.
      final std = base64.encode(key);
      final urlSafe = std.replaceAll('+', '-').replaceAll('/', '_')
          .replaceAll('=', '');
      final parsed = parseChannelInvite('dev:$urlSafe');
      expect(parsed, isNotNull);
      expect(parsed!.key, equals(key));
    });

    test('rejects payload without a colon', () {
      expect(parseChannelInvite('nope'), isNull);
    });

    test('rejects empty channel id', () {
      final key = List<int>.filled(32, 0);
      expect(parseChannelInvite(':${base64.encode(key)}'), isNull);
    });

    test('rejects empty key', () {
      expect(parseChannelInvite('ops:'), isNull);
    });

    test('rejects wrong-length key', () {
      final short = base64.encode(List<int>.filled(16, 0));
      expect(parseChannelInvite('ops:$short'), isNull);
    });

    test('rejects non-base64 key', () {
      expect(parseChannelInvite('ops:!!!not-base64!!!'), isNull);
    });

    test('rejects empty / whitespace payload', () {
      expect(parseChannelInvite(''), isNull);
      expect(parseChannelInvite('   '), isNull);
    });

    test('rejects channel id with comma (would corrupt index)', () {
      final key = List<int>.filled(32, 0);
      expect(parseChannelInvite('a,b:${base64.encode(key)}'), isNull);
    });
  });

  group('ChannelsScreen — list + active indicator', () {
    testWidgets('renders a row per joined channel including public',
        (WidgetTester tester) async {
      await store.addChannel('ops', store.generateKey());
      await store.addChannel('dev', store.generateKey());

      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      expect(find.byKey(const ValueKey<String>('channelRow::public')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('channelRow::ops')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('channelRow::dev')),
          findsOneWidget);
    });

    testWidgets('public row shows the lock icon and cannot-leave hint',
        (WidgetTester tester) async {
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );
      expect(find.byKey(const ValueKey<String>('channelLockIcon')),
          findsOneWidget);
      expect(find.text('default public channel (cannot leave)'),
          findsOneWidget);
    });

    testWidgets('active row shows the active hint and filled radio icon',
        (WidgetTester tester) async {
      await store.addChannel('ops', store.generateKey());
      final w = wire(initialActive: 'ops');
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      // Two rows in the tree; one active, one not.
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
      expect(find.text('active — chat will send here'), findsOneWidget);
    });
  });

  group('ChannelsScreen — switcher', () {
    testWidgets('tapping a non-active row emits onActiveChannelChanged',
        (WidgetTester tester) async {
      await store.addChannel('ops', store.generateKey());
      final w = wire(initialActive: kPublicChannelId);
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      await tester.tap(find.byKey(const ValueKey<String>('channelRow::ops')));
      await tester.pumpAndSettle();

      expect(w.picked, <String>['ops']);
      expect(w.active.value, 'ops');
    });

    testWidgets('tapping the already-active row is a no-op',
        (WidgetTester tester) async {
      final w = wire(initialActive: kPublicChannelId);
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      await tester.tap(
          find.byKey(const ValueKey<String>('channelRow::public')));
      await tester.pumpAndSettle();

      expect(w.picked, isEmpty);
    });
  });

  group('ChannelsScreen — create flow', () {
    testWidgets(
        'create flow: name → key generated → row appears → invite overlay',
        (WidgetTester tester) async {
      final w = wire();
      Widget inviteBuilder(BuildContext ctx, String id, List<int> key) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('invite for $id'),
          ],
        );
      }

      await pumpChannels(
        tester,
        child: buildScreen(
          active: w.active,
          picked: w.picked,
          showQrInvite: inviteBuilder,
        ),
      );

      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelButton')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('createChannelDialog')),
          findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey<String>('createChannelNameField')),
          'ops');
      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelConfirm')));
      await tester.pumpAndSettle();

      // Dialog dismissed, invite overlay shown.
      expect(find.byKey(const ValueKey<String>('createChannelDialog')),
          findsNothing);
      expect(find.byKey(const ValueKey<String>('inviteQrDialog')),
          findsOneWidget);
      expect(find.text('invite for ops'), findsOneWidget);

      // Row is in the joined list.
      final ids = await store.listChannels();
      expect(ids, contains('ops'));
      expect(find.byKey(const ValueKey<String>('channelRow::ops')),
          findsOneWidget);

      // Dismiss overlay so subsequent assertions are clean.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('inviteQrDialog')),
          findsNothing);
    });

    testWidgets('create flow: cancel does not add a channel',
        (WidgetTester tester) async {
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelButton')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelCancel')));
      await tester.pumpAndSettle();

      final ids = await store.listChannels();
      expect(ids, equals(<String>[kPublicChannelId]));
    });

    testWidgets('create flow: invalid name surfaces an error',
        (WidgetTester tester) async {
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      // Empty name.
      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelButton')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelConfirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('channelsScanError')),
          findsOneWidget);

      // Comma-in-name attempt.
      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelButton')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey<String>('createChannelNameField')),
          'a,b');
      await tester.tap(
          find.byKey(const ValueKey<String>('createChannelConfirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('channelsScanError')),
          findsOneWidget);

      // No extra channels added.
      final ids = await store.listChannels();
      expect(ids, equals(<String>[kPublicChannelId]));
    });
  });

  group('ChannelsScreen — join flow', () {
    testWidgets('join flow: scan callback returns payload → row added',
        (WidgetTester tester) async {
      final key = Uint8List.fromList(List<int>.filled(32, 9));
      final payload = 'remote-ops:${base64.encode(key)}';
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(
          active: w.active,
          picked: w.picked,
          scanQr: () async => payload,
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('joinChannelButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('channelRow::remote-ops')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('channelsScanError')),
          findsNothing);
    });

    testWidgets('join flow: malformed payload surfaces an error',
        (WidgetTester tester) async {
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(
          active: w.active,
          picked: w.picked,
          scanQr: () async => 'not-a-channel-invite',
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('joinChannelButton')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey<String>('channelsScanError')),
          findsOneWidget);
      expect(find.text('QR did not contain a channel invite'), findsOneWidget);
      final ids = await store.listChannels();
      expect(ids, equals(<String>[kPublicChannelId]));
    });

    testWidgets('join flow: cancelled scan (null) is a no-op',
        (WidgetTester tester) async {
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(
          active: w.active,
          picked: w.picked,
          scanQr: () async => null,
        ),
      );

      await tester.tap(find.byKey(const ValueKey<String>('joinChannelButton')));
      await tester.pumpAndSettle();

      final ids = await store.listChannels();
      expect(ids, equals(<String>[kPublicChannelId]));
      expect(find.byKey(const ValueKey<String>('channelsScanError')),
          findsNothing);
    });

    testWidgets('join button is disabled when no scan callback is injected',
        (WidgetTester tester) async {
      final w = wire();
      await pumpChannels(
        tester,
        child: buildScreen(active: w.active, picked: w.picked),
      );

      final button = tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey<String>('joinChannelButton')),
          );
      expect(button.onPressed, isNull);
    });
  });
}