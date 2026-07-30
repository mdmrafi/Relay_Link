// Tests for the public surface of InMemoryContactsStore.
//
// These tests pin down the four observable behaviors the SMS-DIRECT
// adapter (and any future caller) can rely on:
//   1. upsert on a fresh store returns null (no previous record).
//   2. upsert replaces an existing record AND returns the OLD record.
//   3. lookupByDeviceId resolves known ids and returns null for unknown.
//   4. length reflects the current count of stored records.

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/contacts/contacts_lookup.dart';

ContactRecord _record(String deviceId, {String? phone, String name = 'Alice'}) {
  return ContactRecord(
    deviceId: deviceId,
    displayName: name,
    x25519PublicKey: null,
    phoneNumber: phone,
  );
}

void main() {
  group('InMemoryContactsStore', () {
    test('upsert on a fresh store returns null (no previous record)', () {
      final store = InMemoryContactsStore(const []);
      final result = store.upsert(_record('device-a', phone: '+15551111111'));
      expect(result, isNull);
    });

    test('upsert replaces an existing record and returns the OLD record', () {
      final original = _record('device-b', phone: '+15552222222', name: 'Bob');
      final store = InMemoryContactsStore([original]);

      final updated = _record('device-b', phone: '+15559999999', name: 'Bob 2');
      final returned = store.upsert(updated);

      // upsert returns the OLD record, not the new one.
      expect(returned, equals(original));
      expect(returned, isNot(equals(updated)));

      // The store now holds the new record.
      expect(store.lookupByDeviceId('device-b'), equals(updated));
    });

    test('lookupByDeviceId returns the matching record and null for unknown',
        () {
      final alice = _record('device-alice', phone: '+15553333333');
      final bob = _record('device-bob', phone: '+15554444444');
      final store = InMemoryContactsStore([alice, bob]);

      expect(store.lookupByDeviceId('device-alice'), equals(alice));
      expect(store.lookupByDeviceId('device-bob'), equals(bob));
      expect(store.lookupByDeviceId('device-unknown'), isNull);
    });

    test('length reflects the count of stored records', () {
      final store = InMemoryContactsStore(const []);
      expect(store.length, 0);

      store.upsert(_record('device-1', phone: '+15551111111'));
      expect(store.length, 1);

      store.upsert(_record('device-2', phone: '+15552222222'));
      expect(store.length, 2);

      // Upserting an existing device-id must NOT increase the count.
      store.upsert(_record('device-1', phone: '+15559999999'));
      expect(store.length, 2);
    });
  });
}
