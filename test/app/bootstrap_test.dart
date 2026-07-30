// RelayLink — `bootstrapServices` smoke test.
//
// Verifies that the wiring-gap-closure bootstrap constructs every
// long-lived singleton and registers the expected transports. Uses
// an in-memory sqflite database for `LocalDb` (via `dbOverride`) and a
// mocked `FlutterSecureStorage` for `DeviceIdentity.loadOrGenerate()`.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/app/bootstrap.dart';
import 'package:relaylink/storage/local_db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database raw;
  late LocalDb db;

  setUp(() async {
    LocalDb.resetForTesting();
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
  });

  tearDown(() async {
    await raw.close();
    await FlutterSecureStorage().deleteAll();
  });

  test('bootstrapServices wires every singleton', () async {
    final bootstrap = await bootstrapServices(dbOverride: db);
    addTearDown(() async {
      await bootstrap.dispose();
    });

    expect(bootstrap.db, isNotNull);
    expect(bootstrap.identity, isNotNull);
    expect(bootstrap.directSessionStore, isNotNull);
    expect(bootstrap.transportManager, isNotNull);
    expect(bootstrap.broadcastCrypto, isNotNull);
    expect(bootstrap.contactsLookup, isNotNull);
    expect(bootstrap.messageDecryptor, isNotNull);
    expect(bootstrap.remoteChatController, isNotNull);
    expect(bootstrap.channelKeyStore, isNotNull);

    // TransportManager should always register mesh, sms, internet. Echo
    // is gated on `--dart-define=DEV_LOOPBACK=true` so we don't assert
    // it here.
    final names = bootstrap.transportManager.transports.map((t) => t.name).toSet();
    expect(names, containsAll(<String>{'mesh', 'SMS', 'internet'}));
  });

  test('bootstrapServices produces a consistent identity across calls',
      () async {
    final a = await bootstrapServices(dbOverride: db);
    // Capture identity before dispose — the DB will be closed by dispose.
    final idA = a.identity.senderId;
    final pubA = a.identity.x25519PublicKeyBytes;

    // Construct a fresh in-memory DB for the second call so the close
    // from `a.dispose()` doesn't affect `b`.
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
    final b = await bootstrapServices(dbOverride: db2);
    addTearDown(() async {
      await a.dispose();
      await b.dispose();
    });

    // The second call returns a fresh BootstrapResult but the
    // DeviceIdentity.loadOrGenerate() should resolve to the same
    // identity (persisted in secure storage).
    expect(b.identity.senderId, idA);
    expect(b.identity.x25519PublicKeyBytes, pubA);
  });
}
