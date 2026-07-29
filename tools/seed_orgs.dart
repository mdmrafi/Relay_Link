// RelayLink — Ticket #35 seeder for `verified_orgs` (offline allowlist).
//
// What this script does
// ---------------------
// Generates 2-3 demo entries for the ALERT-verification allowlist and
// writes them to `assets/verified_orgs.json`, which the app bundles and
// reads at startup via `VerifiedOrgsAllowlist.load()`. The receiver can
// therefore verify signatures **offline** without depending on Firestore.
//
// Why not write directly to Firestore?
// ------------------------------------
// Ticket #35's spec explicitly allows either Firestore seeding or a local
// JSON asset. We chose the local asset because:
//   1. It is reproducible without a Firebase Admin SDK or service-account
//      credentials — important for offline development and CI.
//   2. The receiver-side check (Ticket #36) reads from the same JSON
//      whether the source is "asset" or "synced Firestore doc" — the wire
//      shape is identical.
//
// What it generates
// -----------------
// Three demo orgs, each with:
//   * a fresh Ed25519 keypair generated via the `cryptography` package
//   * a clearly demo-flagged name ("Demo ... Branch")
//   * `demo: true` in the JSON
//   * `added_at` = current UTC timestamp
//
// The script also prints the **private seed** for each org to stdout —
// this is intentional for the demo (so reviewers can manually sign a test
// ALERT and feed it through the verifier). The seeds MUST NOT be checked
// in or used outside the demo; they are documented as throwaway in the
// README. Production trust authority is out of scope for this repo.
//
// Run with:  dart run tools/seed_orgs.dart

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// Demo allowlist entries. Each tuple is (org_id, display_name).
/// Keys are generated fresh on every run — see file header.
const List<(String, String)> _demoOrgs = [
  ('demo_red_crescent', 'Demo Red Crescent Branch'),
  ('demo_community_net', 'Demo Community Mesh Network'),
  ('demo_climate_watch', 'Demo Climate Watch Coalition'),
];

Future<void> main() async {
  final ed = Ed25519();
  final now = DateTime.now().toUtc();
  final entries = <Map<String, dynamic>>[];
  final privateKeys = <Map<String, String>>[];

  for (final (orgId, name) in _demoOrgs) {
    final kp = await ed.newKeyPair();
    final pub = await kp.extractPublicKey();
    final seed = await kp.extract();
    final pubB64 = base64Encode(pub.bytes);
    final seedB64 = base64Encode(seed.bytes);

    entries.add({
      'org_id': orgId,
      'name': name,
      'public_key': pubB64,
      'added_at': now.toIso8601String(),
      'demo': true,
    });
    privateKeys.add({
      'org_id': orgId,
      'seed_b64': seedB64,
      'public_key_b64': pubB64,
    });
  }

  // Pretty-print the JSON with 2-space indent so diffs stay readable.
  final encoded = const JsonEncoder.withIndent('  ').convert(entries);
  const assetPath = 'assets/verified_orgs.json';
  await File(assetPath).writeAsString('$encoded\n');
  stdout.writeln('Wrote ${entries.length} demo entries to $assetPath');

  // Echo the public keys (committed) and seeds (printed for the demo only).
  stdout.writeln('');
  stdout.writeln('Public keys (committed):');
  for (final e in entries) {
    stdout.writeln('  ${e['org_id']}  ${e['public_key']}');
  }
  stdout.writeln('');
  stdout.writeln('Private seeds (DEMO ONLY — do NOT commit or use in prod):');
  for (final pk in privateKeys) {
    stdout.writeln('  ${pk['org_id']}  ${pk['seed_b64']}');
  }
}
