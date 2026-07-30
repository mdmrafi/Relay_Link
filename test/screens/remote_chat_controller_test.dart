// RelayLink — `RemoteChatController` tests.
//
// Covers the BROADCAST and DIRECT round-trips against an in-memory
// sqflite, a real `DirectSessionStore`, and an `EchoTransport` for the
// in-test loopback that exercises the `TransportManager.fanOutSend`
// path.

import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/crypto/contact_invite.dart';
import 'package:relaylink/crypto/direct.dart';
import 'package:relaylink/crypto/direct_session_store.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/screens/chat.dart';
import 'package:relaylink/screens/remote_chat_controller.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/transport/transport.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<String?> Function(Message) buildDecryptor(BroadcastCrypto crypto) {
    return (msg) async {
      if (msg.mode != MessageMode.broadcast) return null;
      try {
        final env = BroadcastEnvelope.fromJsonBytes(msg.payload);
        if (!crypto.hasChannelKey(env.channelId)) return null;
        return crypto.decryptString(env);
      } catch (_) {
        return null;
      }
    };
  }

  late Database raw;
  late LocalDb db;
  late DeviceIdentity self;
  late DeviceIdentity peer;
  late DirectSessionStore sessionStore;
  late BroadcastCrypto broadcastCrypto;
  late TransportManager transports;
  late EchoTransport echo;
  late RemoteChatController controller;

  setUp(() async {
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
    FlutterSecureStorage.setMockInitialValues({});
    self = await DeviceIdentity.generate();
    peer = await DeviceIdentity.generate();
    sessionStore = DirectSessionStore(const FlutterSecureStorage());
    broadcastCrypto = BroadcastCrypto();
    transports = TransportManager();
    echo = EchoTransport(name: 'echo', available: true);
    transports.register(echo);

    controller = RemoteChatController(
      db: db,
      transports: transports,
      identity: self,
      broadcastCrypto: broadcastCrypto,
      directSessionStore: sessionStore,
      decryptor: buildDecryptor(broadcastCrypto),
    );
  });

  tearDown(() async {
    controller.dispose();
    echo.close();
    await sessionStore.close();
    await raw.close();
  });

  group('RemoteChatController (BROADCAST)', () {
    test('sendMessage broadcasts through the registered transport',
        () async {
      final msg = await controller.sendMessage(
        type: MessageType.chat,
        body: 'hello',
        senderId: self.senderId,
      );
      expect(msg.mode, MessageMode.broadcast);
      expect(msg.payload, isNot(Uint8List(0)));

      // The EchoTransport looped the message back onto its own stream;
      // RemoteChatController should have observed it (and deduped
      // against the message we already added). The end-state is that
      // we have exactly one message in the in-memory mirror.
      // Wait one microtask for the stream to drain.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.messages.length, 1);
      expect(controller.messages.first.id, msg.id);
    });

    test('decryptForDisplay returns the plaintext for a freshly sent message',
        () async {
      final msg = await controller.sendMessage(
        type: MessageType.chat,
        body: 'plaintext body',
        senderId: self.senderId,
      );
      final decrypted = await controller.decryptForDisplay(msg);
      expect(decrypted, 'plaintext body');
    });

    test('updateStatus flips the message status and notifies listeners',
        () async {
      var notifyCount = 0;
      controller.addListener(() => notifyCount++);
      final msg = await controller.sendMessage(
        type: MessageType.chat,
        body: 'oi',
        senderId: self.senderId,
      );
      // The send already notified. Look at the post-send state.
      final before = notifyCount;
      controller.updateStatus(msg.id, MessageStatus.failed);
      expect(notifyCount, before + 1);
      controller.updateStatus(msg.id, MessageStatus.failed);
      // Same value: no second notify.
      expect(notifyCount, before + 1);
    });

    test('messages persist across controller re-instantiation', () async {
      await controller.sendMessage(
        type: MessageType.chat,
        body: 'persistent',
        senderId: self.senderId,
      );
      // Wait for the in-memory mirror to be persisted.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Build a fresh controller over the same DB.
      final second = RemoteChatController(
        db: db,
        transports: transports,
        identity: self,
        broadcastCrypto: broadcastCrypto,
        directSessionStore: sessionStore,
        decryptor: buildDecryptor(broadcastCrypto),
      );
      addTearDown(second.dispose);

      // Wait for hydration.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(second.messages.length, 1);
      final decrypted = await second.decryptForDisplay(second.messages.first);
      expect(decrypted, 'persistent');
    });
  });

  group('RemoteChatController (DIRECT)', () {
    test('sendDirectMessage requires a paired session', () async {
      expect(
        () => controller.sendDirectMessage(
          recipientDeviceId: peer.senderId,
          type: MessageType.chat,
          body: 'hi',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('pairWithInvite → sendDirectMessage → decrypt via receiver session',
        () async {
      // Both sides bootstrap from each other's invite.
      final selfInvite = ContactInviteCodec.forLocalDevice(self);
      final peerInvite = ContactInviteCodec.forLocalDevice(peer);

      // The local device pairs with the peer.
      await controller.pairWithInvite(
        invite: peerInvite,
        isInitiator: true,
      );

      // The peer (simulated) also bootstraps from our invite.
      final peerSession = await ContactInviteCodec.bootstrapSession(
        self: peer,
        invite: selfInvite,
        isInitiator: false,
      );

      // Send a DIRECT message.
      final msg = await controller.sendDirectMessage(
        recipientDeviceId: peer.senderId,
        type: MessageType.chat,
        body: 'direct hello',
      );
      expect(msg.mode, MessageMode.direct);
      expect(msg.recipientId, peer.senderId);

      // The EchoTransport will loop the message back. The receiver side
      // would normally decrypt via the peerSession. We simulate that
      // here.
      final dm = DirectMessage(
        ciphertext: msg.payload,
        ratchetHeader: RemoteChatController.decodeRatchetHeader(
          msg.ratchetHeader!,
        ),
        chainKeyAfterMessage: Uint8List(32),
      );
      final plaintext = await peerSession.decrypt(dm.ciphertext, dm.ratchetHeader);
      expect(plaintext, 'direct hello');
    });

    test('pairWithInvite persists the session to the DirectSessionStore',
        () async {
      final peerInvite = ContactInviteCodec.forLocalDevice(peer);
      await controller.pairWithInvite(
        invite: peerInvite,
        isInitiator: true,
      );
      final loaded = await sessionStore.get(peer.senderId);
      expect(loaded, isNotNull);
    });
  });
}
