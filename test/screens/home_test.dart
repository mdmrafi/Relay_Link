// RelayLink — Ticket #38: Home screen widget tests.
//
// Verifies the user-visible behavior of the home screen:
//   1. Header shows "RelayLink" + own SenderId (truncated).
//   2. Transport status row renders one chip per transport (mesh, sms,
//      internet) with ✓/✗ reflecting capability + live availability.
//   3. Peer count badge shows the current peer count.
//   4. Recent activity card shows the 24h count from LocalDb.
//   5. Tapping a transport status invokes the onTransportTapped hook
//      (and surfaces a snackbar in dev mode).
//   6. Tab bar exposes the five destinations (Home, Chat, Vault,
//      Channels, Settings).
//   7. The truncateSenderId helper drops a too-long id down to 16 chars.
//
// State is injected by overriding the Riverpod providers in each test's
// ProviderScope, so we never depend on real platform / identity / DB
// state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/screens/home.dart';

Future<void> _pumpHome(
  WidgetTester tester, {
  HomeTab initialTab = HomeTab.home,
  void Function(HomeTab)? onTabChanged,
  void Function(HomeTransport)? onTransportTapped,
  VoidCallback? onComposeTapped,
  VoidCallback? onChannelsTapped,
  VoidCallback? onVaultTapped,
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: HomeScreen(
          initialTab: initialTab,
          onTabChanged: onTabChanged,
          onTransportTapped: onTransportTapped,
          onComposeTapped: onComposeTapped,
          onChannelsTapped: onChannelsTapped,
          onVaultTapped: onVaultTapped,
        ),
      ),
    ),
  );
  // Let the FutureProvider for activity resolve to its initial loading
  // state, then settle.
  await tester.pump();
  await tester.pump();
}

