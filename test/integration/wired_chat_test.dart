// RelayLink — End-to-end wiring-gap-closure integration test.
//
// Spins up the full `bootstrapServices` (with `dbOverride` pointing at
// an in-memory sqflite) plus an extra `EchoTransport` (so the same
// device can observe the fan-out round-trip). Then exercises the
// production paths end-to-end:
//
//   1. BROADCAST round-trip: send via `RemoteChatController.sendMessage`,
//      observe the EchoTransport's loopback, decrypt via the bootstrap's
//      MessageDecryptor, and confirm the plaintext renders.
//   2. Message persistence: a second controller built on the same DB
//      hydrates from disk and decrypts the same message.
//   3. Contact pairing via ContactInvite: build an invite from the local
//      device, decode + bootstrap a DirectSession, persist via the
//      DirectSessionStore, send a DIRECT message, and verify the
//      receiver-side session decrypts the same plaintext.
//   4. Contacts lookup: the just-paired contact is resolvable via
//      `RepositoryContactsLookup.lookupByDeviceIdAsync`.

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/app/bootstrap.dart';
import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/crypto/contact_invite.dart';
import 'package:relaylink/crypto/direct.dart';
import 'package:relaylink/crypto/direct_session_store.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/screens/remote_chat_controller.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/transport/transport.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database raw;
  late LocalDb db;
  late BootstrapResult bootstrap;

  setUp(() async {
    LocalDb.resetForTesting();
    DirectSessionStore.resetForTesting();
    FlutterSecureStorage.setMockInitialValues({});
    raw = await databaseFactory.openDatabase(
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
    db = await LocalDb.withDatabase(raw);
    bootstrap = await bootstrapServices(dbOverride: db);
    // Production transports (mesh/sms/internet) register as unavailable
    // stubs; add an EchoTransport so a single device can observe the
    // full send → fan-out → incoming → decrypt loop.
    bootstrap.transportManager.register(
      EchoTransport(name: 'echo', available: true),
    );
  });

  tearDown(() async {
    await bootstrap.dispose();
    await raw.close();
  });

  test('BROADCAST round-trip renders the original plaintext', () async {
    final sent = await bootstrap.remoteChatController.sendMessage(
      type: MessageType.chat,
      body: 'integration-broadcast',
      senderId: bootstrap.identity.senderId,
    );

    // The EchoTransport loops the message back; wait for it to land.
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // The controller observed it (and deduped against the message it
    // already added) — exactly one message in the in-memory mirror.
    expect(bootstrap.remoteChatController.messages.length, 1);
    expect(bootstrap.remoteChatController.messages.first.id, sent.id);

    // The decryptor returns the original plaintext.
    final plaintext =
        await bootstrap.remoteChatController.decryptForDisplay(sent);
    expect(plaintext, 'integration-broadcast');

    // The message is persisted in LocalDb.
    final persisted = await db.listMessages();
    expect(persisted.length, 1);
    expect(persisted.first.id, sent.id);
  });

  test('A second controller hydrates from disk and decrypts the same '
      'message', () async {
    await bootstrap.remoteChatController.sendMessage(
      type: MessageType.chat,
      body: 'persisted-broadcast',
      senderId: bootstrap.identity.senderId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // Build a fresh in-memory DB for the second controller so we don't
    // collide on the first one (which is about to be closed).
    final raw2 = await databaseFactory.openDatabase(
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
    final db2 = await LocalDb.withDatabase(raw2);

    // Copy the messages from the first DB into the second so the second
    // controller sees them on hydrate.
    final all = await db.listMessages();
    for (final m in all) {
      await db2.insertMessage(m);
    }

    final second = await bootstrapServices(dbOverride: db2);
    // Register an EchoTransport on the second controller too, otherwise
    // the hydrated messages have nowhere to loop back from (they're
    // already in the DB, so this is purely defensive).
    second.transportManager.register(
      EchoTransport(name: 'echo', available: true),
    );
    addTearDown(() async {
      await second.dispose();
      await raw2.close();
    });

    // Wait for hydration microtask.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second.remoteChatController.messages.length, 1);
    final decrypted = await second.remoteChatController.decryptForDisplay(
      second.remoteChatController.messages.first,
    );
    expect(decrypted, 'persisted-broadcast');
  });

  test('ContactInvite → DirectSession → DIRECT round-trip', () async {
    // Simulate a peer device: generate a fresh DeviceIdentity and a
    // ContactInvite for it.
    final peer = await DeviceIdentity.generate();
    final peerInvite = ContactInviteCodec.forLocalDevice(peer);

    // The local controller pairs with the peer.
    await bootstrap.remoteChatController.pairWithInvite(
      invite: peerInvite,
      isInitiator: true,
    );

    // The peer (simulated) also bootstraps from our invite so it can
    // decrypt what we send.
    final selfInvite = ContactInviteCodec.forLocalDevice(bootstrap.identity);
    final peerSession = await ContactInviteCodec.bootstrapSession(
      self: peer,
      invite: selfInvite,
      isInitiator: false,
    );

    // Send a DIRECT message through the production controller.
    final sent =
        await bootstrap.remoteChatController.sendDirectMessage(
      recipientDeviceId: peer.senderId,
      type: MessageType.chat,
      body: 'integration-direct',
    );

    expect(sent.mode, MessageMode.direct);
    expect(sent.recipientId, peer.senderId);

    // The EchoTransport looped the DIRECT message back too; the receiver
    // side would normally see it via a transport subscription. Here we
    // decode it directly using the peerSession.
    final dm = DirectMessage(
      ciphertext: sent.payload,
      ratchetHeader: RemoteChatController.decodeRatchetHeader(
        sent.ratchetHeader!,
      ),
      chainKeyAfterMessage: Uint8List(32),
    );
    final plaintext = await peerSession.decrypt(dm.ciphertext, dm.ratchetHeader);
    expect(plaintext, 'integration-direct');

    // The DirectSession persisted through the DirectSessionStore.
    final stored = await bootstrap.directSessionStore.get(peer.senderId);
    expect(stored, isNotNull);
  });

  test('ContactInvite → contacts lookup resolves the just-paired contact',
      () async {
    final peer = await DeviceIdentity.generate();
    final peerInvite = ContactInviteCodec.forLocalDevice(peer);

    await bootstrap.remoteChatController.pairWithInvite(
      invite: peerInvite,
      isInitiator: true,
    );

    // Upsert via RepositoryContactsLookup (mirrors what main.dart does).
    await bootstrap.contactsLookup.upsert(
      ContactRecord(
        deviceId: peerInvite.deviceId,
        displayName: peerInvite.displayName,
        x25519PublicKey: peerInvite.x25519PublicKey,
        phoneNumber: null,
      ),
    );

    final resolved =
        await bootstrap.contactsLookup.lookupByDeviceIdAsync(peer.senderId);
    expect(resolved, isNotNull);
    expect(resolved!.deviceId, peer.senderId);
  });

  test('TransportManager reports mesh, SMS, and internet registered',
      () async {
    final names =
        bootstrap.transportManager.transports.map((t) => t.name).toSet();
    expect(names, containsAll(<String>{'mesh', 'SMS', 'internet'}));
    expect(names, contains('echo'));
  });
}
