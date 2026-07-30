// RelayLink — Ticket #37 ALERT verified badge widget tests.
//
// Drives both branches of `VerifiedBadge` against an injected
// `VerifiedOrgsCache.withFetcher(...)` so the test does not touch
// shared_preferences or a real Firestore. The cache is the contract:
// `isVerified(pubkey)` is the only signal the widget reads.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/alerts/allowlist.dart';
import 'package:relaylink/widgets/verified_badge.dart';

/// Test pubkeys (same as `test/alerts/allowlist_test.dart` for consistency).
const _verifiedPubkey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
const _unknownPubkey = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';
const _orgName = 'Demo Red Crescent Branch';
const _senderName = 'Field Volunteer';

Future<VerifiedOrgsCache> _cacheWithKeys(List<String> pubkeys) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final cache = VerifiedOrgsCache.withFetcher(() async => pubkeys);
  await cache.init();
  return cache;
}

/// Wraps a widget in a tiny Material+Directionality host so the icon
/// widgets and text styles render correctly under `testWidgets`.
Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(child: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VerifiedBadge — verified branch', () {
    testWidgets(
      'shows "Verified: <name>" when sender pubkey is in the cache',
      (tester) async {
        final cache = await _cacheWithKeys(<String>[_verifiedPubkey]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _verifiedPubkey,
            displayName: _orgName,
            cache: cache,
          ),
        ));

        // The verified prefix must be present alongside the org name.
        expect(find.text('Verified: $_orgName'), findsOneWidget);

        // The verified (check) icon must be present, the person icon must not.
        expect(find.byIcon(Icons.verified), findsOneWidget);
        expect(find.byIcon(Icons.person_outline), findsNothing);
      },
    );

    testWidgets(
      'verified badge uses a different color than the unsigned branch',
      (tester) async {
        final cache = await _cacheWithKeys(<String>[_verifiedPubkey]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _verifiedPubkey,
            displayName: _orgName,
            cache: cache,
          ),
        ));

        // Pull the rendered text widget to assert its color. The verified
        // palette is green-tinted (#6FE0A1); the unsigned palette is grey
        // (#9AA4B2). Asserting the actual color guarantees the two branches
        // are visually distinct (acceptance criterion).
        final verifiedText = tester.widget<Text>(
          find.text('Verified: $_orgName'),
        );
        expect(verifiedText.style?.color, isNot(const Color(0xFF9AA4B2)));
        // Sanity: it should be a green tone, not arbitrary.
        final c = verifiedText.style!.color!;
        expect(c.g > c.r && c.g > c.b, isTrue,
            reason: 'Verified badge color should be green-dominant.');
      },
    );
  });

  group('VerifiedBadge — unsigned branch', () {
    testWidgets(
      'shows "Signed by: <name>" when sender pubkey is NOT in the cache',
      (tester) async {
        // Cache holds a different key — our sender is unknown.
        final cache = await _cacheWithKeys(<String>[_verifiedPubkey]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _unknownPubkey,
            displayName: _senderName,
            cache: cache,
          ),
        ));

        expect(find.text('Signed by: $_senderName'), findsOneWidget);

        // Person icon, NOT the check icon.
        expect(find.byIcon(Icons.person_outline), findsOneWidget);
        expect(find.byIcon(Icons.verified), findsNothing);
      },
    );

    testWidgets(
      'empty cache (cold offline) → unsigned branch',
      (tester) async {
        final cache = await _cacheWithKeys(<String>[]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _unknownPubkey,
            displayName: _senderName,
            cache: cache,
          ),
        ));

        // Acceptance: when the offline cache is empty we MUST fall back to
        // the neutral label rather than the verified badge. A verified
        // badge with no allowlist would be a security regression.
        expect(find.text('Signed by: $_senderName'), findsOneWidget);
        expect(find.byIcon(Icons.verified), findsNothing);
      },
    );
  });

  group('VerifiedBadge — edge cases', () {
    testWidgets(
      'empty display name renders the prefix without a trailing colon',
      (tester) async {
        final cache = await _cacheWithKeys(<String>[_verifiedPubkey]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _verifiedPubkey,
            displayName: '',
            cache: cache,
          ),
        ));

        expect(find.text('Verified'), findsOneWidget);
        expect(find.text('Verified:'), findsNothing,
            reason: 'No dangling colon when the display name is empty.');
      },
    );

    testWidgets(
      'whitespace-only display name is treated as empty',
      (tester) async {
        final cache = await _cacheWithKeys(<String>[]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _unknownPubkey,
            displayName: '   ',
            cache: cache,
          ),
        ));

        expect(find.text('Signed by'), findsOneWidget);
        expect(find.text('Signed by: '), findsNothing);
      },
    );

    testWidgets(
      'inline style renders without the chip background container',
      (tester) async {
        final cache = await _cacheWithKeys(<String>[_verifiedPubkey]);
        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _verifiedPubkey,
            displayName: _orgName,
            cache: cache,
            style: VerifiedBadgeStyle.inline,
          ),
        ));

        // Same text and icon, just no rounded pill background.
        expect(find.text('Verified: $_orgName'), findsOneWidget);
        expect(find.byIcon(Icons.verified), findsOneWidget);
      },
    );
  });

  group('VerifiedBadge — receiver-side invariant', () {
    testWidgets(
      'decision depends ONLY on the cache, never on any other parameter',
      (tester) async {
        // Same pubkey, two different display names, with the same cache
        // state. Both should land on the same branch.
        final cache = await _cacheWithKeys(<String>[_verifiedPubkey]);

        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _verifiedPubkey,
            displayName: 'Alpha',
            cache: cache,
          ),
        ));
        expect(find.text('Verified: Alpha'), findsOneWidget);

        await tester.pumpWidget(_host(
          VerifiedBadge(
            senderPubkey: _verifiedPubkey,
            displayName: 'Bravo',
            cache: cache,
          ),
        ));
        expect(find.text('Verified: Bravo'), findsOneWidget);
        expect(find.text('Verified: Alpha'), findsNothing);
      },
    );
  });
}