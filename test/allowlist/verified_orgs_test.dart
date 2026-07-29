// RelayLink — Ticket #35 allowlist tests.
//
// The asset bundle (`assets/verified_orgs.json`) holds demo organization
// entries — each with an Ed25519 public key that can verify ALERT messages
// at receive time. These tests exercise the full verification contract:
//   * The bundled asset round-trips through `VerifiedOrgsAllowlist.load()`.
//   * `verify(orgId, signature, message)` succeeds for a signature produced
//     with the matching test identity, and fails for unknown orgs / tampered
//     signatures / swapped public keys.
//   * Demo entries are clearly flagged (the README disclosure is enforced by
//     docs, but we also reject the loader if `demo` is missing or false —
//     non-demo entries in this demo allowlist would be a foot-gun).
//
// We seed the test identity at runtime via `cryptography` (not via the
// persisted `DeviceIdentity`) so the test does not depend on the device
// identity ticket or on platform secure storage.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/allowlist/verified_orgs.dart';

/// Helper: generate an Ed25519 keypair and return (privateKey, publicKeyB64).
Future<(SimpleKeyPairData, String)> _generateIdentity() async {
  final ed = Ed25519();
  final kp = await ed.newKeyPair();
  final seed = await kp.extract();
  final pub = await kp.extractPublicKey();
  final pubB64 = base64Encode(pub.bytes);
  return (seed, pubB64);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('asset bundle', () {
    test('assets/verified_orgs.json exists on disk and parses', () async {
      final file = File('assets/verified_orgs.json');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'Seed script must have produced assets/verified_orgs.json.',
      );
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as List<dynamic>;
      expect(decoded, isNotEmpty);

      // Each entry must carry every required field and be flagged as demo.
      for (final entry in decoded.cast<Map<String, dynamic>>()) {
        expect(entry['org_id'], isA<String>());
        expect(entry['name'], isA<String>());
        expect(entry['public_key'], isA<String>());
        expect(entry['added_at'], isA<String>());
        expect(
          entry['demo'],
          isTrue,
          reason: 'Non-demo entries would imply production trust.',
        );
      }
    });

    test('load() returns all bundled entries via rootBundle', () async {
      // Make the asset available to rootBundle — the test runner binds the
      // working directory by default, so the relative path resolves.
      final raw = await File('assets/verified_orgs.json').readAsString();
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (message) async {
            final key = utf8.decode((message as ByteData).buffer.asUint8List());
            if (key == 'assets/verified_orgs.json') {
              return ByteData.view(Uint8List.fromList(utf8.encode(raw)).buffer);
            }
            return null;
          });

      final orgs = await VerifiedOrgsAllowlist.load();
      expect(orgs.all, isNotEmpty);
      for (final org in orgs.all) {
        expect(org.orgId, isNotEmpty);
        expect(org.name, isNotEmpty);
        expect(org.publicKey, isNotEmpty);
        expect(org.demo, isTrue);
        expect(
          org.addedAt.isBefore(DateTime.now().add(const Duration(seconds: 1))),
          isTrue,
        );
      }
    });
  });

  group('VerifiedOrgsAllowlist.fromList / verify', () {
    test(
      'verifies a signature signed with the matching test identity',
      () async {
        final (seed, pubB64) = await _generateIdentity();
        final ed = Ed25519();
        final message = utf8.encode('ALERT: flood warning');
        final sig = await ed.sign(message, keyPair: seed);
        final orgs = VerifiedOrgsAllowlist.fromList([
          VerifiedOrg(
            orgId: 'demo_red_crescent',
            name: 'Demo Red Crescent Branch',
            publicKey: pubB64,
            addedAt: DateTime.utc(2026, 7, 30),
            demo: true,
          ),
        ]);

        final ok = await orgs.verify('demo_red_crescent', sig.bytes, message);
        expect(ok, isTrue);
      },
    );

    test('returns false for an unknown org id', () async {
      final (seed, pubB64) = await _generateIdentity();
      final ed = Ed25519();
      final message = utf8.encode('ALERT: flood warning');
      final sig = await ed.sign(message, keyPair: seed);
      final orgs = VerifiedOrgsAllowlist.fromList([
        VerifiedOrg(
          orgId: 'demo_red_crescent',
          name: 'Demo Red Crescent Branch',
          publicKey: pubB64,
          addedAt: DateTime.utc(2026, 7, 30),
          demo: true,
        ),
      ]);

      final ok = await orgs.verify('demo_unknown', sig.bytes, message);
      expect(ok, isFalse);
    });

    test('returns false when the message has been tampered with', () async {
      final (seed, pubB64) = await _generateIdentity();
      final ed = Ed25519();
      final sig = await ed.sign(utf8.encode('original message'), keyPair: seed);
      final orgs = VerifiedOrgsAllowlist.fromList([
        VerifiedOrg(
          orgId: 'demo_red_crescent',
          name: 'Demo Red Crescent Branch',
          publicKey: pubB64,
          addedAt: DateTime.utc(2026, 7, 30),
          demo: true,
        ),
      ]);

      final ok = await orgs.verify(
        'demo_red_crescent',
        sig.bytes,
        utf8.encode('tampered'),
      );
      expect(ok, isFalse);
    });

    test('returns false when the public key is malformed', () async {
      final (seed, _) = await _generateIdentity();
      final ed = Ed25519();
      final sig = await ed.sign(utf8.encode('hi'), keyPair: seed);
      final orgs = VerifiedOrgsAllowlist.fromList([
        VerifiedOrg(
          orgId: 'demo_bad',
          name: 'Demo Bad',
          publicKey: 'not-base64-at-all',
          addedAt: DateTime.utc(2026, 7, 30),
          demo: true,
        ),
      ]);

      final ok = await orgs.verify('demo_bad', sig.bytes, utf8.encode('hi'));
      expect(ok, isFalse);
    });

    test('lookup by org id returns null for unknown orgs', () {
      final orgs = VerifiedOrgsAllowlist.fromList([
        VerifiedOrg(
          orgId: 'demo_a',
          name: 'Demo A',
          publicKey: base64Encode(List<int>.filled(32, 0)),
          addedAt: DateTime.utc(2026, 7, 30),
          demo: true,
        ),
      ]);
      expect(orgs.find('demo_a'), isNotNull);
      expect(orgs.find('demo_b'), isNull);
    });
  });
}
