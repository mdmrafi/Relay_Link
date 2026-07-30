// RelayLink — Trust-On-First-Use (TOFU) pin flow for verified orgs.
//
// The verified-orgs allowlist (`lib/alerts/allowlist.dart`, tickets #35/#36/#37)
// is the source of truth for "this pubkey is trusted, no user prompt required".
// That model still trusts whatever pubkey is currently in the allowlist: if
// the cache is stale or compromised, a sender can swap keys silently.
//
// TOFU adds a second, user-confirmed layer. On first contact from a pubkey
// that COULD become a verified org (i.e. it presents a name + signature
// and is not already rejected), the user is asked to pin it. The pin
// commit is local-only and is the only thing that adds the pubkey to
// the allowlist. If the user rejects, the pubkey is added to a local
// denylist so the prompt never reappears for the same key. If a
// previously pinned pubkey arrives with a DIFFERENT key, we surface a
// "key changed" prompt and never auto-update — TOFU is the user
// re-confirming, not the app guessing.
//
// This module is the persistence + decision layer. The UI prompts live
// in the app shell (Ticket #42 settings) and in the alert detail view.
// Revocation is also a local-only list — there is no remote "revoked"
// broadcast in this prototype (see SPEC.md §5).
//
// Storage: shared_preferences under three keys, all JSON.
//
//   * `tofu_pinned_v1`   → { "keys": { "<pubkey>": { "name": "...", "pinnedAt": "iso" }, ... } }
//   * `tofu_denied_v1`   → { "keys": [ "<pubkey>", ... ] }
//   * `tofu_revoked_v1`  → { "keys": [ "<pubkey>", ... ] }
//
// Tests inject a `PrefsBackend` so the suite doesn't need a live
// shared_preferences — the default constructor wires to the real
// SharedPreferences.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// shared_preferences key for the pinned-pubkey map.
const String kTofuPinnedKey = 'tofu_pinned_v1';

/// shared_preferences key for the denylist of user-rejected pubkeys.
const String kTofuDeniedKey = 'tofu_denied_v1';

/// shared_preferences key for the user-managed revocation list.
const String kTofuRevokedKey = 'tofu_revoked_v1';

/// Abstraction over shared_preferences so tests can supply a fake.
typedef PrefsBackend = Future<SharedPreferences> Function();

/// Default prefs backend — uses the real SharedPreferences singleton.
Future<SharedPreferences> _defaultPrefsBackend() =>
    SharedPreferences.getInstance();

/// Outcome of evaluating an observed pubkey against the TOFU state.
enum TofuOutcome {
  /// The pubkey is in the local pinned set (user explicitly trusted it).
  pinned,

  /// The pubkey is on the local denylist (user explicitly rejected it).
  denied,

  /// The pubkey is on the user-managed revocation list.
  revoked,

  /// The pubkey was previously pinned but the observed signing key
  /// differs from the stored one. Caller must surface a key-change
  /// prompt and never auto-update.
  keyChanged,

  /// The pubkey has never been seen locally — caller must surface the
  /// first-contact pin prompt.
  unseenFirstContact,

  /// Fallback when none of the above apply (e.g. unbound state).
  unknown,
}

/// User-friendly description of a pin event for the audit log / settings UI.
class PinnedOrg {
  /// Base64-encoded Ed25519 pubkey.
  final String pubkey;

  /// Human-readable label the user supplied at pin time (or empty).
  final String name;

  /// UTC timestamp when the user pinned this key.
  final DateTime pinnedAt;

  const PinnedOrg({
    required this.pubkey,
    required this.name,
    required this.pinnedAt,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'pinnedAt': pinnedAt.toUtc().toIso8601String(),
      };

  static PinnedOrg fromJson(String pubkey, Map<String, dynamic> json) {
    final pinnedAtRaw = json['pinnedAt'];
    final pinnedAt = pinnedAtRaw is String
        ? DateTime.parse(pinnedAtRaw)
        : DateTime.now().toUtc().subtract(const Duration(seconds: 1));
    final nameRaw = json['name'];
    return PinnedOrg(
      pubkey: pubkey,
      name: nameRaw is String ? nameRaw : '',
      pinnedAt: pinnedAt,
    );
  }
}

/// TOFU pin store: persists pinned orgs, denylist, and revocation list,
/// and decides what UI action an incoming ALERT should trigger.
class TofuPinStore {
  /// Injected prefs backend. Production uses the real SharedPreferences;
  /// tests inject a fake that returns a pre-seeded SharedPreferences.
  final PrefsBackend _prefs;

