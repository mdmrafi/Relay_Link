// RelayLink — `DirectSessionStore` tests.
//
// Verifies secure-storage-backed persistence: put/get round-trip,
// schema-corrupt payload rejection, delete, list, broadcast stream.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:relaylink/crypto/direct.dart';
import 'package:relaylink/crypto/direct_session_store.dart';

void main() {
  late DirectSessionStore store;
  late FlutterSecureStorage storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = const FlutterSecureStorage();
    store = DirectSessionStore(storage);
  });

  tearDown(() async {
    await store.close();
    await storage.deleteAll();
  });

  // Helper: build a fresh session to persist. Avoids depending on a
  // real ECDH bootstrap in the test — just use a deterministic seed.
  Future<DirectSession> sampleSession({int sendCounter = 0, int recvCounter = 0}) async {
    // 32 bytes of zeros — fine for storage round-trips; the ratchet
    // isn't exercised here.
    final seed = List<int>.filled(32, 0x42);
    return DirectSession.fromChainKey(
      seed,
      isInitiator: true,
      nextMessageIndex: sendCounter,
    );
  }

  group('DirectSessionStore', () {
    test('get returns null for an unknown device id', () async {
      expect(await store.get('unknown'), isNull);
    });

    test('get returns null for an empty device id', () async {
      expect(await store.get(''), isNull);
    });

    test('put → get round-trips a session', () async {
      final session = await sampleSession();
      await store.put('aabbccddeeff0011', session);
      final loaded = await store.get('aabbccddeeff0011');
      expect(loaded, isNotNull);
      // Compare via JSON — DirectSession has no equality override.
      expect(loaded!.toJson(), session.toJson());
    });

    test('put on the same id overwrites', () async {
      final s1 = await sampleSession(sendCounter: 3);
      final s2 = await sampleSession(sendCounter: 7);
      await store.put('id-1', s1);
      await store.put('id-1', s2);
      final loaded = await store.get('id-1');
      expect(loaded, isNotNull);
      expect(loaded!.toJson(), s2.toJson());
    });

    test('delete removes the persisted session', () async {
      final session = await sampleSession();
      await store.put('id-2', session);
      expect(await store.get('id-2'), isNotNull);
      final removed = await store.delete('id-2');
      expect(removed, isTrue);
      expect(await store.get('id-2'), isNull);
    });

    test('delete on unknown id returns false', () async {
      expect(await store.delete('never-paired'), isFalse);
    });

    test('delete on empty id returns false without touching storage',
        () async {
      expect(await store.delete(''), isFalse);
    });

    test('listDeviceIds returns all paired ids', () async {
      final s = await sampleSession();
      await store.put('aaaa1111aaaa1111', s);
      await store.put('bbbb2222bbbb2222', s);
      final ids = await store.listDeviceIds();
      expect(ids.toSet(), {'aaaa1111aaaa1111', 'bbbb2222bbbb2222'});
    });

    test('deviceIds stream emits on put and delete', () async {
      final events = <String>[];
      final sub = store.deviceIds.listen(events.add);
      // Pump event loop so the broadcast subscription is registered
      // before we start mutating.
      await Future<void>.delayed(Duration.zero);

      final s = await sampleSession();
      await store.put('id-stream', s);
      await Future<void>.delayed(Duration.zero);
      await store.delete('id-stream');
      await Future<void>.delayed(Duration.zero);

      expect(events, contains('id-stream'));
      expect(events.length, 2); // one put + one delete
      await sub.cancel();
    });

    test('get throws on a corrupt (non-JSON) persisted value', () async {
      await storage.write(
        key: '${kDirectSessionStorePrefix}corrupt-id',
        value: 'not json at all',
      );
      // FormatException from jsonDecode.
      expect(
        () => store.get('corrupt-id'),
        throwsA(isA<FormatException>()),
      );
    });

    test('get throws on a JSON blob with the wrong schema version',
        () async {
      await storage.write(
        key: '${kDirectSessionStorePrefix}wrong-version',
        value: '{"v":999,"send_chain":"AAAA","send_counter":0,'
            '"recv_chain":"AAAA","recv_counter":0,"initiator_tag":1}',
      );
      expect(
        () => store.get('wrong-version'),
        throwsA(isA<FormatException>()),
      );
    });

    test('singleton instance() returns the same object across calls', () {
      DirectSessionStore.resetForTesting();
      final a = DirectSessionStore.instance();
      final b = DirectSessionStore.instance();
      expect(identical(a, b), isTrue);
      DirectSessionStore.resetForTesting();
    });
  });
}
