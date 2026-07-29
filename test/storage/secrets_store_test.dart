// RelayLink — Ticket #05 secrets store tests.
//
// Uses `FlutterSecureStorage.setMockInitialValues({...})` so the platform
// keychain is replaced with an in-memory map during tests — no real
// keychain access on the host CI runner.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/storage/secrets_store.dart';

void main() {
  late FlutterSecureStorage raw;
  late SecretsStore store;

  setUp(() {
    // Per-test reset so tests cannot leak state into each other.
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    raw = const FlutterSecureStorage();
    store = SecretsStore.withStorage(raw);
  });

  group('generic kv', () {
    test('getSecret returns null for unknown keys', () async {
      expect(await store.getSecret('nope'), isNull);
    });

    test('setSecret + getSecret roundtrip', () async {
      await store.setSecret('api.token', 'abc123');
      expect(await store.getSecret('api.token'), 'abc123');
    });

    test('setSecret(null) deletes the key', () async {
      await store.setSecret('api.token', 'abc123');
      await store.setSecret('api.token', null);
      expect(await store.getSecret('api.token'), isNull);
    });

    test('deleteSecret removes the key', () async {
      await store.setSecret('temp', 'value');
      await store.deleteSecret('temp');
      expect(await store.getSecret('temp'), isNull);
    });

    test('deleteSecret on missing key is a no-op', () async {
      await store.deleteSecret('missing');
      expect(await store.getSecret('missing'), isNull);
    });
  });

  group('identity bundle', () {
    test('getIdentity returns null when no bundle has been set', () async {
      expect(await store.getIdentity(), isNull);
    });

    test('setIdentity + getIdentity roundtrip', () async {
      const bundle = IdentityBundle(
        ed25519PrivateKeyB64: 'AAAA',
        ed25519PublicKeyB64: 'BBBB',
        x25519PrivateKeyB64: 'CCCC',
        x25519PublicKeyB64: 'DDDD',
      );
      await store.setIdentity(bundle);

      final loaded = await store.getIdentity();
      expect(loaded, isNotNull);
      expect(loaded, equals(bundle));
    });

    test('deleteIdentity removes the bundle', () async {
      await store.setIdentity(
        const IdentityBundle(
          ed25519PrivateKeyB64: 'A',
          ed25519PublicKeyB64: 'B',
          x25519PrivateKeyB64: 'C',
          x25519PublicKeyB64: 'D',
        ),
      );
      await store.deleteIdentity();
      expect(await store.getIdentity(), isNull);
    });

    test('getIdentity throws on malformed JSON', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        SecretsStore.identityBundleKey: 'not-json',
      });
      final localStore = SecretsStore.withStorage(
        const FlutterSecureStorage(),
      );
      await expectLater(localStore.getIdentity(), throwsFormatException);
    });

    test('getIdentity throws when keys are missing', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        SecretsStore.identityBundleKey:
            '{"ed25519_priv":"A","ed25519_pub":"B","x25519_priv":"C"}',
      });
      final localStore = SecretsStore.withStorage(
        const FlutterSecureStorage(),
      );
      await expectLater(localStore.getIdentity(), throwsFormatException);
    });
  });
}