void main() {
  /// Standard overrides used by most tests. Tests that want to override
  /// individual providers add to this list before passing it to
  /// [_pumpHome].
  List<Override> baseOverrides({
    String senderId = '0123456789abcdef',
    DeviceCapabilities? capabilities,
    int peerCount = 0,
    bool smsAvailable = false,
    bool internetReachable = false,
  }) {
    return <Override>[
      ownSenderIdProvider.overrideWith((_) => senderId),
      deviceCapabilitiesProvider.overrideWith(
        (_) => capabilities ?? DeviceCapabilities.forPlatform('android'),
      ),
      meshPeerCountProvider.overrideWith((_) => peerCount),
      smsAvailableProvider.overrideWith((_) => smsAvailable),
      internetReachableProvider.overrideWith((_) => internetReachable),
    ];
  }

  group('truncateSenderId', () {
    test('returns the value unchanged when <= 16 chars', () {
      expect(truncateSenderId('0123456789abcdef'), '0123456789abcdef');
      expect(truncateSenderId(''), '');
      expect(truncateSenderId('abc'), 'abc');
    });

    test('truncates to 16 chars when longer', () {
      expect(
        truncateSenderId('0123456789abcdefdeadbeefcafef00d'),
        '0123456789abcdef',
      );
    });
  });

  group('HomeScreen — header', () {
    testWidgets('shows "RelayLink" and own SenderId (truncated)',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: baseOverrides(senderId: 'aabbccddeeff0011'),
      );

      expect(find.text('RelayLink'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('homeSenderIdText')),
        findsOneWidget,
      );
      final senderText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('homeSenderIdText')),
      );
      expect(senderText.data, 'aabbccddeeff0011');
    });

    testWidgets('renders a "…" placeholder when no SenderId is loaded yet',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: baseOverrides(senderId: ''),
      );

      expect(
        find.byKey(const ValueKey<String>('homeSenderIdText')),
        findsOneWidget,
      );
      final senderText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('homeSenderIdText')),
      );
      expect(senderText.data, '…');
    });
  });

  group('HomeScreen — transport status row', () {
    testWidgets('renders one chip per transport (mesh, sms, internet)',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: baseOverrides(
          capabilities: DeviceCapabilities.forPlatform('android'),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('homeTransportRow')),
        findsOneWidget,
      );
      for (final t in HomeTransport.values) {
        expect(
          find.byKey(ValueKey<String>('transportChip::${t.name}')),
          findsOneWidget,
          reason: 'missing chip for transport ${t.name}',
        );
      }
    });

    testWidgets('shows ✓ icon for available transports and ✗ for off ones',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: baseOverrides(
          capabilities: DeviceCapabilities.forPlatform('android'),
          smsAvailable: true,
          internetReachable: true,
        ),
      );

      // All three on → 3 check-circles, 0 cancels.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(3));
      expect(find.byIcon(Icons.cancel), findsNothing);
    });

    testWidgets('shows ✗ when capability is unavailable (iOS for SMS)',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: baseOverrides(
          // iOS: SMS send/receive unavailable.
          capabilities: DeviceCapabilities.forPlatform('ios'),
          // Even if the live radio says "on", the capability gate
          // forces the chip off.
          smsAvailable: true,
          internetReachable: true,
        ),
      );

      // Mesh (capability on, radio on) → ✓. SMS (capability off) → ✗.
      // Internet (capability on, internet on) → ✓. So 2 ✓ and 1 ✗.
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.cancel), findsOneWidget);
    });

    testWidgets('tapping a chip fires onTransportTapped with the transport',
        (WidgetTester tester) async {
      final tapped = <HomeTransport>[];
      await _pumpHome(
        tester,
        onTransportTapped: tapped.add,
        overrides: baseOverrides(
          capabilities: DeviceCapabilities.forPlatform('android'),
          internetReachable: true,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('transportChip::mesh')),
      );
      await tester.pump(); // start the snackbar animation
      expect(tapped, <HomeTransport>[HomeTransport.mesh]);
    });

    testWidgets('tapping the internet chip fires the internet callback',
        (WidgetTester tester) async {
      final tapped = <HomeTransport>[];
      await _pumpHome(
        tester,
        onTransportTapped: tapped.add,
        overrides: baseOverrides(
          capabilities: DeviceCapabilities.forPlatform('android'),
          internetReachable: true,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('transportChip::internet')),
      );
      await tester.pump();
      expect(tapped, <HomeTransport>[HomeTransport.internet]);
    });
  });

  group('HomeScreen — peer count + activity', () {
    testWidgets('peer count badge reflects meshPeerCountProvider',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: baseOverrides(peerCount: 7),
      );

      expect(
        find.byKey(const ValueKey<String>('homePeerCountCard')),
        findsOneWidget,
      );
      final valueText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('homePeerCountValue')),
      );
      expect(valueText.data, '7');
    });

    testWidgets('activity card renders the 24h count once loaded',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: <Override>[
          ...baseOverrides(),
          // Force the activity query into a known data state without
          // touching LocalDb.
          homeActivityProvider.overrideWith(
            (_) async => const HomeActivityCount(count24h: 42, known: true),
          ),
        ],
      );
      await tester.pumpAndSettle();

      final valueText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('homeActivityValue')),
      );
      expect(valueText.data, '42');
    });

    testWidgets('activity card renders "—" while the query is unknown',
        (WidgetTester tester) async {
      await _pumpHome(
        tester,
        overrides: <Override>[
          ...baseOverrides(),
          homeActivityProvider.overrideWith(
            (_) async => const HomeActivityCount(count24h: 0, known: false),
          ),
        ],
      );
      await tester.pumpAndSettle();

      final valueText = tester.widget<Text>(
        find.byKey(const ValueKey<String>('homeActivityValue')),
      );
      expect(valueText.data, '—');
    });
  });

  group('HomeScreen — quick actions', () {
    testWidgets('renders the three quick-action buttons',
        (WidgetTester tester) async {
      await _pumpHome(tester, overrides: baseOverrides());

      expect(
        find.byKey(const ValueKey<String>('homeQuickActionGrid')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('homeComposeButton')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('homeChannelsButton')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('homeVaultButton')),
          findsOneWidget);
    });

    testWidgets('tapping compose fires the compose callback',
        (WidgetTester tester) async {
      var composeCalls = 0;
      await _pumpHome(
        tester,
        onComposeTapped: () => composeCalls++,
        overrides: baseOverrides(),
      );

      await tester.tap(find.byKey(const ValueKey<String>('homeComposeButton')));
      await tester.pump();
      expect(composeCalls, 1);
    });

    testWidgets('tapping channels fires the channels callback',
        (WidgetTester tester) async {
      var channelCalls = 0;
      await _pumpHome(
        tester,
        onChannelsTapped: () => channelCalls++,
        overrides: baseOverrides(),
      );

      await tester.tap(
          find.byKey(const ValueKey<String>('homeChannelsButton')));
      await tester.pump();
      expect(channelCalls, 1);
    });

    testWidgets('tapping vault fires the vault callback',
        (WidgetTester tester) async {
      var vaultCalls = 0;
      await _pumpHome(
        tester,
        onVaultTapped: () => vaultCalls++,
        overrides: baseOverrides(),
      );

      await tester.tap(find.byKey(const ValueKey<String>('homeVaultButton')));
      await tester.pump();
      expect(vaultCalls, 1);
    });
  });

  group('HomeScreen — tab bar', () {
    testWidgets('renders all five tabs', (WidgetTester tester) async {
      await _pumpHome(tester, overrides: baseOverrides());

      expect(find.byKey(const ValueKey<String>('homeTabBar')), findsOneWidget);
      for (final tab in HomeTab.values) {
        expect(
          find.byKey(ValueKey<String>('homeTab::${tab.name}')),
          findsOneWidget,
          reason: 'missing tab ${tab.name}',
        );
      }
    });

    testWidgets('tapping a tab fires the onTabChanged callback',
        (WidgetTester tester) async {
      final visited = <HomeTab>[];
      await _pumpHome(
        tester,
        onTabChanged: visited.add,
        overrides: baseOverrides(),
      );

      // The Vault tab is index 2 in the HomeTabBar's tab list.
      await tester.tap(find.byKey(const ValueKey<String>('homeTab::vault')));
      await tester.pump();
      expect(visited, <HomeTab>[HomeTab.vault]);
    });
  });

  group('HomeScreen — gateway integration', () {
    testWidgets('internet chip flips to ✓ when internetReachable flips on',
        (WidgetTester tester) async {
      // Stream through the live internet provider so we can observe the
      // chip flip in real time without touching the gateway notifier
      // (which calls SharedPreferences in its constructor).
      final container = ProviderContainer(
        overrides: <Override>[
          ...baseOverrides(
            capabilities: DeviceCapabilities.forPlatform('android'),
          ),
          internetReachableProvider.overrideWith((_) => false),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();

      // Pre-toggle: 2 ✗ (SMS, internet) + 1 ✓ (mesh). Internet off.
      expect(find.byIcon(Icons.cancel), findsNWidgets(2));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // Flip internet on → internet chip turns ✓; mesh still ✓; SMS ✗.
      container.read(internetReachableProvider.notifier).state = true;
      await tester.pump();

      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byIcon(Icons.cancel), findsOneWidget);
    });
  });
}
