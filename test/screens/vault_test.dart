// RelayLink — Ticket #32: Vault UI widget tests.
//
// Covers the acceptance criteria from `.scratch/relaylink-build/issues/32-vault-ui.md`:
//
//   * Vault list shows metadata only (no plaintext preview)
//   * Empty state placeholder
//   * View screen decrypts and shows full plaintext
//   * Delete confirms before removing
//   * Compose screen has text input + recipient picker (contacts + Self)
//
// We wire a real `VaultStore` (via `VaultStore.create`) on top of an
// in-memory sqflite database and a fresh `DeviceIdentity`, so the UI is
// exercised against the actual encryption path (#31) rather than a mock.
// `flutter_test`'s widget tester gives us a real `Navigator`, so we can
// tap into the list, view, delete, and compose screens without additional
// scaffolding.
//
// Note on async: `flutter_test`'s `pumpAndSettle` drains the microtask
// queue but doesn't always wait for asynchronous platform channels.
// `sqflite_common_ffi` uses real OS-level awaitable primitives that need
// `tester.runAsync` to drive to completion. We use `runAsync` for any
// store mutation and the resulting rebuild.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/screens/vault.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/vault/store.dart';

const String _plaintextA = 'shoulder-surf-proof evidence A';
const String _plaintextB = 'shoulder-surf-proof evidence B';

/// Per-test fixtures. Wrapped in a small class so the build/teardown
/// helpers can carry the DB + identity + store around without leaning
/// on Dart's record-type sugar (which the analyzer's incremental parser
/// occasionally stumbles on in long files).
class _Fixtures {
  _Fixtures(this.raw, this.db, this.identity, this.store);
  final Database raw;
  final LocalDb db;
  final DeviceIdentity identity;
  final VaultStore store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<_Fixtures> buildFixtures(WidgetTester tester) async {
    final f = await tester.runAsync<_Fixtures>(() async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final identity = await DeviceIdentity.generate();
      await identity.save();
      final raw = await databaseFactory.openDatabase(
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
      final db = await LocalDb.withDatabase(raw);
      final store = await VaultStore.create(identity: identity, db: db);
      return _Fixtures(raw, db, identity, store);
    });
    return f!;
  }

  Future<void> disposeFixtures(WidgetTester tester, _Fixtures f) async {
    await tester.runAsync<void>(() async {
      await f.raw.close();
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
    });
  }

