// RelayLink — Ticket #14 Forward-Secrecy Demo.
//
// This is a 30-second-clip-friendly demonstration of the HKDF-chain fallback
// used by `lib/crypto/direct.dart` (Ticket #13, per D5). It runs end-to-end
// in well under 10 seconds and prints copy-pasteable output suitable for
// recording a README demo.
//
// Why not DeviceIdentity?
// =======================
// lib/crypto/identity.dart pulls in flutter_secure_storage, which requires
// the Flutter runtime — that breaks `dart run tools/demo_forward_secrecy.dart`
// for a CI-friendly standalone script. To keep the demo runnable with plain
// `dart run`, we re-implement the X25519 ECDH step here using the
// `cryptography` package directly (the same package identity.dart uses
// internally). The bytes that come out are bit-for-bit the same as the ones
// DeviceIdentity.ecdh(...) would produce for the same keypair inputs.
//
// Narrative
// =========
// The DIRECT HKDF-chain derives every chain key as the HMAC of the previous
// one, so once a chain has been re-seeded with a fresh shared secret (the
// analogue of a Double-Ratchet DH step) the OLD chain is computationally
// unreachable from the NEW one. This demo walks through that property in a
// single 30-second clip:
//
//   1. Alice and Bob perform an X25519 ECDH to derive shared secret S1.
//   2. They open DIRECT sessions from S1. Alice encrypts the first K-1=9
//      messages on the S1 chain; Bob (with S1) successfully decrypts each
//      one (baseline).
//   3. COMPROMISE: an attacker captures the shared secret S1. They build a
//      fresh DIRECT session from S1, so they have a complete receiver chain
//      for the old (S1) traffic.
//   4. RE-SEED: Alice and Bob derive a fresh shared secret S2 (a new DH
//      step — the analogue of a Double-Ratchet DH ratchet), open new
//      DIRECT sessions from S2, and Alice continues encrypting messages
//      K..N=10..20 on the new S2 chain.
//   5. From the attacker's perspective (using only the captured S1):
//        * Pre-K messages (1..K-1), on the OLD S1 chain:
//          the attacker CAN read them. This is the unavoidable cost:
//          anything sent before the re-seed is forever reachable to anyone
//          who holds the old key.
//        * Post-K messages (K..N), on the NEW S2 chain:
//          the attacker CANNOT read them. **This is the forward-secrecy
//          property the demo is named for.** The re-seed cuts the old
//          key off from any future traffic.
//
// Output
// ======
// For each message index, the script prints:
//   - what the LEGITIMATE Bob decrypts (with a FRESH session built from
//     the appropriate shared secret — bobS1 for pre-K, bobS2 for post-K),
//   - what the ATTACKER (with the captured S1) gets.
//
// Run with:  dart run tools/demo_forward_secrecy.dart

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:relaylink/crypto/direct.dart';

const int _kTotalMessages = 20;
const int _kCompromiseAt = 10; // K = 10 — chain re-seed happens AFTER msg K-1.

String _hex(Uint8List bytes, {int max = 8}) {
  final n = bytes.length < max ? bytes.length : max;
  final hex = bytes
      .sublist(0, n)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join('');
  return '0x$hex${bytes.length > n ? '…' : ''}';
}

Future<String> _safeDecrypt(
  DirectSession session,
  Uint8List ciphertext,
  DirectRatchetHeader header,
) async {
  try {
    return await session.decrypt(ciphertext, header);
  } catch (e) {
    return '<DECRYPT FAILED: ${e.runtimeType}>';
  }
}

/// Perform an X25519 ECDH between two freshly generated keypairs and return
/// the 32-byte shared secret. Mirrors `DeviceIdentity.ecdh(...)` but stays
/// inside the standalone Dart runtime.
Future<Uint8List> _x25519Ecdh() async {
  final x = X25519();
  final a = await x.newKeyPair();
  final b = await x.newKeyPair();
  final aPub = await a.extractPublicKey();
  final bPub = await b.extractPublicKey();
  final s = await x.sharedSecretKey(
    keyPair: a,
    remotePublicKey: bPub,
  );
  // Cross-check: ECDH is symmetric, so doing it the other way should match.
  final s2 = await x.sharedSecretKey(
    keyPair: b,
    remotePublicKey: aPub,
  );
  final sBytes = Uint8List.fromList(await s.extractBytes());
  final s2Bytes = Uint8List.fromList(await s2.extractBytes());
  for (var i = 0; i < sBytes.length; i++) {
    if (sBytes[i] != s2Bytes[i]) {
      throw StateError('ECDH output mismatch — should be symmetric');
    }
  }
  return sBytes;
}

