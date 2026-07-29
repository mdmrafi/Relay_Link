// RelayLink — Ticket #05 local DB tests.
//
// Uses an in-memory sqflite_common_ffi database so tests don't touch the
// host filesystem. Each test gets a fresh database via `setUp`.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/models/message.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/storage/vault_record.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database raw;
  late LocalDb db;

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
  });

  tearDown(() async {
    await raw.close();
  });

  group('messages', () {
    test('insertMessage + getMessage roundtrips a Message', () async {
      final msg = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'device-A',
        payload: Uint8List.fromList('hello'.codeUnits),
      );

      await db.insertMessage(msg);
      final loaded = await db.getMessage(msg.id);

      expect(loaded, isNotNull);
      expect(loaded, equals(msg));
    });

    test('getMessage returns null for unknown id', () async {
      expect(await db.getMessage('nope'), isNull);
    });

    test('listMessages respects limit and offset, newest first', () async {
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        final m = Message.create(
          mode: MessageMode.broadcast,
          type: MessageType.chat,
          channelId: 'public',
          senderId: 'device-A',
        );
        ids.add(m.id);
        await db.insertMessage(m);
        // Ensure a monotonic received_at; sqflite resolution is ms and the
        // loop is fast enough to collide otherwise.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final page = await db.listMessages(limit: 2, offset: 0);
      expect(page.length, 2);
      // Newest first → the most recently inserted id.
      expect(page.first.id, ids.last);

      final page2 = await db.listMessages(limit: 2, offset: 2);
      expect(page2.length, 2);
      expect(page2.first.id, ids[ids.length - 3]);
    });

    test('pruneOlderThan deletes only older messages', () async {
      final old = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'device-A',
      );
      await db.insertMessage(old);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final cutoff = DateTime.now().toUtc().millisecondsSinceEpoch + 1;
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final fresh = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'device-A',
      );
      await db.insertMessage(fresh);

      final removed = await db.pruneOlderThan(cutoff);
      expect(removed, 1);

      expect(await db.getMessage(old.id), isNull);
      expect(await db.getMessage(fresh.id), isNotNull);
    });
  });

  group('seen_cache', () {
    test('markSeen + isSeen roundtrip', () async {
      expect(await db.isSeen('id-1'), isFalse);
      await db.markSeen('id-1');
      expect(await db.isSeen('id-1'), isTrue);
    });

    test('markSeen is idempotent and preserves first_seen_at', () async {
      await db.markSeen('id-2');
      final firstRows = await raw.query(
        'seen_cache',
        where: 'id = ?',
        whereArgs: <Object?>['id-2'],
      );
      final firstTs = (firstRows.first['first_seen_at']! as num).toInt();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.markSeen('id-2');
      final secondRows = await raw.query(
        'seen_cache',
        where: 'id = ?',
        whereArgs: <Object?>['id-2'],
      );
      final secondTs = (secondRows.first['first_seen_at']! as num).toInt();
      expect(secondTs, equals(firstTs));
    });

    test('listSeenIds returns every marked id', () async {
      await db.markSeen('a');
      await db.markSeen('b');
      await db.markSeen('c');
      final ids = await db.listSeenIds();
      expect(ids.toSet(), <String>{'a', 'b', 'c'});
    });
  });

  group('vault_records', () {
    test('insertVaultRecord + listVaultRecords roundtrip', () async {
      final rec = VaultRecord(
        id: 'v-1',
        ciphertext: Uint8List.fromList(List<int>.generate(64, (i) => i)),
        createdAtMillis: 1700000000000,
        recipientId: 'verified-org-1',
        status: 'pending',
      );
      await db.insertVaultRecord(rec);

      final all = await db.listVaultRecords();
      expect(all.length, 1);
      expect(all.first, equals(rec));
    });

    test('listVaultRecords returns newest first', () async {
      for (final c in <VaultRecord>[
        VaultRecord(
          id: 'old',
          ciphertext: Uint8List(8),
          createdAtMillis: 1000,
          recipientId: '',
          status: 'pending',
        ),
        VaultRecord(
          id: 'newer',
          ciphertext: Uint8List(8),
          createdAtMillis: 2000,
          recipientId: '',
          status: 'pending',
        ),
      ]) {
        await db.insertVaultRecord(c);
      }

      final all = await db.listVaultRecords();
      expect(all.map((r) => r.id).toList(), <String>['newer', 'old']);
    });

    test('deleteVaultRecord removes the row', () async {
      final rec = VaultRecord(
        id: 'v-del',
        ciphertext: Uint8List.fromList([1, 2, 3]),
        createdAtMillis: 1,
        recipientId: '',
        status: 'draft',
      );
      await db.insertVaultRecord(rec);
      final removed = await db.deleteVaultRecord('v-del');
      expect(removed, 1);
      expect(await db.listVaultRecords(), isEmpty);
    });

    test('deleteVaultRecord on unknown id returns 0', () async {
      expect(await db.deleteVaultRecord('nope'), 0);
    });
  });
}