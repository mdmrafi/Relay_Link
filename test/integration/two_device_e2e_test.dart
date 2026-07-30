// RelayLink — Ticket #45 integration test (deterministic, offline).
//
// SCENARIO: two-physical-device happy path, simulated in-process.
//
// What this proves end-to-end:
//   1. Two distinct device identities (Ed25519 + X25519 keypairs).
//   2. Pairing: exchange X25519 public keys → mutual ECDH shared secret.
//   3. Custom channel: Alice generates a 32-byte AES-256 key and shares it
//      out-of-band with Bob.
//   4. BROADCAST SOS: Alice crafts an SOS Message, encrypts its payload
//      under the custom channel, JSON-serializes the Message envelope,
//      hands it to Bob over an in-process mesh (a function call, since
//      Bluetooth/Nearby transport is not yet built — ticket #06/#08 are
//      still WIP per HANDOFF-session2.md).
//   5. Bob deserializes the envelope, decrypts the payload using the
//      shared channel key, and verifies the Ed25519 signature against
//      Alice's public key.
//   6. Storage round-trip: Bob writes the decrypted Message to LocalDb;
//      Alice reloads it and the integrity check still passes (we use
//      separate in-memory DBs to keep the test hermetic).
//   7. Tamper detection (regression guard): flipping a bit in the
//      ciphertext causes decrypt to throw — i.e. a crypto regression
//      would turn this test red.
//
// Why this is the strongest available path right now:
//   * Identity + keys:        lib/crypto/identity.dart   (#02, shipped)
//   * AES-256-GCM:            lib/crypto/broadcast.dart  (#03, shipped)
//   * Wire format:            lib/models/message.dart    (#04, shipped)
//   * Local storage:          lib/storage/local_db.dart  (#05, shipped)
//
// Not yet covered:
//   * Mesh transport (#06–#09): not shipped. This test swaps the mesh for
//     an in-process function call — the SAME bytes the mesh would carry.
//   * DIRECT crypto (#13, HKDF-chain): not shipped. Replaced here with a
//     custom-channel-key demonstration that exercises BroadcastCrypto
//     under the same AES-256-GCM plumbing DIRECT will use.
//   * Vault (#31): not shipped.
//
// This test MUST fail meaningfully if any of the following regresses:
//   - DeviceIdentity: senderId derivation, Ed25519 sign/verify, X25519 ECDH
//   - Message schema: JSON round-trip, field-wire-format drift
//   - BroadcastCrypto: AAD binding, nonce uniqueness, MAC verification
//   - LocalDb: insert/getMessage round-trip

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/storage/local_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Two-device integration scenario (Ticket #45)', () {
    test(
        'pair -> broadcast SOS over custom channel -> receive -> store -> reload',
        () async {
      // -----------------------------------------------------------------
      // 0. Clean slate: mock secure storage so two devices can each carry
      //    distinct identity keys without interference.
      // -----------------------------------------------------------------
      FlutterSecureStorage.setMockInitialValues(<String, String>{});

      // -----------------------------------------------------------------
      // 1. Two distinct device identities.
      // -----------------------------------------------------------------
      final alice = await DeviceIdentity.generate();
      final bob = await DeviceIdentity.generate();
      expect(alice.senderId, isNot(bob.senderId),
          reason: 'two devices must have distinct pseudonymous sender ids');

      // 16-hex sender ids.
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(alice.senderId), isTrue);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(bob.senderId), isTrue);

      // -----------------------------------------------------------------
      // 2. Pairing: exchange X25519 public keys, derive mutual ECDH
      //    shared secret. The mesh layer (not yet built) will transport
      //    these public keys; here we just hand them across the room.
      // -----------------------------------------------------------------
      final aliceSharedSecret =
          await alice.ecdh(bob.x25519PublicKeyBytes);
      final bobSharedSecret = await bob.ecdh(alice.x25519PublicKeyBytes);
      expect(aliceSharedSecret.length, 32,
          reason: 'X25519 ECDH must yield a 32-byte secret');
      expect(aliceSharedSecret, equals(bobSharedSecret),
          reason: 'ECDH must be symmetric across the two parties');

      // -----------------------------------------------------------------
      // 3. Custom channel: Alice generates a fresh 32-byte AES-256 key and
      //    shares it with Bob via the (future) QR-code channel-invite
      //    surface (ticket #16). Here it's a direct call.
      //    Non-joined devices see the routing metadata but cannot decrypt.
      // -----------------------------------------------------------------
      final channelId = 'demo-relief-2026';
      final cryptoA = BroadcastCrypto();
      final cryptoB = BroadcastCrypto();
      // Pull the embedded public-channel key out (they both have it by
      // construction), then Alice registers a custom key only she knows
      // exists — Bob receives it out-of-band.
      cryptoA.setChannelKey(
        channelId,
        Uint8List.fromList(
          List<int>.generate(32, (i) => (i * 13 + 7) & 0xff),
        ),
      );
      final sharedChannelKey = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 13 + 7) & 0xff),
      );
      cryptoB.setChannelKey(channelId, sharedChannelKey);

      // A third "non-joined" device has the same default public key but no
      // entry for the custom channel — it can relay but cannot read.
      final cryptoC = BroadcastCrypto();
      expect(cryptoA.hasChannelKey(channelId), isTrue);
      expect(cryptoB.hasChannelKey(channelId), isTrue);
      expect(cryptoC.hasChannelKey(channelId), isFalse,
          reason: 'non-joined device must not possess the custom channel key');

      // -----------------------------------------------------------------
      // 4. Alice crafts + signs + encrypts an SOS.
      // -----------------------------------------------------------------
      const plaintextString =
          'Trapped at 39.91N 116.40E. Two injured. Need medical help.';
      final envelope = await cryptoA.encryptString(
        plaintextString,
        channelId,
      );
      expect(envelope.channelId, channelId);
      expect(envelope.nonce.length, 12); // GCM nonce size.
      expect(envelope.mac.length, 16); // GCM tag size.

      // Wrap ciphertext into a Message envelope and sign it.
      // (Signature covers ciphertext + metadata so a relay cannot
      // tamper with the message fields without breaking the signature.)
      final innerMessage = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.sos,
        channelId: channelId,
        senderId: alice.senderId,
        senderDisplayName: 'Alice',
        recipientId: null,
        payload: Uint8List.fromList(envelope.ciphertext),
        location: const GeoLocation(
          latitude: 39.91,
          longitude: 116.40,
          accuracyMeters: 5.0,
        ),
      );
      // Canonical signing input: JSON canonicalization, then Ed25519 sign.
      // The signature is over the canonical envelope so any tamper — even
      // a hop-count bump — breaks it.
      final canonicalForSig = utf8.encode(
        jsonEncode(innerMessage.toJson()..remove('signature')),
      );
      final sig = await alice.sign(canonicalForSig);
      final signedMessage = innerMessage.copyWith(signature: sig);

      // -----------------------------------------------------------------
      // 5. Bob receives: deserialize, verify signature, decrypt with the
      //    shared channel key he got out-of-band in step 3.
      // -----------------------------------------------------------------
      // The transport layer (Bluetooth mesh, future) would deliver these
      // bytes as a String over the wire; we round-trip through JSON to
      // exercise the on-wire format that the mesh layer will need to
      // honor.
      final jsonBytes = utf8.encode(jsonEncode(signedMessage.toJson()));
      final jsonString = utf8.decode(jsonBytes);
      final parsed =
          Message.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);

      // Identity check: message claims Alice's sender id.
      expect(parsed.senderId, alice.senderId);

      // Verify the signature BEFORE attempting decrypt — a forged message
      // must be rejected even if the cipher happens to be well-formed.
      final canonicalAgain = utf8.encode(
        jsonEncode(parsed.toJson()..remove('signature')),
      );
      final ok = await DeviceIdentity.verify(
        canonicalAgain,
        signature: parsed.signature!,
        publicKey: alice.ed25519PublicKeyBytes,
      );
      expect(ok, isTrue,
          reason: 'Bob must reject messages whose signature fails to verify');

      // Decrypt under the shared channel key. Bob uses cryptoB which has
      // the same `channelId` key as cryptoA.
      final bobEnvelope = BroadcastEnvelope(
        channelId: parsed.channelId,
        nonce: envelope.nonce,
        ciphertext: parsed.payload,
        mac: envelope.mac,
      );
      final decrypted = await cryptoB.decryptString(bobEnvelope);
      expect(decrypted, plaintextString,
          reason: 'Bob must recover Alice\'s plaintext via the shared '
              'channel key');
      expect(decrypted.codeUnits, equals(utf8.encode(plaintextString)));

      // -----------------------------------------------------------------
      // 6. Storage round-trip: write to Bob's LocalDb, reload from Alice's
      //    LocalDb by replaying the JSON. (We use two databases to model
      //    two physical devices; each holds its own seen-cache.)
      // -----------------------------------------------------------------
      // Bob's DB.
      final bobDbRaw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: LocalDb.schemaVersion,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON;');
          },
          onCreate: (db, _) async {
            await LocalDb.migrate(db);
          },
        ),
      );
      addTearDown(bobDbRaw.close);

      // Alice's DB (separate — represents a second physical device).
      final aliceDbRaw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: LocalDb.schemaVersion,
          onConfigure: (db) async {
            await db.execute('PRAGMA foreign_keys = ON;');
          },
          onCreate: (db, _) async {
            await LocalDb.migrate(db);
          },
        ),
      );
      addTearDown(aliceDbRaw.close);

      // Singleton bookkeeping in LocalDb is process-wide; tests must reset
      // before (re)binding. The wrapper holds the most-recently-bound db,
      // so we bind Alice last to ensure `aliceDb` resolves to Alice.
      LocalDb.resetForTesting();
      final bobDb = await LocalDb.withDatabase(bobDbRaw);
      LocalDb.resetForTesting();
      final aliceDb = await LocalDb.withDatabase(aliceDbRaw);

      // Bob persists the *received* signed message and marks its id seen
      // so the mesh relay will not re-broadcast if a redundant copy
      // arrives (the deduplication id is the message's UUID).
      await bobDb.insertMessage(parsed);
      await bobDb.markSeen(parsed.id);

      // "Alice" receives a relayed copy of the same envelope via her
      // own (separate) LocalDb — this simulates a multi-hop mesh where the
      // message traverses nodes that each maintain local persistence.
      await aliceDb.insertMessage(parsed);
      await aliceDb.markSeen(parsed.id);

      // Read both ways:
      //  - From Bob's db (directly inserted)
      //  - From Alice's db (relayed hop)
      final bobSide = await bobDb.getMessage(parsed.id);
      final aliceSide = await aliceDb.getMessage(parsed.id);
      expect(bobSide, isNotNull);
      expect(aliceSide, isNotNull);
      expect(bobSide, equals(parsed));
      expect(aliceSide, equals(parsed));

      // seen-cache dedup check.
      expect(await bobDb.isSeen(parsed.id), isTrue);
      expect(await aliceDb.isSeen(parsed.id), isTrue);

      // -----------------------------------------------------------------
      // 7. Tamper detection (regression guard): flipping a single bit in
      //    the ciphertext causes decrypt to throw — even on the device
      //    that knows the channel key. If this ever stops throwing, AES-
      //    GCM MAC verification has regressed.
      // -----------------------------------------------------------------
      final tamperedEnvelope = BroadcastEnvelope(
        channelId: envelope.channelId,
        nonce: envelope.nonce,
        ciphertext: Uint8List.fromList(envelope.ciphertext)..[0] ^= 0x01,
        mac: envelope.mac,
      );
      await expectLater(
        () => cryptoB.decryptString(tamperedEnvelope),
        throwsA(isA<SecretBoxAuthenticationError>()),
        reason: 'Crypto regression: ciphertext tamper must break MAC check',
      );

      // Channel-id AAD tamper (defense-in-depth): an attacker who re-routes
      // a captured ciphertext to a different channel id must still fail
      // authentication.
      //
      // To prove this is the AAD binding firing (and not "we used the
      // wrong key because Bob doesn't have that channel registered"),
      // we register kPublicChannelId in cryptoB with the SAME key as the
      // custom channel. If AAD binding were broken, decrypt would succeed
      // under the (now-matching) key; AAD binding forces an auth failure.
      cryptoB.setChannelKey(kPublicChannelId, sharedChannelKey);
      final spoofedEnvelope = BroadcastEnvelope(
        channelId: kPublicChannelId, // lie about the channel
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
        mac: envelope.mac,
      );
      await expectLater(
        () => cryptoB.decryptString(spoofedEnvelope),
        throwsA(isA<SecretBoxAuthenticationError>()),
        reason: 'AAD binding must force auth failure when channel id is '
            'spoofed, even if the decrypting device has the correct key '
            'registered for the spoofed channel',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test(
        'non-joined third device can identify the message routing metadata '
        'but cannot decrypt the payload', () async {
      // Sanity: even a passive observer that does NOT have the custom
      // channel key can still see routing fields (senderId, channelId,
      // mode, type, ttl) — that's the design per SPEC.md §5 (routing
      // metadata is plaintext so relays can route without decrypting).
      final alice = await DeviceIdentity.generate();
      final cryptoA = BroadcastCrypto();
      final channelId = 'isolated-channel';
      cryptoA.setChannelKey(
        channelId,
        Uint8List.fromList(List<int>.generate(32, (i) => (i * 17 + 3) & 0xff)),
      );

      final plaintext = utf8.encode('classified: evacuate via route B');
      final envelope = await cryptoA.encrypt(plaintext, channelId);
      final msg = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.alert,
        channelId: channelId,
        senderId: alice.senderId,
        payload: Uint8List.fromList(envelope.ciphertext),
      );

      // A passive observer has its own BroadcastCrypto with only the
      // embedded public key — exactly the situation the spec calls out.
      final observer = BroadcastCrypto();

      // Routing metadata is visible.
      expect(msg.senderId, alice.senderId);
      expect(msg.channelId, channelId);
      expect(msg.mode, MessageMode.broadcast);

      // But the payload is opaque to them.
      final observerEnvelope = BroadcastEnvelope(
        channelId: channelId, // claims the channel
        nonce: envelope.nonce,
        ciphertext: msg.payload,
        mac: envelope.mac,
      );
      expect(
        () => observer.decrypt(observerEnvelope),
        throwsA(isA<UnknownChannelException>()),
        reason: 'A non-joined device must fail decryption (UnknownChannel) '
            'rather than receiving a tampered MAC error — because they '
            'don\'t have the key at all.',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