Future<void> main() async {
  print('================================================================');
  print('  RelayLink  ·  Forward-Secrecy Demo  ·  Ticket #14            ');
  print('  HKDF-chain fallback (lib/crypto/direct.dart, Ticket #13)     ');
  print('================================================================');
  print('');
  print('Scenario:');
  print('  • N = $_kTotalMessages messages total');
  print('  • K = $_kCompromiseAt — chain re-seeded AFTER message K-1');
  print('  • Attacker captures the OLD shared secret S1');
  print('  • Goal: show that post-K messages on the NEW chain are safe');
  print('    even though pre-K messages were readable to the attacker.');
  print('');

  // ------------------------------------------------------------------
  // Step 1: Establish the shared secrets via X25519 ECDH.
  // ------------------------------------------------------------------
  final sharedSecretS1 = await _x25519Ecdh();
  final sharedSecretS2 = await _x25519Ecdh();

  print('Step 1 — Establish session');
  print('  S1 (Alice ↔ Bob, X25519 ECDH)   = ${_hex(sharedSecretS1)}');
  print('  S2 (post-K re-seed, fresh ECDH) = ${_hex(sharedSecretS2)}');
  print('');

  // ------------------------------------------------------------------
  // Step 2: Alice encrypts pre-K messages on the S1 chain. Bob (with S1)
  // decrypts them all (baseline).
  // ------------------------------------------------------------------
  final aliceS1 = await DirectSession.create(sharedSecretS1, isInitiator: true);
  final bobS1Baseline = await DirectSession.create(sharedSecretS1, isInitiator: false);

  final preK = <DirectMessage>[];
  final plaintexts = <String>[];
  for (var i = 0; i < _kCompromiseAt - 1; i++) {
    final pt = 'ALICE → BOB  msg #${(i + 1).toString().padLeft(2, '0')}  ·PRE-K·S1';
    plaintexts.add(pt);
    preK.add(await aliceS1.encrypt(pt));
  }
  print('Step 2 — Encrypt pre-K messages (1..${_kCompromiseAt - 1}) on the S1 chain');
  for (var i = 0; i < preK.length; i++) {
    final got = await bobS1Baseline.decrypt(preK[i].ciphertext, preK[i].ratchetHeader);
    if (got != plaintexts[i]) {
      throw StateError('baseline pre-K decrypt mismatch at #$i');
    }
  }
  print('  Bob (with S1) decrypted all ${preK.length} pre-K messages ✓');
  print('');

  // ------------------------------------------------------------------
  // Step 3: COMPROMISE simulation at message K.
  // ------------------------------------------------------------------
  // The attacker captures the shared secret S1 (this is the analogue
  // of an ECDH private-key leak — strongest possible attacker, gives
  // the cleanest narrative).
  print('Step 3 — Compromise at message K=$_kCompromiseAt');
  print('  Attacker captured the shared secret S1 = ${_hex(sharedSecretS1)}');
  print('  Attacker bootstraps a fake-Bob session from S1.');
  print('');

  final attackerWithS1 = await DirectSession.create(sharedSecretS1, isInitiator: false);

  // ------------------------------------------------------------------
  // Step 4: Re-seed the chain. Alice and Bob both abandon S1 and start
  // fresh from S2 (the analogue of a Double-Ratchet DH step).
  // ------------------------------------------------------------------
  final aliceS2 = await DirectSession.create(sharedSecretS2, isInitiator: true);
  final bobS2Baseline = await DirectSession.create(sharedSecretS2, isInitiator: false);

  final postK = <DirectMessage>[];
  for (var i = _kCompromiseAt - 1; i < _kTotalMessages; i++) {
    final pt = 'ALICE → BOB  msg #${(i + 1).toString().padLeft(2, '0')}  ·POST-K·S2';
    plaintexts.add(pt);
    postK.add(await aliceS2.encrypt(pt));
  }
  print('Step 4 — Re-seed: Alice & Bob migrate to S2');
  for (var i = 0; i < postK.length; i++) {
    final got = await bobS2Baseline.decrypt(postK[i].ciphertext, postK[i].ratchetHeader);
    if (got != plaintexts[_kCompromiseAt - 1 + i]) {
      throw StateError('baseline post-K decrypt mismatch at #${_kCompromiseAt + i}');
    }
  }
  print('  Alice encrypts messages $_kCompromiseAt..$_kTotalMessages on the S2 chain');
  print('  Bob (with S2) decrypted all ${postK.length} post-K messages ✓');
  print('');

  // ------------------------------------------------------------------
  // Step 5: Demonstrate the property using FRESH Bob sessions for the
  // table. We need fresh sessions because the baseline test above has
  // already advanced the chain counters in bobS1Baseline and
  // bobS2Baseline.
  // ------------------------------------------------------------------
  print('================================================================');
  print('  Results  ·  legitimate Bob  vs.  attacker (captured S1)      ');
  print('================================================================');
  print('');
  print('  idx │ Bob (legit, current)         │ Attacker (captured S1)  ');
  print('  ────┼─────────────────────────────┼────────────────────────');

  var bobCleanPreK = 0;
  var bobCleanPostK = 0;
  var attackerCleanPreK = 0;
  var attackerFailedPostK = 0;

  final bobFreshS1 = await DirectSession.create(sharedSecretS1, isInitiator: false);
  final bobFreshS2 = await DirectSession.create(sharedSecretS2, isInitiator: false);

  for (var i = 0; i < _kTotalMessages; i++) {
    final idx = i;
    final isPostK = idx >= _kCompromiseAt - 1;
    final msgIndex1Based = idx + 1;

    final DirectMessage dm;
    final String pt;
    final DirectSession bobSession;
    if (isPostK) {
      dm = postK[idx - (_kCompromiseAt - 1)];
      pt = plaintexts[idx];
      bobSession = bobFreshS2;
    } else {
      dm = preK[idx];
      pt = plaintexts[idx];
      bobSession = bobFreshS1;
    }

    // The legitimate Bob uses his appropriate session (S1 or S2).
    final bobView = await _safeDecrypt(bobSession, dm.ciphertext, dm.ratchetHeader);

    // The attacker uses ONE session bootstrapped from the captured S1.
    final atkView = await _safeDecrypt(attackerWithS1, dm.ciphertext, dm.ratchetHeader);

    if (!isPostK && bobView == pt) bobCleanPreK++;
    if (isPostK && bobView == pt) bobCleanPostK++;
    if (!isPostK && atkView == pt) attackerCleanPreK++;
    if (isPostK && atkView.startsWith('<DECRYPT FAILED')) attackerFailedPostK++;

    final bobCell = bobView.length > 27 ? '${bobView.substring(0, 27)}…' : bobView;
    final atkCell = atkView.length > 24 ? '${atkView.substring(0, 24)}…' : atkView;
    print(
      '  ${msgIndex1Based.toString().padLeft(2, '0')}  │ ${bobCell.padRight(27)} │ '
      '${atkCell.padRight(24)} │',
    );
  }
  print('  ────┴─────────────────────────────┴────────────────────────');
  print('');

  // ------------------------------------------------------------------
  // Summary
  // ------------------------------------------------------------------
  final preKCount = _kCompromiseAt - 1;
  final postKCount = _kTotalMessages - (_kCompromiseAt - 1);

  print('================================================================');
  print('  Summary                                                         ');
  print('================================================================');
  print('  Compromised message K             = $_kCompromiseAt');
  print('  Pre-K (1..$preKCount) Bob decrypted cleanly                  = '
      '$bobCleanPreK of $preKCount');
  print('                                       (legit Bob with S1 — he');
  print('                                        was never compromised.)');
  print('  Pre-K (1..$preKCount) attacker decrypted cleanly            = '
      '$attackerCleanPreK of $preKCount');
  print('                                       (attacker holds S1 — old');
  print('                                        chain keys are reachable)');
  print('  Post-K ($_kCompromiseAt..$_kTotalMessages) Bob decrypted cleanly       = '
      '$bobCleanPostK of $postKCount');
  print('                                       (legit Bob with S2 — new');
  print('                                        chain is independent of S1)');
  print('  Post-K ($_kCompromiseAt..$_kTotalMessages) attacker FAILED     = '
      '$attackerFailedPostK of $postKCount');
  print('                                       (attacker holds S1 — S2');
  print('                                        chain is unreachable)');
  print('');
  print('  Forward-secrecy claim (this demo):');
  print('    A leak of S1 (the pre-K shared secret) exposes messages sent');
  print('    on the S1 chain (1..${_kCompromiseAt - 1} in this transcript) but');
  print('    NOT messages sent on a freshly re-seeded S2 chain');
  print('    ($_kCompromiseAt..$_kTotalMessages).');
  print('');
  print('  Honest caveat (D5 / VERDICT.md):');
  print('    The HKDF-chain fallback in lib/crypto/direct.dart gives forward');
  print('    secrecy in the "stolen old key cannot read new traffic" sense');
  print('    ONLY when the chain is re-seeded (a new DH step) — this is the');
  print('    analogue of a Double-Ratchet DH ratchet. It does NOT give');
  print('    post-compromise secrecy against an attacker who steals the');
  print('    CURRENT chain key and continues to listen without a re-seed.');
  print('    Full post-compromise secrecy requires a DH ratchet on every');
  print('    send, which is out of scope for the hackathon build.');
  print('================================================================');
}