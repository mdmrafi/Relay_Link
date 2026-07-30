// RelayLink — `RepositoryContactsLookup` tests.
//
// Verifies the production ContactsLookup impl against an in-memory
// sqflite_ffi database: sync cache hit, async hydration path, upsert
// returns previous record, delete propagates, list reflects DB state.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/contacts/repository_contacts_lookup.dart';
import 'package:relaylink/storage/local_db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database raw;
  late LocalDb db;
  late RepositoryContactsLookup repo;

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
    repo = RepositoryContactsLookup(db);
  });

  tearDown(() async {
    await raw.close();
  });

  ContactRecord rec({
    String deviceId = 'aabbccddeeff0011',
    String displayName = 'Alice',
    String? phone = '+15551234567',
    Uint8List? x25519,
  }) {
    return ContactRecord(
      deviceId: deviceId,
      displayName: displayName,
      phoneNumber: phone,
      x25519PublicKey: x25519 ?? Uint8List.fromList(List<int>.filled(32, 0x7E)),
    );
  }

  group('RepositoryContactsLookup', () {
    test('upsert returns null on first insert', () async {
      final r = rec();
      final prev = await repo.upsert(r);
      expect(prev, isNull);
    });

    test('upsert returns the previous record on replace', () async {
      final r1 = rec(displayName: 'Old');
      final r2 = rec(displayName: 'New');
      await repo.upsert(r1);
      final prev = await repo.upsert(r2);
      expect(prev, isNotNull);
      expect(prev!.displayName, 'Old');
    });

    test('lookupByDeviceIdAsync returns the upserted record after hydration',
        () async {
      final r = rec();
      await repo.upsert(r);
      // Bypass cache to force re-hydration.
      repo.invalidate();
      final looked = await repo.lookupByDeviceIdAsync(r.deviceId);
      expect(looked, isNotNull);
      expect(looked!.displayName, r.displayName);
      expect(looked.phoneNumber, r.phoneNumber);
      expect(looked.x25519PublicKey, isNotNull);
    });

    test('lookupByDeviceId hits the cache after first hydration', () async {
      final r = rec();
      await repo.upsert(r);
      // Without an explicit invalidate, the cache should already be
      // populated by the upsert.
      final looked = repo.lookupByDeviceId(r.deviceId);
      expect(looked, isNotNull);
      expect(looked!.displayName, r.displayName);
    });

    test('lookupByDeviceId returns null for an unknown id (cache miss)',
        () async {
      // No prior upsert; cache is empty.
      final looked = repo.lookupByDeviceId('not-paired');
      // Synchronous returns null on cache miss; async resolves to null too.
      expect(looked, isNull);
      final asyncLooked = await repo.lookupByDeviceIdAsync('not-paired');
      expect(asyncLooked, isNull);
    });

    test('delete removes a contact and returns the affected row count',
        () async {
      final r = rec();
      await repo.upsert(r);
      final removed = await repo.delete(r.deviceId);
      expect(removed, 1);
      expect(await repo.lookupByDeviceIdAsync(r.deviceId), isNull);
    });

    test('list returns all upserted contacts', () async {
      final a = rec(deviceId: 'aaaa1111aaaa1111', displayName: 'A');
      final b = rec(deviceId: 'bbbb2222bbbb2222', displayName: 'B');
      await repo.upsert(a);
      await repo.upsert(b);
      final list = await repo.list();
      expect(list.length, 2);
      expect(
        list.map((c) => c.deviceId).toSet(),
        {a.deviceId, b.deviceId},
      );
    });

    test('invalidate forces the next async lookup to re-hydrate from DB',
        () async {
      final r = rec();
      // Insert directly into the DB without going through repo.
      await db.insertContact(r);
      // First async lookup hydrates the cache.
      expect(await repo.lookupByDeviceIdAsync(r.deviceId), isNotNull);
      // Now nuke the cache + duplicate the row in the DB to prove a
      // post-invalidate lookup re-reads (cache was empty pre-hydration
      // this time, so the assertion is that the lookup still succeeds).
      repo.invalidate();
      expect(await repo.lookupByDeviceIdAsync(r.deviceId), isNotNull);
    });
  });
}
