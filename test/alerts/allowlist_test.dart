// RelayLink — Ticket #36 allowlist sync + local cache tests.
//
// These tests cover the externally observable behavior of VerifiedOrgsCache:
//
//   1. Cache hit (warm cache, no refresh): isVerified returns true for a
//      pubkey that was previously persisted, even when the Firestore fetcher
//      is never invoked (proving we don't hit the network on warm cache).
//   2. Cache miss + refresh: empty cache, online → init() pulls from the
//      injected Firestore fetcher → isVerified becomes true for the
//      returned pubkeys.
//   3. Cache miss + offline (no refresh possible): cold cache, fetcher
//      throws → init() does NOT throw, isVerified returns false, and the
//      empty in-memory set survives the failure.
//
// We inject a fetcher `Future<List<String>> Function()` so tests don't need
// a live Firestore. The default constructor of VerifiedOrgsCache uses the
// real FirebaseBackend; the test constructor takes the fetcher.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/alerts/allowlist.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Shared set of pubkeys used across tests.
  const pubkeyA = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
  const pubkeyB = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';

  setUp(() {
    // Each test gets a clean SharedPreferences backing so persisted state
    // doesn't leak across tests.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('VerifiedOrgsCache — cache hit (warm cache, no refresh)', () {
    test(
      'init() with a fresh warm cache does NOT call the fetcher, and '
      'isVerified returns true for cached pubkeys',
      () async {
        // Seed prefs with a cache that was fetched just now (well within
        // the 24h window) — no refresh should occur.
        final fetchedAt = DateTime.now().toUtc();
        SharedPreferences.setMockInitialValues(<String, Object>{
          kVerifiedOrgsCacheKey: jsonEncode({
            'fetchedAt': fetchedAt.toIso8601String(),
            'pubkeys': <String>[pubkeyA, pubkeyB],
          }),
        });

        var fetcherCalls = 0;
        final cache = VerifiedOrgsCache.withFetcher(() async {
          fetcherCalls += 1;
          return <String>['unrelated-key'];
        });

        await cache.init();

        expect(fetcherCalls, 0,
            reason: 'Warm cache must not trigger a Firestore refresh.');
        expect(cache.isVerified(pubkeyA), isTrue);
        expect(cache.isVerified(pubkeyB), isTrue);
        expect(cache.isVerified('never-seen'), isFalse);
      },
    );

    test(
      'warm cache persists across two cache instances (simulating app '
      'restart)',
      () async {
        final fetchedAt = DateTime.now().toUtc();
        SharedPreferences.setMockInitialValues(<String, Object>{
          kVerifiedOrgsCacheKey: jsonEncode({
            'fetchedAt': fetchedAt.toIso8601String(),
            'pubkeys': <String>[pubkeyA],
          }),
        });

        // First "session": fetcher is NOT called, cache is used.
        final first = VerifiedOrgsCache.withFetcher(() async => <String>[]);
        await first.init();
        expect(first.isVerified(pubkeyA), isTrue);

        // Second "session": new instance, same backing prefs.
        final second = VerifiedOrgsCache.withFetcher(() async {
          throw StateError('Network is offline');
        });
        await second.init();
        expect(second.isVerified(pubkeyA), isTrue);
      },
    );
  });

  group('VerifiedOrgsCache — cache miss with refresh (online)', () {
    test(
      'cold cache pulls from Firestore and isVerified returns true after '
      'refresh',
      () async {
        // Empty SharedPreferences: no cached value present.
        SharedPreferences.setMockInitialValues(<String, Object>{});

        final cache = VerifiedOrgsCache.withFetcher(
          () async => <String>[pubkeyA, pubkeyB],
        );

        // Before init, the in-memory set is empty.
        expect(cache.isVerified(pubkeyA), isFalse,
            reason: 'Cold cache must report no verified orgs before init.');

        await cache.init();

        expect(cache.isVerified(pubkeyA), isTrue);
        expect(cache.isVerified(pubkeyB), isTrue);

        // The cache must also have been persisted so the next launch can
        // warm-start.
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(kVerifiedOrgsCacheKey);
        expect(raw, isNotNull,
            reason: 'Refresh must persist the cache to shared_preferences.');
        final decoded = jsonDecode(raw!) as Map<String, dynamic>;
        expect(decoded['pubkeys'], equals(<String>[pubkeyA, pubkeyB]));
      },
    );

    test(
      'stale cache (>24h old) triggers a refresh',
      () async {
        // Seed prefs with a cache fetched 25 hours ago — definitely stale.
        final fetchedAt = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 25));
        SharedPreferences.setMockInitialValues(<String, Object>{
          kVerifiedOrgsCacheKey: jsonEncode({
            'fetchedAt': fetchedAt.toIso8601String(),
            'pubkeys': <String>['old-key'],
          }),
        });

        var fetcherCalls = 0;
        final cache = VerifiedOrgsCache.withFetcher(() async {
          fetcherCalls += 1;
          return <String>[pubkeyA];
        });

        await cache.init();

        expect(fetcherCalls, 1, reason: 'Stale cache must trigger refresh.');
        // The stale key must be gone; the freshly-fetched key is in.
        expect(cache.isVerified('old-key'), isFalse);
        expect(cache.isVerified(pubkeyA), isTrue);
      },
    );

    test(
      'empty Firestore collection → cache becomes empty set, no error',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});

        final cache = VerifiedOrgsCache.withFetcher(
          () async => <String>[],
        );

        await cache.init();

        expect(cache.isVerified(pubkeyA), isFalse);
        expect(cache.isVerified('any-key'), isFalse);
      },
    );
  });

  group('VerifiedOrgsCache — cache miss with no refresh (offline)', () {
    test(
      'cold cache + unreachable Firestore → init() does NOT throw, '
      'isVerified returns false',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});

        final cache = VerifiedOrgsCache.withFetcher(() async {
          throw Exception('Network unreachable');
        });

        // The acceptance criterion is explicit: do NOT crash the app when
        // Firestore is unreachable.
        await expectLater(cache.init(), completes);

        expect(cache.isVerified(pubkeyA), isFalse);
        expect(cache.isVerified('anything'), isFalse);
      },
    );

    test(
      'stale cache + unreachable Firestore → init() does NOT throw, the '
      'stale cache is preserved (graceful degradation)',
      () async {
        final fetchedAt = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 25));
        SharedPreferences.setMockInitialValues(<String, Object>{
          kVerifiedOrgsCacheKey: jsonEncode({
            'fetchedAt': fetchedAt.toIso8601String(),
            'pubkeys': <String>[pubkeyA],
          }),
        });

        final cache = VerifiedOrgsCache.withFetcher(() async {
          throw Exception('Network unreachable');
        });

        await expectLater(cache.init(), completes);

        // Even though we couldn't refresh, the previously-cached key must
        // still verify — that's the whole point of the offline-first
        // design. The stale entry is preferable to no entry at all.
        expect(cache.isVerified(pubkeyA), isTrue,
            reason: 'Stale-but-present cache must still verify while offline.');
      },
    );
  });

  group('VerifiedOrgsCache — refresh() explicit', () {
    test(
      'refresh() overwrites the cache with whatever Firestore returns',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});

        // Mutable backing for the fetcher so we can simulate Firestore
        // returning different lists on different calls.
        var nextResult = <String>[pubkeyA];
        final cache = VerifiedOrgsCache.withFetcher(() async => nextResult);
        await cache.init();
        expect(cache.isVerified(pubkeyA), isTrue);

        // Pretend Firestore was updated to remove org A and add org B.
        nextResult = <String>[pubkeyB];
        await cache.refresh();

        expect(cache.isVerified(pubkeyA), isFalse);
        expect(cache.isVerified(pubkeyB), isTrue);
      },
    );
  });
}