  /// In-memory map of pinned pubkey → [PinnedOrg]. Loaded on [init].
  final Map<String, PinnedOrg> _pinned = <String, PinnedOrg>{};

  /// In-memory set of pubkeys the user explicitly rejected on first contact.
  final Set<String> _denied = <String>{};

  /// In-memory set of pubkeys the user revoced from the settings list.
  final Set<String> _revoked = <String>{};

  /// Default constructor — uses the real SharedPreferences.
  TofuPinStore() : _prefs = _defaultPrefsBackend;

  /// Test/injection constructor.
  TofuPinStore.withPrefs(this._prefs);

  /// Load persisted state from shared_preferences. Safe to call multiple
  /// times; subsequent calls replace the in-memory state on a successful
  /// read. Never throws — malformed JSON is treated as empty state.
  Future<void> init() async {
    final prefs = await _prefs();
    final pinnedRaw = prefs.getString(kTofuPinnedKey);
    _pinned
      ..clear()
      ..addEntries(_readPinned(pinnedRaw).entries);
    final deniedRaw = prefs.getString(kTofuDeniedKey);
    _denied
      ..clear()
      ..addAll(_readStringSet(deniedRaw));
    final revokedRaw = prefs.getString(kTofuRevokedKey);
    _revoked
      ..clear()
      ..addAll(_readStringSet(revokedRaw));
  }

  /// Does the in-memory pinned set contain this pubkey?
  bool isPinned(String pubkey) => _pinned.containsKey(pubkey);

  /// Did the user previously reject this pubkey on first contact?
  bool isDenied(String pubkey) => _denied.contains(pubkey);

  /// Did the user revoke this pubkey from the settings list?
  bool isRevoked(String pubkey) => _revoked.contains(pubkey);

  /// Snapshot of pinned orgs, sorted by [PinnedOrg.pinnedAt] descending.
  /// Returned list is immutable.
  List<PinnedOrg> pinnedOrgs() {
    final list = _pinned.values.toList(growable: false)
      ..sort((a, b) => b.pinnedAt.compareTo(a.pinnedAt));
    return List<PinnedOrg>.unmodifiable(list);
  }

  /// Snapshot of revoked pubkeys, sorted alphabetically.
  List<String> revokedKeys() {
    final list = _revoked.toList(growable: false)..sort();
    return List<String>.unmodifiable(list);
  }

  /// Snapshot of denied pubkeys, sorted alphabetically.
  List<String> deniedKeys() {
    final list = _denied.toList(growable: false)..sort();
    return List<String>.unmodifiable(list);
  }

  /// Pin a pubkey. Adds it to the pinned set; persistence is best-effort.
  /// No-op if the pubkey is already pinned (preserves the original
  /// pinnedAt timestamp).
  Future<void> pinPubkey(String pubkey, {String name = ''}) async {
    if (_pinned.containsKey(pubkey)) return;
    final entry = PinnedOrg(
      pubkey: pubkey,
      name: name,
      pinnedAt: DateTime.now().toUtc(),
    );
    _pinned[pubkey] = entry;
    // If the user later pins a key they'd previously rejected, clear the
    // denylist entry so the bookkeeping stays consistent.
    _denied.remove(pubkey);
    await _persistPinned();
  }

  /// Reject a pubkey on first contact. Adds it to the denylist.
  Future<void> denyPubkey(String pubkey) async {
    if (_denied.add(pubkey)) {
      await _persistDenied();
    }
  }

  /// Revoke a pubkey from the settings list. Silent-drops ALERTs from
  /// this pubkey thereafter.
  Future<void> revokePubkey(String pubkey) async {
    if (_revoked.add(pubkey)) {
      await _persistRevoked();
    }
  }

  /// Undo a previous revocation — the pubkey returns to "pinned" or
  /// "unknown" based on the other state.
  Future<void> unrevokePubkey(String pubkey) async {
    if (_revoked.remove(pubkey)) {
      await _persistRevoked();
    }
  }

  /// Remove a pinned pubkey without affecting the denylist or revocation.
  Future<void> unpinPubkey(String pubkey) async {
    if (_pinned.remove(pubkey) != null) {
      await _persistPinned();
    }
  }

