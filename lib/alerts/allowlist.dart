// RelayLink — Ticket #36 allowlist sync + local cache.
//
// The demo allowlist (`lib/allowlist/verified_orgs.dart`) is bundled with
// the app at build time so the receiver can verify signatures offline. In
// addition, the app opportunistically pulls a fresh `verified_orgs`
// collection from Firestore whenever it can and persists the result in
// shared_preferences. This module is the sync/cache layer.
//
// The cache lives in shared_preferences under `verified_orgs_cache_v1` as
// a JSON object: { "fetchedAt": "<iso8601>", "pubkeys": ["<b64>", ...] }.
// The 24-hour invalidation is a simple timestamp comparison: if
// `now - fetchedAt > 24h`, refresh on the next init/refresh.
//
// Tests inject a `FetchVerifiedOrgsFn` so the suite doesn't need a live
// Firestore. The default constructor uses the real `FirebaseBackend`.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../backend/firebase.dart';
import '../backend/schemas.dart' show VerifiedOrgDoc;

/// shared_preferences key for the cached allowlist payload.
const String kVerifiedOrgsCacheKey = 'verified_orgs_cache_v1';

/// Cache TTL: refresh if the cached payload is older than this.
const Duration _kCacheTtl = Duration(hours: 24);

/// Function signature for a Firestore fetch: returns the list of public
/// keys (base64-encoded Ed25519, per `VerifiedOrgDoc.publicKeyB64`) for
/// the verified orgs. Tests inject a fake; the production code uses a
/// fetcher that hits `verified_orgs` via `FirebaseBackend.firestore`.
typedef FetchVerifiedOrgsFn = Future<List<String>> Function();

/// Sync + cache layer for the verified-orgs allowlist (Ticket #36).
///
/// The default constructor wires [VerifiedOrgsCache] to the real
/// `FirebaseBackend.firestore` collection. The named constructor
/// [VerifiedOrgsCache.withFetcher] takes a fetcher function so tests can
/// simulate online / offline / empty / malformed responses without a
/// real Firestore.
class VerifiedOrgsCache {
  /// Fetcher injected by the constructor. Production uses the real
  /// Firestore query; tests inject a fake.
  final FetchVerifiedOrgsFn _fetcher;

  /// In-memory set of verified public keys (base64-encoded Ed25519).
  /// Reads from `isVerified()` are O(1) against this set.
  final Set<String> _verified = <String>{};

  /// Default constructor — uses the real `FirebaseBackend.firestore`.
  /// MUST be called only after `FirebaseBackend.init()` has succeeded.
  /// If the real Firestore is unreachable, [init] silently no-ops; see
  /// the contract above.
  VerifiedOrgsCache() : _fetcher = _realFirestoreFetcher;

  /// Test/injection constructor: takes a fetcher function so suites can
  /// simulate empty / full / throwing backends without a real Firestore.
  VerifiedOrgsCache.withFetcher(this._fetcher);

  /// Sync lookup: does the in-memory set contain this public key?
  ///
  /// Safe to call before [init] — returns false if the cache is empty.
  /// [pubkey] is the base64-encoded Ed25519 public key, exactly as
  /// stored in `VerifiedOrgDoc.publicKeyB64`.
  bool isVerified(String pubkey) => _verified.contains(pubkey);

  /// Initialize the cache at app startup.
  ///
  /// Reads the persisted cache (if any), then refreshes from Firestore if
  /// the cache is missing or older than 24h. Never throws — Firestore
  /// failures are swallowed silently so the app stays usable offline.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = _readCache(prefs);
    if (cached != null) {
      _verified
        ..clear()
        ..addAll(cached.pubkeys);
    }
    final isStale = cached == null ||
        DateTime.now().toUtc().difference(cached.fetchedAt) > _kCacheTtl;
    if (isStale) {
      await refresh();
    }
  }

  /// Force a refresh from Firestore. Never throws. If the fetch fails,
  /// the in-memory set is left untouched (graceful degradation — a stale
  /// cache is preferable to losing the allowlist entirely).
  Future<void> refresh() async {
    try {
      final pubkeys = await _fetcher();
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'fetchedAt': DateTime.now().toUtc().toIso8601String(),
        'pubkeys': pubkeys,
      };
      await prefs.setString(kVerifiedOrgsCacheKey, jsonEncode(payload));
      _verified
        ..clear()
        ..addAll(pubkeys);
    } catch (_) {
      // Swallow: do NOT crash the app on a network failure. The
      // acceptance criterion is explicit — graceful degradation.
    }
  }

  /// Read the cache payload from shared_preferences. Returns null if the
  /// cache is missing or malformed (treated as a cold cache).
  static _CachePayload? _readCache(SharedPreferences prefs) {
    final raw = prefs.getString(kVerifiedOrgsCacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final fetchedAtRaw = decoded['fetchedAt'];
      final pubkeysRaw = decoded['pubkeys'];
      if (fetchedAtRaw is! String || pubkeysRaw is! List) return null;
      final fetchedAt = DateTime.parse(fetchedAtRaw);
      final pubkeys = pubkeysRaw
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      return _CachePayload(fetchedAt: fetchedAt, pubkeys: pubkeys);
    } catch (_) {
      // Malformed cache: treat as cold cache so init() repopulates it.
      return null;
    }
  }
}

class _CachePayload {
  final DateTime fetchedAt;
  final List<String> pubkeys;
  _CachePayload({required this.fetchedAt, required this.pubkeys});
}

/// Default fetcher used by the parameterless constructor. Reads every
/// document under `verified_orgs/` and returns the `public_key_b64` field
/// of each. Returns an empty list if Firestore is uninitialized or the
/// collection is empty.
Future<List<String>> _realFirestoreFetcher() async {
  if (!FirebaseBackend.isInitialized) {
    // Defensive: the default constructor is documented to require init
    // first, but never throw — return an empty set so init() still
    // caches the (empty) state and isVerified() returns false.
    return <String>[];
  }
  final query = FirebaseBackend.firestore
      .collection(FirebaseBackend.verifiedOrgsCollection);
  final snapshot = await query.get();
  final pubkeys = <String>[];
  for (final doc in snapshot.docs) {
    final data = doc.data();
    final pk = data[VerifiedOrgDoc.publicKeyB64];
    if (pk is String && pk.isNotEmpty) pubkeys.add(pk);
  }
  return pubkeys;
}