  Future<void> pumpVaultList(
    WidgetTester tester, {
    required VaultStore store,
    List<ContactRecord> contacts = const <ContactRecord>[],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VaultListScreen(store: store, contacts: contacts),
      ),
    );
    await tester.runAsync<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  group('VaultListScreen — empty state', () {
    testWidgets('shows the empty-state placeholder when no records exist',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await pumpVaultList(tester, store: f.store);

      expect(find.byKey(kVaultEmptyStateKey), findsOneWidget);
      expect(
        find.text('No evidence captured yet. Tap + to capture.'),
        findsOneWidget,
      );
      expect(find.byKey(kVaultListKey), findsNothing);
      expect(find.byKey(kVaultAddFabKey), findsOneWidget);
    });
  });

  group('VaultListScreen — list metadata', () {
    testWidgets('lists one row per record, metadata only — no plaintext',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.runAsync<void>(() async {
        await f.store.capture(_plaintextA);
        await f.store.capture(_plaintextB);
      });

      await pumpVaultList(tester, store: f.store);

      expect(find.byKey(kVaultEmptyStateKey), findsNothing);
      expect(find.byKey(kVaultListKey), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(2));

      // No plaintext leak in the list (acceptance criterion).
      expect(find.textContaining(_plaintextA), findsNothing);
      expect(find.textContaining(_plaintextB), findsNothing);
      expect(find.textContaining('shoulder-surf-proof'), findsNothing);

      expect(find.textContaining('status: pending'), findsNWidgets(2));
      expect(find.textContaining('recipient: self'), findsNWidgets(2));
      expect(find.textContaining('length:'), findsNWidgets(2));
    });

    testWidgets('shows recipient display name when a contact matches',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.runAsync<void>(() async {
        await f.store.capture(_plaintextA, 'device-id-1');
      });

      const contact = ContactRecord(
        deviceId: 'device-id-1',
        displayName: 'Alice',
        phoneNumber: '+15555550100',
        x25519PublicKey: null,
      );

      await pumpVaultList(
        tester,
        store: f.store,
        contacts: const <ContactRecord>[contact],
      );

      expect(
        find.textContaining('recipient: Alice'),
        findsOneWidget,
        reason: 'displayName must be used so the list is human-readable',
      );
      expect(find.textContaining('recipient: device-id-1'), findsNothing);
    });
  });

  group('VaultViewScreen — decrypt on tap', () {
    testWidgets('decrypts and displays the full plaintext when tapped',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.runAsync<void>(() async {
        await f.store.capture(_plaintextA);
      });

      await pumpVaultList(tester, store: f.store);

      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();

      expect(find.byKey(kVaultDecryptButtonKey), findsOneWidget);

      await tester.tap(find.byKey(kVaultDecryptButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kVaultPlaintextViewKey), findsOneWidget);
      expect(
        find.text(_plaintextA),
        findsOneWidget,
        reason: 'the full plaintext must appear in the view screen',
      );
      expect(find.byKey(kVaultListKey), findsNothing);
    });
  });

  group('VaultListScreen — delete with confirm', () {
    testWidgets('confirm dialog appears before any row is removed',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.runAsync<void>(() async {
        await f.store.capture(_plaintextA);
      });

      await pumpVaultList(tester, store: f.store);

      expect(find.byType(ListTile), findsOneWidget);

      await tester.tap(find.byKey(kVaultDeleteButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kVaultDeleteConfirmKey), findsOneWidget);
      expect(find.byKey(kVaultDeleteCancelKey), findsOneWidget);
      expect(find.text('Delete record?'), findsOneWidget);

      await tester.tap(find.byKey(kVaultDeleteCancelKey));
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsOneWidget);
      final remaining = (await tester
          .runAsync<List<VaultRecord>>(() => f.store.list()))!;
      expect(remaining, hasLength(1),
          reason: 'cancel must not delete the record');
    });

    testWidgets('confirming deletes the record from the store',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      late VaultRecord recA;
      await tester.runAsync<void>(() async {
        recA = await f.store.capture(_plaintextA);
        await f.store.capture(_plaintextB);
      });

      await pumpVaultList(tester, store: f.store);
      expect(find.byType(ListTile), findsNWidgets(2));

      await tester.tap(find.byKey(kVaultDeleteButtonKey).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kVaultDeleteConfirmKey));
      await tester.runAsync<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsOneWidget);
      final remaining = (await tester
          .runAsync<List<VaultRecord>>(() => f.store.list()))!;
      expect(remaining, hasLength(1));
      expect(remaining.first.id, equals(recA.id),
          reason: 'the OLDER record must remain after deleting the newer');
    });

    testWidgets('deleting the last record restores the empty state',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.runAsync<void>(() async {
        await f.store.capture(_plaintextA);
      });

      await pumpVaultList(tester, store: f.store);
      expect(find.byKey(kVaultListKey), findsOneWidget);

      await tester.tap(find.byKey(kVaultDeleteButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kVaultDeleteConfirmKey));
      await tester.runAsync<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      expect(find.byKey(kVaultListKey), findsNothing);
      expect(find.byKey(kVaultEmptyStateKey), findsOneWidget);
      final remaining = (await tester
          .runAsync<List<VaultRecord>>(() => f.store.list()))!;
      expect(remaining, isEmpty);
    });
  });

  group('VaultComposeScreen — text input + recipient picker', () {
    testWidgets('text input + recipient picker (Self + contacts) are visible',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      const alice = ContactRecord(
        deviceId: 'device-alice',
        displayName: 'Alice',
        phoneNumber: '+15555550100',
        x25519PublicKey: null,
      );
      const bob = ContactRecord(
        deviceId: 'device-bob',
        displayName: 'Bob',
        phoneNumber: '+15555550101',
        x25519PublicKey: null,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: VaultComposeScreen(
            store: f.store,
            contacts: const <ContactRecord>[alice, bob],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(kVaultComposeTextFieldKey), findsOneWidget);
      expect(find.byKey(kVaultComposeSubmitKey), findsOneWidget);
      expect(find.byKey(kVaultRecipientPickerKey), findsOneWidget);

      await tester.tap(find.byKey(kVaultRecipientPickerKey));
      await tester.pumpAndSettle();

      // The dropdown shows the selected value AND the menu items, so
      // use "at least" rather than "exactly one" for the picker entries.
      expect(find.text('Self'), findsAtLeastNWidgets(1));
      expect(find.text('Alice'), findsAtLeastNWidgets(1));
      expect(find.text('Bob'), findsAtLeastNWidgets(1));
    });

    testWidgets('submitting empty text does nothing',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.pumpWidget(
        MaterialApp(
          home: VaultComposeScreen(
            store: f.store,
            contacts: const <ContactRecord>[],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(kVaultComposeSubmitKey));
      await tester.pumpAndSettle();

      final remaining = (await tester
          .runAsync<List<VaultRecord>>(() => f.store.list()))!;
      expect(remaining, isEmpty);
      expect(find.byKey(kVaultComposeTextFieldKey), findsOneWidget);
    });

    testWidgets('submitting text with Self recipient persists a record',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await tester.pumpWidget(
        MaterialApp(
          home: VaultComposeScreen(
            store: f.store,
            contacts: const <ContactRecord>[],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(kVaultComposeTextFieldKey),
        _plaintextA,
      );
      await tester.tap(find.byKey(kVaultComposeSubmitKey));
      await tester.runAsync<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      final records = (await tester
          .runAsync<List<VaultRecord>>(() => f.store.list()))!;
      expect(records, hasLength(1));
      expect(records.first.recipientId, isNull,
          reason: 'Self should not bind a recipient device id');
    });
  });

  group('VaultListScreen — integration with the FAB → compose flow', () {
    testWidgets('tapping the FAB opens the compose screen',
        (WidgetTester tester) async {
      final f = await buildFixtures(tester);
      addTearDown(() => disposeFixtures(tester, f));

      await pumpVaultList(tester, store: f.store);

      await tester.tap(find.byKey(kVaultAddFabKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kVaultComposeTextFieldKey), findsOneWidget);
      expect(find.byKey(kVaultComposeSubmitKey), findsOneWidget);
      expect(find.byKey(kVaultRecipientPickerKey), findsOneWidget);
    });
  });

  group('formatVaultCreatedAt', () {
    test('returns yyyy-MM-dd HH:mm formatted string', () {
      final ts = DateTime.utc(2024, 1, 15, 12, 34, 0).millisecondsSinceEpoch;
      final formatted = formatVaultCreatedAt(ts);
      final expected = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      final expectedStr =
          '${expected.year.toString().padLeft(4, '0')}-${two(expected.month)}-'
          '${two(expected.day)} ${two(expected.hour)}:${two(expected.minute)}';
      expect(formatted, expectedStr);
      expect(formatted.length, 16);
    });
  });

  group('formatVaultCipherLength', () {
    test('formats byte count with a B suffix', () {
      expect(formatVaultCipherLength(0), '0 B');
      expect(formatVaultCipherLength(48), '48 B');
      expect(formatVaultCipherLength(1024), '1024 B');
    });
  });
}
