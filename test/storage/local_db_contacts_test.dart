// RelayLink — `LocalDb.contacts` table tests (schema v3).
//
// Verifies the new contacts table introduced by the wiring-gap-closure
// plan: round-trip insert/get, list returns newest first, delete removes
// a row, and upsert replaces.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/storage/local_db.dart';

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

  ContactRecord sampleRecord({
    String deviceId = 'aabbccddeeff0011',
    String displayName = 'Alice',
    String? phone = '+15551234567',
  }) {
    return ContactRecord(
      deviceId: deviceId,
      displayName: displayName,
      phoneNumber: phone,
      x25519PublicKey: Uint8List.fromList(List<int>.filled(32, 0xAB)),
    );
  }

  ContactRecord sampleRecordNoCrypto({
    String deviceId = 'aabbccddeeff0011',
    String displayName = 'Alice',
    String? phone = '+15551234567',
  }) {
    return ContactRecord(
      deviceId: deviceId,
      displayName: displayName,
      phoneNumber: phone,
      x25519PublicKey: null,
    );
  }

  group('LocalDb contacts (schema v3)', () {
    test('schemaVersion is 3', () {
      expect(LocalDb.schemaVersion, 3);
    });

    test('migrate creates the contacts table on a fresh database', () async {
      final rows = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='contacts';",
      );
      expect(rows, isNotEmpty);
    });

    test('insertContact + getContact round-trips a record', () async {
      final rec = sampleRecord();
      await db.insertContact(rec);
      final loaded = await db.getContact(rec.deviceId);
      expect(loaded, isNotNull);
      expect(loaded, equals(rec));
    });

    test('getContact returns null for unknown id', () async {
      expect(await db.getContact('not-paired'), isNull);
    });

    test('insertContact replaces an existing row with the same device_id',
        () async {
      final first = sampleRecord(displayName: 'Old');
      final second = sampleRecord(displayName: 'New', phone: '+15559999999');
      await db.insertContact(first);
      await db.insertContact(second);
      final loaded = await db.getContact(first.deviceId);
      expect(loaded, isNotNull);
      expect(loaded!.displayName, 'New');
      expect(loaded.phoneNumber, '+15559999999');
    });

    test('listContacts returns newest first', () async {
      final a = sampleRecord(deviceId: 'aaaa1111aaaa1111', displayName: 'A');
      final b = sampleRecord(deviceId: 'bbbb2222bbbb2222', displayName: 'B');
      await db.insertContact(a);
      // Force a monotonic paired_at timestamp.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.insertContact(b);

      final list = await db.listContacts();
      expect(list.length, 2);
      expect(list.first.deviceId, b.deviceId);
      expect(list.last.deviceId, a.deviceId);
    });

    test('insertContact preserves nullable phone_number and x25519', () async {
      final rec = sampleRecordNoCrypto(phone: null);
      await db.insertContact(rec);
      final loaded = await db.getContact(rec.deviceId);
      expect(loaded, isNotNull);
      expect(loaded!.phoneNumber, isNull);
      expect(loaded.x25519PublicKey, isNull);
    });

    test('deleteContact removes a paired row', () async {
      final rec = sampleRecord();
      await db.insertContact(rec);
      expect(await db.getContact(rec.deviceId), isNotNull);
      final removed = await db.deleteContact(rec.deviceId);
      expect(removed, 1);
      expect(await db.getContact(rec.deviceId), isNull);
    });

    test('deleteContact returns 0 for an unknown id', () async {
      expect(await db.deleteContact('not-paired'), 0);
    });
  });
}
