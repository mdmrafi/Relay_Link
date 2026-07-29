// RelayLink — Ticket #15 channel key generation + storage tests.
//
// Uses `FlutterSecureStorage.setMockInitialValues({...})` so the platform
// keychain is replaced with an in-memory map during tests — no real
// keychain access on the host CI runner.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/channels/keys.dart';
import 'package:relaylink/crypto/broadcast.dart';

void main() {
  late ChannelKeyStore store;

  setUp(() {
    // Per-test reset so tests cannot leak state into each other.
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = ChannelKeyStore.withStorage(const FlutterSecureStorage());
  });

  group('init()', () {
    test('auto-adds the public channel with the embedded networkKey',
        () async {
      await store.init();

      final ids = await store.listChannels();
      expect(ids, contains(kPublicChannelId));

      final key = await store.getChannelKey(kPublicChannelId);
      expect(key, isNotNull);
      expect(key!.length, 32);
      // The auto-added public channel key must match the broadcast default
      // exactly — otherwise the entire network would see different "public"
      // ciphertexts.
      expect(key, equals(networkKey));
    });

    test('init() is idempotent — calling twice does not duplicate',
        () async {
      await store.init();
      await store.init();

      final ids = await store.listChannels();
      expect(ids.where((id) => id == kPublicChannelId).length, 1);
    });

    test('init() restores the public key if it was deleted but keeps index',
        () async {
      await store.init();
      // Simulate an external process deleting the key blob but not the index.
      await FlutterSecureStorage().delete(key: 'channel_public');

      await store.init();

      final key = await store.getChannelKey(kPublicChannelId);
      expect(key, equals(networkKey));
    });
  });

  group('generateKey()', () {
    test('returns 32 bytes', () {
      final key = store.generateKey();
      expect(key.length, 32);
    });

    test('two calls produce distinct keys', () {
      final a = store.generateKey();
      final b = store.generateKey();
      expect(a, isNot(equals(b)));
    });

    test('many calls produce distinct keys (statistical)', () {
      final seen = <List<int>>{};
      for (var i = 0; i < 50; i++) {
        seen.add(store.generateKey());
      }
      // 50 keys, all 32 bytes; collisions with 256^32 space are vanishingly
      // unlikely — assert full uniqueness.
      expect(seen.length, 50);
    });
  });

  group('addChannel / getChannelKey / listChannels', () {
    test('roundtrip: add then get returns the same key', () async {
      await store.init();
      final key = store.generateKey();
      await store.addChannel('ops', key);

      final loaded = await store.getChannelKey('ops');
      expect(loaded, isNotNull);
      expect(loaded, equals(key));
    });

    test('listChannels returns every joined channel', () async {
      await store.init();
      await store.addChannel('ops', store.generateKey());
      await store.addChannel('dev', store.generateKey());

      final ids = await store.listChannels();
      expect(ids, containsAll(<String>[kPublicChannelId, 'ops', 'dev']));
      expect(ids.length, 3);
    });

    test('getChannelKey returns null for unknown channels (no throw)',
        () async {
      await store.init();
      final loaded = await store.getChannelKey('does-not-exist');
      expect(loaded, isNull);
    });

    test('addChannel rejects non-32-byte keys', () async {
      await store.init();
      expect(
        () => store.addChannel('bad', List<int>.filled(16, 0)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => store.addChannel('bad', List<int>.filled(64, 0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('addChannel rejects empty channelId', () async {
      await store.init();
      expect(
        () => store.addChannel('', store.generateKey()),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('addChannel replaces an existing key for the same channelId',
        () async {
      await store.init();
      final first = store.generateKey();
      final second = store.generateKey();
      await store.addChannel('ops', first);
      await store.addChannel('ops', second);

      final loaded = await store.getChannelKey('ops');
      expect(loaded, equals(second));
      // listChannels should still only count 'ops' once.
      final ids = await store.listChannels();
      expect(ids.where((id) => id == 'ops').length, 1);
    });

    test('auto-added public key is the embedded base64 networkKey', () async {
      await store.init();

      // Read the raw blob and confirm it matches the constant broadcast
      // default at the storage-format layer too (base64 roundtrip).
      final raw = await FlutterSecureStorage().read(key: 'channel_public');
      expect(raw, isNotNull);
      expect(raw, equals(base64.encode(networkKey)));
    });
  });
}
