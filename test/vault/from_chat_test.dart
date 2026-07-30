// RelayLink — Ticket #34 "Save as evidence" from chat (long-press affordance).
//
// Tests for the bridge between the chat layer and the encrypted Evidence
// Vault. Sets up the same in-memory sqflite + mocked secure storage used
// by `test/vault/store_test.dart`, then exercises the
// [SaveMessageAsEvidence] service end-to-end (capture -> encrypt ->
// stamp provenance -> round-trip decrypt -> look up by message id).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/vault/from_chat.dart';
import 'package:relaylink/vault/store.dart';
import 'package:uuid/uuid.dart';

const _evidenceBody = 'local shelter needs water and medicine';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SaveMessageAsEvidence', () {
    late Database raw;
    late LocalDb db;
    late DeviceIdentity identity;
    late VaultStore vault;
    late SaveMessageAsEvidence saver;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      identity = await DeviceIdentity.generate();
      await identity.save();
      raw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: LocalDb.schemaVersion,
          onConfigure: (d) async {
            await d.execute('PRAGMA foreign_keys = ON;');
          },
          onCreate: (d, _) async {
            await LocalDb.migrate(d);
          },
        ),
      );
      db = await LocalDb.withDatabase(raw);
      vault = await VaultStore.create(identity: identity, db: db);
      saver = SaveMessageAsEvidence(store: vault, db: db);
    });

    tearDown(() async {
      await raw.close();
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });

    /// Build a deterministic chat-shaped [Message] we can reference.
    Message buildChatMessage({String? id, String body = _evidenceBody}) {
      return Message(
        id: id ?? const Uuid().v4(),
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'sender-1',
        senderDisplayName: 'Sender One',
        origin: MessageOrigin.mesh,
        recipientId: null,
        // For broadcast chat the payload is the plaintext (we don't
        // run a full ratchet here — the chat layer is responsible for
        // giving us readable text, see from_chat.dart docstring).
        payload: Uint8List.fromList(utf8.encode(body)),
        ratchetHeader: null,
        location: null,
        createdAt: DateTime.utc(2026, 7, 30, 12, 0),
        ttl: MessageDefaults.defaultTtlFor(MessageType.chat),
        hopCount: 0,
        signature: null,
        inResponseTo: null,
      );
    }

    test('save captures plaintext into the vault and stamps '
        'origin_message_id on the row', () async {
      final message = buildChatMessage();

      final saved = await saver.save(
        message: message,
        plaintext: _evidenceBody,
      );

      expect(saved.record.id, isNotEmpty);
      expect(saved.originMessageId, message.id);

      // The vault record was encrypted — body bytes are not the
      // plaintext bytes.
      expect(saved.record.ciphertext, isNot(equals(utf8.encode(_evidenceBody))));

      // Decryption round-trips back to the original plaintext.
      final decrypted = await vault.decrypt(saved.record);
      expect(utf8.decode(decrypted), _evidenceBody);

      // Provenance is queryable on the row.
      final stored = await saver.originMessageIdFor(saved.record.id);
      expect(stored, message.id);
    });

    test('origin_message_id column is added lazily and is idempotent',
        () async {
      // Confirm the column does NOT exist yet on a fresh install
      // (LocalDb v2 schema shipped before this ticket).
      final before = await raw.rawQuery(
        'PRAGMA table_info(vault_records);',
      );
      expect(
        before.any((row) => row['name'] == 'origin_message_id'),
        isFalse,
        reason: 'fresh v2 schema should not declare origin_message_id',
      );

      final message = buildChatMessage();
      final saved = await saver.save(
        message: message,
        plaintext: _evidenceBody,
      );

      // After the first save the column exists.
      final after = await raw.rawQuery(
        'PRAGMA table_info(vault_records);',
      );
      expect(
        after.any((row) => row['name'] == 'origin_message_id'),
        isTrue,
      );

      // A second save is a no-op for the schema (doesn't blow up
      // with "duplicate column") and still stamps provenance.
      final second = buildChatMessage();
      final saved2 = await saver.save(
        message: second,
        plaintext: _evidenceBody,
      );
      expect(saved2.originMessageId, second.id);

      // Each row has its own provenance.
      expect(await saver.originMessageIdFor(saved.record.id), message.id);
      expect(
        await saver.originMessageIdFor(saved2.record.id),
        second.id,
      );
    });

    test('plaintext is not leaked into any persisted vault column',
        () async {
      final message = buildChatMessage();
      final saved = await saver.save(
        message: message,
        plaintext: _evidenceBody,
      );

      final rows = await raw.query(
        'vault_records',
        where: 'id = ?',
        whereArgs: <Object?>[saved.record.id],
      );
      expect(rows.length, 1);
      final row = rows.first;

      String asText(Object? v) {
        if (v is Uint8List) return utf8.decode(v, allowMalformed: true);
        if (v is List<int>) {
          return utf8.decode(v, allowMalformed: true);
        }
        if (v is String) return v;
        return v.toString();
      }

      // Only the `origin_message_id` is allowed to be readable text —
      // every other column must stay opaque (ciphertext + wrapped key).
      for (final entry in row.entries) {
        if (entry.key == 'origin_message_id') continue;
        expect(
          asText(entry.value),
          isNot(contains(_evidenceBody)),
          reason: 'plaintext leaked into column ${entry.key}',
        );
      }
      expect(row['origin_message_id'], isA<String>());
      expect(row['origin_message_id'], message.id);
    });

    test('save works for own (sender == self) and received messages',
        () async {
      // Own message.
      final own = Message(
        id: const Uuid().v4(),
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'me',
        senderDisplayName: 'Me',
        origin: MessageOrigin.mesh,
        recipientId: null,
        payload: Uint8List.fromList(utf8.encode('sent-from-me')),
        ratchetHeader: null,
        location: null,
        createdAt: DateTime.utc(2026, 7, 30, 12, 0),
        ttl: MessageDefaults.defaultTtlFor(MessageType.chat),
        hopCount: 0,
        signature: null,
        inResponseTo: null,
      );
      final ownSaved = await saver.save(
        message: own,
        plaintext: 'sent-from-me',
      );
      expect(ownSaved.originMessageId, own.id);
      expect(
        utf8.decode(await vault.decrypt(ownSaved.record)),
        'sent-from-me',
      );

      // Received message.
      final incoming = Message(
        id: const Uuid().v4(),
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'remote-peer',
        senderDisplayName: 'Remote Peer',
        origin: MessageOrigin.mesh,
        recipientId: null,
        payload: Uint8List.fromList(utf8.encode('received-by-me')),
        ratchetHeader: null,
        location: null,
        createdAt: DateTime.utc(2026, 7, 30, 12, 1),
        ttl: MessageDefaults.defaultTtlFor(MessageType.chat),
        hopCount: 2,
        signature: null,
        inResponseTo: null,
      );
      final incomingSaved = await saver.save(
        message: incoming,
        plaintext: 'received-by-me',
      );
      expect(incomingSaved.originMessageId, incoming.id);
      expect(
        utf8.decode(await vault.decrypt(incomingSaved.record)),
        'received-by-me',
      );
    });

    test('saving the same message twice produces two distinct vault rows '
        'sharing the same origin_message_id', () async {
      final message = buildChatMessage();

      final a = await saver.save(
        message: message,
        plaintext: _evidenceBody,
      );
      final b = await saver.save(
        message: message,
        plaintext: _evidenceBody,
      );

      expect(a.record.id, isNot(equals(b.record.id)));
      // Same provenance — both rows point to the same chat message.
      expect(
        await saver.originMessageIdFor(a.record.id),
        message.id,
      );
      expect(
        await saver.originMessageIdFor(b.record.id),
        message.id,
      );

      // Both rows still decrypt.
      expect(utf8.decode(await vault.decrypt(a.record)), _evidenceBody);
      expect(utf8.decode(await vault.decrypt(b.record)), _evidenceBody);
    });

    test('save rejects empty plaintext', () async {
      final message = buildChatMessage();
      await expectLater(
        () => saver.save(message: message, plaintext: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('vault rows saved before this ticket have no origin_message_id '
        'and originMessageIdFor returns null', () async {
      // Capture a record WITHOUT going through the from-chat service so
      // no provenance column write happens.
      final direct = await vault.capture('plain vault-only record');

      // origin_message_id is null (column added later, value unset).
      expect(await saver.originMessageIdFor(direct.id), isNull);
    });

    test('ChatMessageAction.saveAsEvidence has the label required by the '
        'ticket spec', () {
      expect(ChatMessageAction.saveAsEvidence.id, 'save_as_evidence');
      expect(ChatMessageAction.saveAsEvidence.label, 'Save as evidence');
    });
  });
}
