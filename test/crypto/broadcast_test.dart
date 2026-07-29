// RelayLink — Ticket #03: BROADCAST crypto unit tests.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/crypto/broadcast.dart';

void main() {
  group('BroadcastCrypto', () {
    test('default constructor registers the public channel', () {
      final crypto = BroadcastCrypto();
      expect(crypto.hasChannelKey(kPublicChannelId), isTrue);
      expect(crypto.hasChannelKey('does-not-exist'), isFalse);
    });

    test('default networkKey is a valid 32-byte AES-256 key', () {
      // Defensive: if anyone regenerates networkKey and forgets the length
      // guarantee, this test fails loudly instead of silently misusing GCM.
      expect(networkKey.length, 32);
      // Sanity: it's not all-zero (which would be a catastrophic miss).
      expect(networkKey.any((b) => b != 0), isTrue);
    });

    test('round-trip encrypt/decrypt on the default public channel', () async {
      final crypto = BroadcastCrypto();
      const message = 'hello, mesh 👋';

      final env = await crypto.encryptString(message, kPublicChannelId);
      expect(env.channelId, kPublicChannelId);
      expect(env.nonce.length, 12); // GCM default nonce length
      expect(env.mac.length, 16); // GCM tag length
      expect(env.ciphertext, isNot(equals(utf8.encode(message))));

      final recovered = await crypto.decryptString(env);
      expect(recovered, message);
    });

    test('two encryptions of the same plaintext use different nonces', () async {
      final crypto = BroadcastCrypto();
      const message = 'identical input';

      final a = await crypto.encryptString(message, kPublicChannelId);
      final b = await crypto.encryptString(message, kPublicChannelId);

      // Random nonces → different ciphertexts even for the same plaintext.
      expect(a.nonce, isNot(equals(b.nonce)));
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
    });

    test('two BroadcastCrypto instances round-trip (shared key)', () async {
      // Sender and receiver each have their own instance, but the registry
      // is seeded from the same embedded `networkKey`.
      final sender = BroadcastCrypto();
      final receiver = BroadcastCrypto();

      final env = await sender.encryptString('ping', kPublicChannelId);
      final pt = await receiver.decryptString(env);
      expect(pt, 'ping');
    });

    test('flipping a bit in ciphertext causes decrypt to throw', () async {
      final crypto = BroadcastCrypto();
      final env = await crypto.encryptString('secret message', kPublicChannelId);

      // Tamper: flip the lowest bit of the first ciphertext byte.
      final tampered = BroadcastEnvelope(
        channelId: env.channelId,
        nonce: env.nonce,
        ciphertext: Uint8List.fromList(env.ciphertext),
        mac: env.mac,
      );
      tampered.ciphertext[0] = tampered.ciphertext[0] ^ 0x01;

      await expectLater(
        () => crypto.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      // And critically: no plaintext should ever leak. We assert the error
      // type (above) and that we cannot squeeze bytes out of the tamper.
      // This is the "no plaintext leaked" property the ticket requires.
    });

    test('flipping a bit in the MAC causes decrypt to throw', () async {
      final crypto = BroadcastCrypto();
      final env = await crypto.encryptString('another secret', kPublicChannelId);

      final tampered = BroadcastEnvelope(
        channelId: env.channelId,
        nonce: env.nonce,
        ciphertext: env.ciphertext,
        mac: Uint8List.fromList(env.mac),
      );
      tampered.mac[0] = tampered.mac[0] ^ 0x80;

      await expectLater(
        () => crypto.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('channel id mismatch (AAD tamper) causes decrypt to throw', () async {
      final crypto = BroadcastCrypto();
      final env = await crypto.encryptString('channel-bound', kPublicChannelId);

      // Register the spoof channel id so decrypt can resolve a key and
      // proceed to AAD verification. Then lie about the channel id — the
      // AAD won't match the original `public` AAD → MAC fails.
      crypto.setChannelKey(
        'public-but-not-really',
        List<int>.generate(32, (i) => i),
      );
      final tampered = BroadcastEnvelope(
        channelId: 'public-but-not-really',
        nonce: env.nonce,
        ciphertext: env.ciphertext,
        mac: env.mac,
      );

      await expectLater(
        () => crypto.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('custom channel key registered at runtime round-trips', () async {
      final crypto = BroadcastCrypto();
      final customKey = List<int>.generate(32, (i) => (i * 7 + 11) & 0xff);

      crypto.setChannelKey('ops', customKey);

      final env = await crypto.encryptString('ops note', 'ops');
      final pt = await crypto.decryptString(env);
      expect(pt, 'ops note');

      // And the public channel still works after registering a custom one.
      final envPub = await crypto.encryptString('still works', kPublicChannelId);
      expect(await crypto.decryptString(envPub), 'still works');
    });

    test('setChannelKey rejects non-32-byte keys', () {
      final crypto = BroadcastCrypto();
      expect(
        () => crypto.setChannelKey('short', List<int>.filled(16, 0)),
        throwsArgumentError,
      );
      expect(
        () => crypto.setChannelKey('long', List<int>.filled(64, 0)),
        throwsArgumentError,
      );
    });

    test('setChannelKey can replace an existing key', () async {
      final crypto = BroadcastCrypto();
      final originalKey = List<int>.generate(32, (i) => i);
      final replacementKey = List<int>.generate(32, (i) => 255 - i);

      crypto.setChannelKey('rotating', originalKey);
      final env = await crypto.encryptString('phase 1', 'rotating');
      expect(await crypto.decryptString(env), 'phase 1');

      // Rotate. Old ciphertexts should now fail to decrypt.
      crypto.setChannelKey('rotating', replacementKey);
      await expectLater(
        () => crypto.decrypt(env),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      // New encryptions under the replacement key work.
      final env2 = await crypto.encryptString('phase 2', 'rotating');
      expect(await crypto.decryptString(env2), 'phase 2');
    });

    test('decrypt with an unknown channel id throws UnknownChannelException',
        () async {
      // Build an envelope under a channel that isn't registered, by
      // registering it transiently, encrypting, then dropping it.
      final crypto = BroadcastCrypto();
      final ephemeralKey = List<int>.generate(32, (i) => i);

      crypto.setChannelKey('secret-channel', ephemeralKey);
      final env = await crypto.encryptString('classified', 'secret-channel');

      // Now simulate the receiver never having been invited.
      final isolated = BroadcastCrypto();
      expect(
        () => isolated.decrypt(env),
        throwsA(isA<UnknownChannelException>()),
      );

      try {
        await isolated.decrypt(env);
      } on UnknownChannelException catch (e) {
        expect(e.channelId, 'secret-channel');
      }
    });

    test('encrypt with an unknown channel id throws UnknownChannelException',
        () async {
      final crypto = BroadcastCrypto();
      await expectLater(
        () => crypto.encryptString('hi', 'no-such-channel'),
        throwsA(isA<UnknownChannelException>()),
      );
    });

    test('UnknownChannelException is a typed Exception subclass', () {
      const e = UnknownChannelException('x');
      expect(e, isA<Exception>());
      expect(e.channelId, 'x');
      expect(e.toString(), contains('x'));
    });

    test('handles empty plaintext and binary plaintext', () async {
      final crypto = BroadcastCrypto();

      final empty = await crypto.encrypt(<int>[], kPublicChannelId);
      expect(await crypto.decrypt(empty), <int>[]);

      final binary = Uint8List.fromList(List<int>.generate(1024, (i) => i));
      final env = await crypto.encrypt(binary, kPublicChannelId);
      expect(await crypto.decrypt(env), equals(binary));
    });
  });
}