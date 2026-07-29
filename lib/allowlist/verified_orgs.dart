// RelayLink — Ticket #35 verified-orgs allowlist.
//
// Locally bundled allowlist of trusted aid organizations whose Ed25519
// public keys can sign authentic ALERT messages. The list is loaded from
// `assets/verified_orgs.json` at startup so the receiver can verify
// signatures offline — without depending on a live Firestore read.
//
// IMPORTANT: this is a manually curated demo allowlist. It is NOT a
// production trust authority. The README has the consumer-facing
// disclosure. Every entry MUST carry `demo: true` so we cannot silently
// promote a real org to verified status.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart' show rootBundle;

const String _kAssetPath = 'assets/verified_orgs.json';

/// One entry in the verified-orgs allowlist.
class VerifiedOrg {
  /// Stable id (slug). Used as the key in the lookup map.
  final String orgId;

  /// Human-readable display name (e.g. "Demo Red Crescent Branch").
  final String name;

  /// Base64-encoded Ed25519 public key (32 decoded bytes).
  final String publicKey;

  /// When this entry was added to the local allowlist (UTC).
  final DateTime addedAt;

  /// Whether this is a demo-only entry. The receiver-side API refuses
  /// non-demo entries — production trust authority is out of scope.
  final bool demo;

  const VerifiedOrg({
    required this.orgId,
    required this.name,
    required this.publicKey,
    required this.addedAt,
    required this.demo,
  });

  /// Parses one entry from the asset JSON shape.
  /// Asset shape (per Ticket #35):
  /// ```
  /// {
  ///   'org_id': 'demo_red_crescent',
  ///   'name': 'Demo Red Crescent Branch',
  ///   'public_key': '<base64>',
  ///   'added_at': '<ISO-8601>',
  ///   'demo': true,
  /// }
  /// ```
  factory VerifiedOrg.fromJson(Map<String, dynamic> json) {
    final orgId = json['org_id'] as String;
    final name = json['name'] as String;
    final publicKey = json['public_key'] as String;
    final addedAtRaw = json['added_at'] as String;
    final demo = json['demo'] as bool;
    if (!demo) {
      throw FormatException(
        'VerifiedOrg "$orgId" is not demo-flagged; production trust '
        'authority is out of scope for this demo allowlist.',
      );
    }
    return VerifiedOrg(
      orgId: orgId,
      name: name,
      publicKey: publicKey,
      addedAt: DateTime.parse(addedAtRaw),
      demo: demo,
    );
  }

  /// Serialize back to the asset JSON shape. Used by the seed script and
  /// for round-trip tests.
  Map<String, dynamic> toJson() => {
    'org_id': orgId,
    'name': name,
    'public_key': publicKey,
    'added_at': addedAt.toUtc().toIso8601String(),
    'demo': demo,
  };
}

/// In-memory allowlist of verified organizations. Construct via
/// [VerifiedOrgsAllowlist.fromList] for tests, or via
/// [VerifiedOrgsAllowlist.load] to read from the bundled asset.
class VerifiedOrgsAllowlist {
  final Map<String, VerifiedOrg> _byId;

  VerifiedOrgsAllowlist._(this._byId);

  /// Build from an in-memory list (test-friendly).
  factory VerifiedOrgsAllowlist.fromList(List<VerifiedOrg> orgs) {
    final map = <String, VerifiedOrg>{};
    for (final org in orgs) {
      map[org.orgId] = org;
    }
    return VerifiedOrgsAllowlist._(map);
  }

  /// Load the allowlist from the bundled asset. Throws [FormatException]
  /// if the asset is missing or contains a non-demo entry.
  static Future<VerifiedOrgsAllowlist> load() async {
    final raw = await rootBundle.loadString(_kAssetPath);
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    final orgs = list.map(VerifiedOrg.fromJson).toList();
    return VerifiedOrgsAllowlist.fromList(orgs);
  }

  /// All entries, in document order.
  List<VerifiedOrg> get all => _byId.values.toList(growable: false);

  /// Look up an org by id. Returns null if the org is not on the list.
  VerifiedOrg? find(String orgId) => _byId[orgId];

  /// Verify an ALERT signature against the org's public key. Returns
  /// false on any failure (unknown org, malformed key, bad signature) and
  /// never throws.
  Future<bool> verify(
    String orgId,
    List<int> signature,
    List<int> message,
  ) async {
    final org = _byId[orgId];
    if (org == null) return false;
    try {
      final pubBytes = base64Decode(org.publicKey);
      if (pubBytes.length != 32) return false;
      final ed = Ed25519();
      final pk = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
      final sig = Signature(signature, publicKey: pk);
      return await ed.verify(message, signature: sig);
    } catch (_) {
      return false;
    }
  }
}
