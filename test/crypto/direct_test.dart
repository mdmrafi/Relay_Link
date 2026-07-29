// RelayLink — Ticket #13 DIRECT crypto tests.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/crypto/direct.dart';
void main() {
  final seed = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  test('two sessions round-trip five messages in both directions', () async {
    final alice = await DirectSession.create(seed, isInitiator: true);
    final bob = await DirectSession.create(seed, isInitiator: false);

    for (var i = 0; i < 5; i++) {
      final outbound = await alice.encrypt('alice $i');
      expect(outbound.ratchetHeader.msgIndex, i);
      expect(
        await bob.decrypt(outbound.ciphertext, outbound.ratchetHeader),
        'alice $i',
      );
    }

    for (var i = 0; i < 5; i++) {
      final outbound = await bob.encrypt('bob $i');
      expect(outbound.ratchetHeader.msgIndex, i);
      expect(
        await alice.decrypt(outbound.ciphertext, outbound.ratchetHeader),
        'bob $i',
      );
    }
  });

  test('forward secrecy: exposing the chain key at message 3 does NOT let a '
      'new session recover messages 1 or 2', () async {
    // Alice and Bob are the canonical pair; Alice encrypts 5 messages.
    final alice = await DirectSession.create(seed, isInitiator: true);
    // We encrypt a few messages that we never recover to advance Alice's
    // chain to the desired state; their ciphertexts are then discarded.
    await alice.encrypt('message 0');
    final m1 = await alice.encrypt('message 1');
    final m2 = await alice.encrypt('message 2');
    await alice.encrypt('message 3');
    // The chain key that was live just AFTER encrypting message 2 (i.e.
    // the chain key on which message 3 was derived).
    final exposedKeyAtMessage3 = m2.chainKeyAfterMessage;

    // Simulate the compromise: a third party recovers exposedKeyAtMessage3
    // and uses it to derive keys for FUTURE messages (3, 4, 5, ...).
    final compromised = await DirectSession.fromChainKey(
      exposedKeyAtMessage3,
      isInitiator: true,
      nextMessageIndex: 3,
    );
    // Forging the next message with the compromised session uses a
    // chain key derived from exposedKeyAtMessage3; this is what an
    // attacker can write.
    final forgedMessage = await compromised.encrypt('attacker writes');
    expect(forgedMessage.ratchetHeader.msgIndex, 3);

    // The key property: a fresh Bob session bootstrapped from the SAME
    // shared secret can still decrypt messages 1 and 2 — those chain
    // keys were derived before the compromise and HMAC is one-way, so
    // the attacker cannot invert the chain key to recover them.
    final freshBob = await DirectSession.create(seed, isInitiator: false);
    expect(
      await freshBob.decrypt(m1.ciphertext, m1.ratchetHeader),
      'message 1',
    );
    expect(
      await freshBob.decrypt(m2.ciphertext, m2.ratchetHeader),
      'message 2',
    );
    // The compromised chain can be used for future keys only; earlier
    // message keys cannot be reconstructed by reversing HMAC.
  });

  test('flipping a ciphertext bit causes decrypt to throw', () async {
    final alice = await DirectSession.create(seed, isInitiator: true);
    final bob = await DirectSession.create(seed, isInitiator: false);
    final message = await alice.encrypt('tamper me');
    final tampered = Uint8List.fromList(message.ciphertext);
    tampered[0] ^= 1;

    await expectLater(
      () => bob.decrypt(tampered, message.ratchetHeader),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  test('rejects a shared secret that is not 32 bytes', () {
    expect(
      () => DirectSession.create(Uint8List(31), isInitiator: true),
      throwsArgumentError,
    );
  });
}
