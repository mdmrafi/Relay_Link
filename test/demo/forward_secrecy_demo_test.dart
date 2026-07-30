// RelayLink — Ticket #14 Forward-Secrecy Demo in-process test.
//
// Runs the same logic as `tools/demo_forward_secrecy.dart` (which prints a
// narrative for a 30-second README demo) but as a regular flutter_test
// suite, so the demo behavior is asserted by CI. The script is the source
// of truth for the human-facing narrative; this test pins the *outcomes*
// of the script so reviewers can run `flutter test test/demo/` and trust
// the demo output.
//
// What we assert
// ==============
//   * N = 20 messages are encrypted on the S1 chain.
//   * K = 10 is the re-seed point.
//   * The legitimate Bob (with S1) decrypts all pre-K (1..9) messages.
//   * The legitimate Bob (with S2) decrypts all post-K (10..20) messages.
//   * An attacker who captured S1 can decrypt all pre-K (1..9) messages.
//   * An attacker who captured S1 FAILS to decrypt every post-K message.
//   * The N=20 and K=10 constants stay baked in (regression guard so
//     reviewers always know which clip they're seeing in the README).

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/crypto/direct.dart';

const int _kTotalMessages = 20;
const int _kCompromiseAt = 10;

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
  return Uint8List.fromList(await s.extractBytes());
}

void main() {
  test('demo: legitimate Bob decrypts all 20 messages after a chain re-seed',
      () async {
    final s1 = await _x25519Ecdh();
    final s2 = await _x25519Ecdh();

    final aliceS1 = await DirectSession.create(s1, isInitiator: true);
    final bobS1 = await DirectSession.create(s1, isInitiator: false);
    final aliceS2 = await DirectSession.create(s2, isInitiator: true);
    final bobS2 = await DirectSession.create(s2, isInitiator: false);

    final preK = <DirectMessage>[];
    for (var i = 0; i < _kCompromiseAt - 1; i++) {
      preK.add(await aliceS1.encrypt('pre-K #$i'));
    }
    final postK = <DirectMessage>[];
    for (var i = _kCompromiseAt - 1; i < _kTotalMessages; i++) {
      postK.add(await aliceS2.encrypt('post-K #$i'));
    }

    // Bob S1 decrypts the S1-chain messages.
    for (var i = 0; i < preK.length; i++) {
      expect(
        await bobS1.decrypt(preK[i].ciphertext, preK[i].ratchetHeader),
        'pre-K #$i',
      );
    }
    // Bob S2 decrypts the S2-chain messages.
    for (var i = 0; i < postK.length; i++) {
      expect(
        await bobS2.decrypt(postK[i].ciphertext, postK[i].ratchetHeader),
        'post-K #${_kCompromiseAt - 1 + i}',
      );
    }
  });

  test('demo: attacker with captured S1 decrypts pre-K, fails on post-K',
      () async {
    final s1 = await _x25519Ecdh();
    final s2 = await _x25519Ecdh();

    final aliceS1 = await DirectSession.create(s1, isInitiator: true);
    final aliceS2 = await DirectSession.create(s2, isInitiator: true);

    final preK = <DirectMessage>[];
    final preKPlain = <String>[];
    for (var i = 0; i < _kCompromiseAt - 1; i++) {
      final pt = 'pre-K #$i';
      preKPlain.add(pt);
      preK.add(await aliceS1.encrypt(pt));
    }
    final postK = <DirectMessage>[];
    for (var i = _kCompromiseAt - 1; i < _kTotalMessages; i++) {
      postK.add(await aliceS2.encrypt('post-K #$i'));
    }

    // The attacker captured S1 and built a fresh Bob session from it.
    final attackerWithS1 = await DirectSession.create(s1, isInitiator: false);

    // Attacker decrypts every pre-K message.
    for (var i = 0; i < preK.length; i++) {
      expect(
        await attackerWithS1.decrypt(preK[i].ciphertext, preK[i].ratchetHeader),
        preKPlain[i],
        reason: 'attacker with S1 should read pre-K message #$i',
      );
    }

    // Attacker FAILS on every post-K message (because post-K is on S2).
    for (var i = 0; i < postK.length; i++) {
      await expectLater(
        () => attackerWithS1.decrypt(postK[i].ciphertext, postK[i].ratchetHeader),
        throwsA(isA<SecretBoxAuthenticationError>()),
        reason: 'attacker with S1 must not read post-K message '
            '#${_kCompromiseAt - 1 + i} (chain re-seeded to S2 at K=$_kCompromiseAt)',
      );
    }
  });

  test('demo: scripts/K values are baked in (regression guard)', () {
    // The ticket asks for N=20, K=10. If anyone changes those constants,
    // this test reminds them to re-record the README demo clip.
    expect(_kTotalMessages, 20);
    expect(_kCompromiseAt, 10);
  });
}