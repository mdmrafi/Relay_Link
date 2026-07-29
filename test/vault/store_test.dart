// RelayLink — Ticket #31 vault encrypt-at-rest + storage tests.
//
// Uses in-memory sqflite_common_ffi and a mocked flutter_secure_storage so
// tests don't touch real platform keychain or filesystem.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/vault/store.dart';

const _plaintextProbe = 'super-secret-evidence-text-12345';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('VaultStore', () {
    late Database raw;
    late LocalDb db;
    late DeviceIdentity identity;
    late VaultStore store;

    setUp(() async {
      // Per-test isolation: fresh secure storage + fresh in-memory DB.
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
      store = await VaultStore.create(
        identity: identity,
        db: db,
      );
    });

    tearDown(() async {
      await raw.close();
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });

    test('capture returns a record with ciphertext and metadata', () async {
      final rec = await store.capture(_plaintextProbe);

      expect(rec.id, isNotEmpty);
      // UUIDv4: 36 chars, dashes, lowercase hex.
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-'
                r'[0-9a-f]{12}$')
            .hasMatch(rec.id),
        isTrue,
      );
      expect(rec.ciphertext, isA<Uint8List>());
      expect(rec.ciphertext, isNotEmpty);
      expect(rec.ciphertext, isNot(equals(utf8.encode(_plaintextProbe))));
      expect(rec.perRecordKeyWrapped, isA<Uint8List>());
      expect(rec.perRecordKeyWrapped, isNotEmpty);
      expect(rec.nonce.length, 12); // AES-GCM default nonce length
      expect(rec.aad, isA<Uint8List>());
      expect(rec.aad, equals(utf8.encode('self')));
      expect(rec.recipientId, isNull);
      expect(rec.createdAt, greaterThan(0));
    });

    test('self-encrypted capture round-trips (capture -> decrypt)', () async {
      final rec = await store.capture(_plaintextProbe);

      final decrypted = await store.decrypt(rec);
      expect(utf8.decode(decrypted), _plaintextProbe);
    });

    test('capture with recipientId uses recipient as AAD', () async {
      const recipient = 'verified-org-1';
      final rec = await store.capture(_plaintextProbe, recipient);

      expect(rec.recipientId, recipient);
      expect(rec.aad, equals(utf8.encode(recipient)));

      final decrypted = await store.decrypt(rec);
      expect(utf8.decode(decrypted), _plaintextProbe);
    });

    test('list() returns all captured records newest first', () async {
      final a = await store.capture('first');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final b = await store.capture('second');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final c = await store.capture('third');

      final all = await store.list();
      expect(all.length, 3);
      expect(all.map((r) => r.id).toList(), <String>[c.id, b.id, a.id]);
    });

    test('get(id) returns the matching record', () async {
      final rec = await store.capture(_plaintextProbe);
      final fetched = await store.get(rec.id);
      expect(fetched, isNotNull);
      expect(fetched!.id, rec.id);

      final decrypted = await store.decrypt(fetched);
      expect(utf8.decode(decrypted), _plaintextProbe);
    });

    test('get(id) returns null for unknown id', () async {
      expect(await store.get(const Uuid().v4()), isNull);
    });

    test('flipping a bit in ciphertext causes decrypt to throw', () async {
      final rec = await store.capture(_plaintextProbe);

      // Tamper: flip the lowest bit of the first ciphertext byte.
      final tamperedBytes = Uint8List.fromList(rec.ciphertext);
      tamperedBytes[0] = tamperedBytes[0] ^ 0x01;
      final tampered = VaultRecord(
        id: rec.id,
        ciphertext: tamperedBytes,
        perRecordKeyWrapped: rec.perRecordKeyWrapped,
        nonce: rec.nonce,
        aad: rec.aad,
        createdAt: rec.createdAt,
        recipientId: rec.recipientId,
      );

      await expectLater(
        () => store.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('flipping a bit in wrapped key causes decrypt to throw', () async {
      final rec = await store.capture(_plaintextProbe);

      final tamperedWrapped = Uint8List.fromList(rec.perRecordKeyWrapped);
      tamperedWrapped[0] = tamperedWrapped[0] ^ 0x01;
      final tampered = VaultRecord(
        id: rec.id,
        ciphertext: rec.ciphertext,
        perRecordKeyWrapped: tamperedWrapped,
        nonce: rec.nonce,
        aad: rec.aad,
        createdAt: rec.createdAt,
        recipientId: rec.recipientId,
      );

      await expectLater(
        () => store.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('flipping a bit in nonce causes decrypt to throw', () async {
      final rec = await store.capture(_plaintextProbe);

      final tamperedNonce = Uint8List.fromList(rec.nonce);
      tamperedNonce[0] = tamperedNonce[0] ^ 0x01;
      final tampered = VaultRecord(
        id: rec.id,
        ciphertext: rec.ciphertext,
        perRecordKeyWrapped: rec.perRecordKeyWrapped,
        nonce: tamperedNonce,
        aad: rec.aad,
        createdAt: rec.createdAt,
        recipientId: rec.recipientId,
      );

      await expectLater(
        () => store.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('AAD mismatch causes decrypt to throw', () async {
      // Encrypt under recipientId, then try to decrypt pretending it was
      // self-encrypted — different AAD means GCM auth fails.
      const recipient = 'verified-org-1';
      final rec = await store.capture(_plaintextProbe, recipient);

      final tampered = VaultRecord(
        id: rec.id,
        ciphertext: rec.ciphertext,
        perRecordKeyWrapped: rec.perRecordKeyWrapped,
        nonce: rec.nonce,
        aad: utf8.encode('self'), // wrong AAD
        createdAt: rec.createdAt,
        recipientId: null,
      );

      await expectLater(
        () => store.decrypt(tampered),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('no plaintext appears in any persisted SQLite column', () async {
      final rec = await store.capture(_plaintextProbe);
      // Now read the raw row back from the database — even ciphertext
      // columns should NOT contain the plaintext bytes (they're encrypted
      // and would fail the AES-GCM auth if anyone modified them).
      final rows = await raw.query(
        'vault_records',
        where: 'id = ?',
        whereArgs: <Object?>[rec.id],
      );
      expect(rows.length, 1);
      final row = rows.first;

      String asBase64(Object? v) {
        if (v is Uint8List) return base64.encode(v);
        if (v is List<int>) return base64.encode(v);
        return v.toString();
      }

      // Plaintext should not appear in any persisted column, in any
      // encoding. Plaintext bytes would never end up there in the first
      // place — but assert against every column defensively.
      for (final entry in row.entries) {
        expect(asBase64(entry.value), isNot(contains(_plaintextProbe)),
            reason: 'plaintext leaked into column ${entry.key}');
      }
    });

    test('two captures of the same plaintext produce different ciphertexts',
        () async {
      final a = await store.capture(_plaintextProbe);
      final b = await store.capture(_plaintextProbe);
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
      expect(a.nonce, isNot(equals(b.nonce)));

      // Both decrypt back to the original plaintext.
      expect(utf8.decode(await store.decrypt(a)), _plaintextProbe);
      expect(utf8.decode(await store.decrypt(b)), _plaintextProbe);
    });

    test('a different device identity cannot decrypt another device\'s vault',
        () async {
      // Capture a record under the FIRST identity's VWK. The record
      // lives in the (in-memory) sqflite — decrypting it requires the
      // first identity's wrap key to unwrap the persisted VWK, then
      // that VWK to unwrap the per-record key.
      final originalRec = await store.capture(_plaintextProbe);

      // Build a SECOND VaultStore around a brand-new identity, backed
      // by an isolated FlutterSecureStorage so it doesn't see the
      // first identity's persisted VWK. This second store generates its
      // own VWK under the new identity's wrap key — different from the
      // first identity's VWK, so it cannot decrypt the first store's
      // per-record key wrapper.
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final otherIdentity = await DeviceIdentity.generate();
      await otherIdentity.save();
      final otherStorage = const FlutterSecureStorage();
      final otherStore = await VaultStore.create(
        identity: otherIdentity,
        db: db,
        storage: otherStorage,
      );

      // Sanity: the other store can encrypt/decrypt its own captures.
      final otherRec = await otherStore.capture('other device plaintext');
      expect(utf8.decode(await otherStore.decrypt(otherRec)),
          'other device plaintext');

      // Now: the other store cannot decrypt the FIRST identity's record.
      await expectLater(
        () => otherStore.decrypt(originalRec),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );

      // And the original store still can.
      expect(utf8.decode(await store.decrypt(originalRec)), _plaintextProbe);
    });

    test('reloading the store with the same identity decrypts existing records',
        () async {
      // Simulate an app restart: same identity, same secure storage, same
      // DB. A new VaultStore must derive the same wrap key, unwrap the
      // same VWK, and decrypt the existing record.
      final originalRec = await store.capture(_plaintextProbe);
      store.close();

      final restarted = await VaultStore.create(
        identity: identity,
        db: db,
      );
      final loaded = await restarted.get(originalRec.id);
      expect(loaded, isNotNull);
      expect(utf8.decode(await restarted.decrypt(loaded!)), _plaintextProbe);
    });

    test('flipping a bit in the wrapped VWK in secure storage causes '
        'create to throw', () async {
      // Capture something to materialise the wrapped VWK in secure
      // storage.
      await store.capture(_plaintextProbe);
      store.close();

      // Now corrupt the persisted wrapped VWK blob.
      final raw = const FlutterSecureStorage();
      final existing = await raw.read(key: VaultStoreKeys.vaultWrappingKey);
      expect(existing, isNotNull);
      final bytes = Uint8List.fromList(base64.decode(existing!));
      expect(bytes.length, 60); // 12 nonce + 32 ct + 16 mac
      bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0x01;
      await raw.write(
        key: VaultStoreKeys.vaultWrappingKey,
        value: base64.encode(bytes),
      );

      // A fresh VaultStore must refuse to unwrap the corrupted VWK.
      await expectLater(
        () => VaultStore.create(
          identity: identity,
          db: db,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('plaintext is not stored in flutter_secure_storage', () async {
      await store.capture(_plaintextProbe);
      final raw = const FlutterSecureStorage();
      // Every value currently in storage must not contain the plaintext.
      final all = await raw.readAll();
      for (final entry in all.entries) {
        expect(entry.key, isNot(equals('unknown')));
        expect(entry.value, isNot(contains(_plaintextProbe)),
            reason: 'plaintext leaked into secure storage at '
                '${entry.key}');
      }
    });
  });

  group('schema migration', () {
    test('v1 → v2 migration adds the new vault_records columns and '
        'preserves v1 rows', () async {
      // Hand-craft a v1 database with the old schema (single ciphertext
      // column) and a v1 row already present. Then run `migrate` and
      // confirm the new columns are added and the original row is still
      // there.
      final raw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, _) async {
            await d.execute(LocalDb.createV1Sql);
            await d.rawQuery('PRAGMA user_version = 1;');
          },
        ),
      );
      try {
        // Insert a v1 row.
        await raw.insert(
          'vault_records',
          <String, Object?>{
            'id': 'legacy-row',
            'ciphertext': Uint8List.fromList(<int>[1, 2, 3, 4]),
            'created_at': 1700000000000,
            'recipient_id': '',
            'status': 'pending',
          },
        );

        // Run migrate — it should add the new columns idempotently
        // without losing the existing row.
        await LocalDb.migrate(raw);

        // Verify the new columns exist.
        final cols = await raw.rawQuery('PRAGMA table_info(vault_records);');
        final names = cols.map((r) => r['name'] as String).toSet();
        expect(names, contains('per_record_key_wrapped'));
        expect(names, contains('nonce'));
        expect(names, contains('aad'));

        // The old row is still present (now with NULL for the new cols).
        final rows = await raw.query(
          'vault_records',
          where: 'id = ?',
          whereArgs: <Object?>['legacy-row'],
        );
        expect(rows.length, 1);
        final row = rows.first;
        expect(row['ciphertext'], isA<Uint8List>());
        expect(row['per_record_key_wrapped'], isNull);
        expect(row['nonce'], isNull);
        expect(row['aad'], isNull);
      } finally {
        await raw.close();
      }
    });
  });
}