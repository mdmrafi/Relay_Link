// RelayLink — TOFU pin-on-first-contact + revocation tests.
//
// These tests cover the externally observable behavior of TofuPinStore
// (lib/alerts/tofu.dart):
//
//   * Pin flow — first contact from an unknown pubkey → outcome is
//     unseenFirstContact; after pin, outcome becomes pinned.
//   * Reject flow — denylist survives across instances; a denied key is
//     never re-prompted.
//   * Key-change detection — pubkey previously pinned but arriving with a
//     different key surfaces keyChanged (never auto-update).
//   * Revocation list — user-managed, silent-drop semantics; flipping
//     revoked on/off changes outcomes.
//   * Persistence — pinned/denied/revoked state survives across
//     instances on the same SharedPreferences backing.
//
// We inject a PrefsBackend so the suite doesn't need a live
// SharedPreferences singleton; we seed initial values via
// SharedPreferences.setMockInitialValues the same way the allowlist tests
// do.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/alerts/tofu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Convenience: a fresh prefs fake that returns the singleton backed by
  /// the most-recently-set mock initial values.
  Future<SharedPreferences> prefsFake() async =>
      SharedPreferences.getInstance();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('TOFU — pin flow (first-contact)', () {
    test('first contact from unknown pubkey surfaces unseenFirstContact',
        () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';

      expect(store.evaluate(foreignKey), TofuOutcome.unseenFirstContact);
      expect(store.isPinned(foreignKey), isFalse);
      expect(store.isDenied(foreignKey), isFalse);
      expect(store.isRevoked(foreignKey), isFalse);
    });

    test(
        'pinning a previously-unseen key promotes it to pinned and survives '
        'across instances', () async {
      var store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      await store.pinPubkey(foreignKey, name: 'Coast Guard');

      expect(store.evaluate(foreignKey), TofuOutcome.pinned);
      expect(store.isPinned(foreignKey), isTrue);

      // Simulated restart: a fresh store reading the same SharedPreferences
      // backing must still see the pin.
      store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      expect(store.evaluate(foreignKey), TofuOutcome.pinned);
      final pinned = store.pinnedOrgs();
      expect(pinned, hasLength(1));
      expect(pinned.first.pubkey, foreignKey);
      expect(pinned.first.name, 'Coast Guard');
    });

    test(
        'pinning a key that is already pinned is a no-op (preserves '
        'original pinnedAt)', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      await store.pinPubkey(foreignKey, name: 'First');

      final first = store.pinnedOrgs().first;

      // Tiny delay to make a wall-clock difference possible — none should
      // appear because the second pin is a no-op.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.pinPubkey(foreignKey, name: 'Second');

      final pinned = store.pinnedOrgs();
      expect(pinned, hasLength(1));
      expect(pinned.first.pinnedAt, first.pinnedAt);
      expect(pinned.first.name, 'First');
    });

    test('denying a first-contact key adds to denylist and persists',
        () async {
      var store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';
      await store.denyPubkey(foreignKey);

      expect(store.evaluate(foreignKey), TofuOutcome.denied);
      expect(store.isDenied(foreignKey), isTrue);

      // Restart — denylist must persist.
      store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      expect(store.evaluate(foreignKey), TofuOutcome.denied);
      expect(store.deniedKeys(), contains(foreignKey));
    });

    test(
        'pinning after a previous denial removes the denylist entry (the '
        'user changed their mind)', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';
      await store.denyPubkey(foreignKey);
      expect(store.isDenied(foreignKey), isTrue);

      await store.pinPubkey(foreignKey, name: 'OK now');

      expect(store.isPinned(foreignKey), isTrue);
      expect(store.isDenied(foreignKey), isFalse);
      expect(store.evaluate(foreignKey), TofuOutcome.pinned);
    });

    test('unpinning returns a key to unseenFirstContact', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      await store.pinPubkey(foreignKey);
      expect(store.evaluate(foreignKey), TofuOutcome.pinned);

      await store.unpinPubkey(foreignKey);
      expect(store.evaluate(foreignKey), TofuOutcome.unseenFirstContact);
      expect(store.isPinned(foreignKey), isFalse);
    });
  });

  group('TOFU — key-change detection', () {
    test(
        'a pubkey previously pinned but arriving on a different key surfaces '
        'keyChanged, NEVER auto-updates', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      // Old pinned key.
      const oldKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      // New key claiming to be the same org.
      const newKey = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';

      await store.pinPubkey(oldKey, name: 'Red Cross');

      // First evaluation pass: the new key is not yet pinned. evaluate()
      // correctly returns unseenFirstContact for a raw key lookup. The
      // key-change check needs to be performed against the OLD key.
      expect(store.evaluate(newKey), TofuOutcome.unseenFirstContact);

      // The key-change comparator — used by the alert ingestion layer:
      // "I used to trust this org's key, but this incoming alert is
      // signed with a different key."
      final outcome = store.evaluateKeyChange(
        observedPubkey: newKey,
        previousPinnedPubkey: oldKey,
      );
      expect(outcome, TofuOutcome.keyChanged);

      // CRUCIAL: the new key must NOT have been auto-added to the pinned
      // set. The user has to confirm via pinPubkey() explicitly.
      expect(store.isPinned(newKey), isFalse,
          reason: 'TOFU must never auto-update; user must re-prompt.');
      expect(store.isPinned(oldKey), isTrue,
          reason: 'The originally-pinned key stays trusted until revoked.');

      // Confirming the new key adds it to the pinned set. The old key
      // remains pinned too (TOFU never auto-revokes a previously-pinned
      // key — the user manages revocation explicitly via the settings
      // screen). Both pins are now visible side-by-side.
      await store.pinPubkey(newKey, name: 'Red Cross');
      expect(store.isPinned(newKey), isTrue);
      expect(store.isPinned(oldKey), isTrue,
          reason: 'Old key stays pinned until the user explicitly revokes.');
    });

    test(
        'evaluateKeyChange with two equal pubkeys returns pinned (no false '
        'positive)', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const key = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      await store.pinPubkey(key);

      final outcome = store.evaluateKeyChange(
        observedPubkey: key,
        previousPinnedPubkey: key,
      );
      expect(outcome, TofuOutcome.pinned);
      expect(store.isPinned(key), isTrue);
    });

    test(
        'evaluateKeyChange with an unknown previousPin falls through to the '
        'ordinary evaluate() result', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const knownKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      const foreignKey = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';
      const unseenPrevious = 'QvLM7w0sQOjq+0XJTfX6m1aE1k2u8m9z3aB4c5d6e7f=';

      await store.pinPubkey(knownKey);

      // If the reference pubkey was never pinned, evaluateKeyChange
      // degrades to the standard first-contact check.
      final outcome = store.evaluateKeyChange(
        observedPubkey: foreignKey,
        previousPinnedPubkey: unseenPrevious,
      );
      expect(outcome, TofuOutcome.unseenFirstContact);
    });
  });

  group('TOFU — revocation list', () {
    test('revoking a pubkey surfaces revoked and silent-drops its ALERTs',
        () async {
      var store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      await store.pinPubkey(foreignKey);

      expect(store.evaluate(foreignKey), TofuOutcome.pinned);

      await store.revokePubkey(foreignKey);

      expect(store.evaluate(foreignKey), TofuOutcome.revoked);
      expect(store.isRevoked(foreignKey), isTrue);

      // Settings list reflects the revocation.
      expect(store.revokedKeys(), contains(foreignKey));

      // Restored across instances.
      store = TofuPinStore.withPrefs(prefsFake);
      await store.init();
      expect(store.evaluate(foreignKey), TofuOutcome.revoked);
    });

    test(
        'revocation takes precedence over pinned — once a key is revoked, '
        'it is revoked until unrevoked', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';
      await store.pinPubkey(foreignKey);
      await store.revokePubkey(foreignKey);

      // Revoked wins over pinned — caller's UI must silent-drop.
      expect(store.evaluate(foreignKey), TofuOutcome.revoked);

      await store.unrevokePubkey(foreignKey);
      expect(store.evaluate(foreignKey), TofuOutcome.pinned);
    });

    test('revocation is local-only and survives across instances',
        () async {
      var store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const foreignKey = 'QvLM7w0sQOjq+0XJTfX6m1aE1k2u8m9z3aB4c5d6e7f=';
      await store.revokePubkey(foreignKey);

      expect(store.isRevoked(foreignKey), isTrue);

      // Inspect what got persisted.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kTofuRevokedKey);
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['keys'], contains(foreignKey));

      // Fresh store reads from the same backing.
      store = TofuPinStore.withPrefs(prefsFake);
      await store.init();
      expect(store.isRevoked(foreignKey), isTrue);
    });
  });

  group('TOFU — misc helpers', () {
    test('fingerprint is stable for the same input and distinct across keys',
        () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const a = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      const b = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';

      final fa = store.fingerprint(a);
      final fb = store.fingerprint(b);

      expect(fa, equals(store.fingerprint(a)),
          reason: 'Fingerprint must be deterministic.');
      expect(fa, isNot(equals(fb)),
          reason: 'Distinct inputs must produce distinct fingerprints.');
      // 16 uppercase hex chars + at most 4 letter separators? No — keep
      // it strict: exactly 16 hex chars so the chip fits.
      expect(fa, hasLength(16));
      expect(fa, matches(RegExp(r'^[0-9A-F]{16}$')));
    });

    test(
        'malformed persistence payloads are tolerated (treated as empty '
        'state, no throw)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kTofuPinnedKey: 'not-json-at-all',
        kTofuDeniedKey: '{"unrelated": true}',
        kTofuRevokedKey: '[]',
      });

      final store = TofuPinStore.withPrefs(prefsFake);
      await expectLater(store.init(), completes);

      expect(store.pinnedOrgs(), isEmpty);
      expect(store.deniedKeys(), isEmpty);
      expect(store.revokedKeys(), isEmpty);
    });

    test(
        'pinnedOrgs returns the most-recently-pinned key first '
        '(sorted by pinnedAt desc)', () async {
      final store = TofuPinStore.withPrefs(prefsFake);
      await store.init();

      const a = '4tSoBcIYkxj6MgyPTp5WHu37liMhqaJEgUSZRbneZQw=';
      const b = 'MeEYMKF3hOu3Ud/skz//EHckjeDxdrGw77PL7D15UOg=';

      await store.pinPubkey(a);
      // Ensure the timestamp b > a. We deliberately drive wall-clock by
      // awaiting one millisecond between pins.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await store.pinPubkey(b);

      final pinned = store.pinnedOrgs();
      expect(pinned, hasLength(2));
      expect(pinned.first.pubkey, b);
      expect(pinned.last.pubkey, a);
    });
  });
}