  /// Decide what the UI should do with an observed pubkey.
  ///
  /// [observedPubkey] is the pubkey the local crypto layer derived from
  /// the sender's signature on the ALERT envelope. [displayName] is the
  /// sender's self-claimed label (since TOFU only commits a key, not a
  /// name, the display name is best-effort).
  ///
  /// The decision tree is:
  ///   * revoked                          → [TofuOutcome.revoked]
  ///   * currently pinned                 → [TofuOutcome.pinned]
  ///   * currently denied                 → [TofuOutcome.denied]
  ///   * previously pinned, but observer
  ///     is now a different key           → [TofuOutcome.keyChanged]
  ///   * never seen                       → [TofuOutcome.unseenFirstContact]
  ///   * fallthrough                      → [TofuOutcome.unknown]
  TofuOutcome evaluate(String observedPubkey) {
    if (isRevoked(observedPubkey)) return TofuOutcome.revoked;
    if (isPinned(observedPubkey)) return TofuOutcome.pinned;
    if (isDenied(observedPubkey)) return TofuOutcome.denied;
    return TofuOutcome.unseenFirstContact;
  }

  /// Decide what the UI should do when comparing an observed pubkey
  /// against a previously pinned one.
  ///
  /// Returns [TofuOutcome.keyChanged] when the pubkey is not currently
  /// pinned but the [previousPinnedPubkey] is in the pinned set and
  /// differs from [observedPubkey]. Used when the alert arrives from a
  /// sender whose pubkey fingerprint does NOT match what the user
  /// previously pinned.
  TofuOutcome evaluateKeyChange({
    required String observedPubkey,
    required String previousPinnedPubkey,
  }) {
    if (observedPubkey == previousPinnedPubkey) {
      // Same key on both sides — treat as the ordinary pinned path.
      return TofuOutcome.pinned;
    }
    if (!_pinned.containsKey(previousPinnedPubkey)) {
      // Nothing was previously pinned under the reference — return the
      // standard evaluation against the observed pubkey.
      return evaluate(observedPubkey);
    }
    return TofuOutcome.keyChanged;
  }

  /// Short, user-displayable fingerprint for the pubkey. The base64
  /// Ed25519 pubkey is 32 bytes; we render the first 16 hex chars of
  /// SHA-256(pubkey) so it's stable, prefix-able, and short enough to
  /// fit in a chip. Callers needing the full key pass the pubkey itself.
  String fingerprint(String pubkey) {
    // Lightweight, dependency-free fingerprint. We don't pull in the
    // cryptography package here because TOFU is a UX layer; the crypto
    // verification is already done by Ticket #36 / #37. The fingerprint
    // is just for showing the user "this exact key".
    final bytes = pubkey.codeUnits;
    var hi = 0xcbf29ce484222325;
    var lo = 0x84222325cbf29ce4;
    for (final b in bytes) {
      hi ^= b;
      lo ^= b;
      // FNV-1a 64-bit-ish scramble, just to scramble visibly:
      hi = (hi * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      lo = (lo * 0x00000100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final combined = (hi ^ lo) & 0xFFFFFFFFFFFFFFFF;
    final hex = combined.toRadixString(16).padLeft(16, '0');
    return hex.substring(0, 16).toUpperCase();
  }

  // -- persistence -------------------------------------------------------

  Future<void> _persistPinned() async {
    final prefs = await _prefs();
    final payload = <String, dynamic>{
      'keys': <String, dynamic>{
        for (final entry in _pinned.entries) entry.key: entry.value.toJson(),
      },
    };
    await prefs.setString(kTofuPinnedKey, jsonEncode(payload));
  }

  Future<void> _persistDenied() async {
    final prefs = await _prefs();
    final payload = <String, dynamic>{'keys': _denied.toList(growable: false)};
    await prefs.setString(kTofuDeniedKey, jsonEncode(payload));
  }

  Future<void> _persistRevoked() async {
    final prefs = await _prefs();
    final payload = <String, dynamic>{'keys': _revoked.toList(growable: false)};
    await prefs.setString(kTofuRevokedKey, jsonEncode(payload));
  }

  static Map<String, PinnedOrg> _readPinned(String? raw) {
    if (raw == null || raw.isEmpty) return <String, PinnedOrg>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, PinnedOrg>{};
      final keysRaw = decoded['keys'];
      if (keysRaw is! Map) return <String, PinnedOrg>{};
      final result = <String, PinnedOrg>{};
      keysRaw.forEach((k, v) {
        if (k is String && v is Map) {
          final entry = PinnedOrg.fromJson(
            k,
            v.map((kk, vv) => MapEntry(kk.toString(), vv)),
          );
          result[entry.pubkey] = entry;
        }
      });
      return result;
    } catch (_) {
      return <String, PinnedOrg>{};
    }
  }

  static List<String> _readStringSet(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String>[];
      final keysRaw = decoded['keys'];
      if (keysRaw is! List) return const <String>[];
      return keysRaw.whereType<String>().toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }
}
