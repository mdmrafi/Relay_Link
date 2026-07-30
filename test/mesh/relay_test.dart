// RelayLink — Mesh relay layer tests (Ticket #09).
//
// Covers the relay's four acceptance criteria:
//   * TTL decrement + drop at TTL=0
//   * Seen-cache per-message-id dedup
//   * Bounded LRU eviction
//   * Self-originated messages still go through seen-cache so neighbor
//     re-broadcasts do not echo back.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/mesh/relay.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';

Message _mkMessage({
  String id = 'msg-1',
  int ttl = 4,
  int hopCount = 0,
  String senderId = 'peer-A',
  MessageType type = MessageType.chat,
  MessageMode mode = MessageMode.broadcast,
}) {
  return Message.create(
    mode: mode,
    type: type,
    channelId: 'public',
    senderId: senderId,
    payload: Uint8List.fromList('hi'.codeUnits),
    ttl: ttl,
  ).copyWith(id: id, hopCount: hopCount);
}

/// Emits a message onto its [incoming] stream when `inject` is called,
/// captures everything sent via `send`. Used as the mesh peer transport in
/// these tests.
class _CapturingTransport implements Transport {
  _CapturingTransport({this.name = 'mesh', this.available = true});

  @override
  final String name;
  bool available;
  final List<Message> sent = <Message>[];

  final StreamController<Message> _ctrl =
      StreamController<Message>.broadcast();

  @override
  Stream<Message> get incoming => _ctrl.stream;

  @override
  bool isAvailable() => available;

  @override
  Future<void> send(Message msg) async {
    if (!_ctrl.isClosed) {
      sent.add(msg);
      _ctrl.add(msg);
    }
  }

  void inject(Message msg) {
    if (!_ctrl.isClosed) _ctrl.add(msg);
  }

  Future<void> close() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}

Future<void> _settle() async {
  // Two microtask flushes is enough for relay `_handle()` -> `send()` chain
  // to play out without needing arbitrary sleeps.
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('LruSeenCache', () {
    test('add + contains returns true; eviction removes oldest at cap', () {
      final cache = LruSeenCache(capacity: 3);
      expect(cache.contains('a'), isFalse);
      cache.add('a');
      cache.add('b');
      cache.add('c');
      expect(cache.contains('a'), isTrue);
      expect(cache.contains('b'), isTrue);
      expect(cache.contains('c'), isTrue);
      expect(cache.length, 3);

      // Exceed cap by one — 'a' (oldest) must be evicted.
      cache.add('d');
      expect(cache.length, 3);
      expect(cache.contains('a'), isFalse,
          reason: 'oldest entry should have been evicted');
      expect(cache.contains('b'), isTrue);
      expect(cache.contains('c'), isTrue);
      expect(cache.contains('d'), isTrue);
    });

    test('re-adding an existing entry refreshes recency (true LRU)', () {
      final cache = LruSeenCache(capacity: 3);
      cache.add('a');
      cache.add('b');
      cache.add('c');
      // Touch 'a' so it becomes the most recent; 'b' is now oldest.
      expect(cache.add('a'), isFalse, reason: '"a" was already present');
      cache.add('d');
      expect(cache.contains('a'), isTrue, reason: '"a" was touched');
      expect(cache.contains('b'), isFalse,
          reason: '"b" should have been evicted as oldest');
    });

    test('capacity <= 0 clamps to a minimum of 1 and still evicts', () {
      final cache = LruSeenCache(capacity: 0);
      // Capacity clamps to 1, so the second `add` evicts the first.
      cache.add('x');
      expect(cache.contains('x'), isTrue);
      cache.add('y');
      expect(cache.contains('y'), isTrue);
      expect(cache.contains('x'), isFalse,
          reason: 'capacity clamps to 1 so the oldest entry must evict');
      expect(cache.length, 1);

      cache.add('z');
      expect(cache.contains('y'), isFalse);
      expect(cache.contains('z'), isTrue);
    });
  });

  group('MeshRelay — TTL decrement', () {
    test('re-broadcasts with ttl-1 and hopCount+1', () async {
      final mesh = _CapturingTransport();
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: LruSeenCache(capacity: 100),
        transports: <Transport>[mesh],
      );
      await relay.start();

      final original = _mkMessage(id: 'm1', ttl: 3, hopCount: 0);
      mesh.inject(original);

      // The transport's incoming stream will see both the injected
      // message and the relay's forwarded message. We want the forwarded
      // one — assert on the relay's send captures directly.
      await _settle();
      expect(mesh.sent.length, 1,
          reason: 'relay should have re-broadcast exactly once');
      final forwarded = mesh.sent.first;
      expect(forwarded.id, 'm1');
      expect(forwarded.ttl, 2);
      expect(forwarded.hopCount, 1);
      expect(forwarded.senderId, 'peer-A');

      await relay.stop();
      await mesh.close();
    });

    test('drops at TTL=0 without re-broadcasting', () async {
      final mesh = _CapturingTransport();
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: LruSeenCache(capacity: 100),
        transports: <Transport>[mesh],
      );
      await relay.start();

      mesh.inject(_mkMessage(id: 'm-depleted', ttl: 0));
      // Wait long enough for the relay to have processed the incoming;
      // then assert nothing was sent and nothing leaked to `incoming`.
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(mesh.sent, isEmpty,
          reason: 'TTL=0 messages must not be re-broadcast');

      await relay.stop();
      await mesh.close();
    });

    test('forwarded message preserves id, mode, sender, channel', () async {
      final mesh = _CapturingTransport();
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: LruSeenCache(capacity: 100),
        transports: <Transport>[mesh],
      );
      await relay.start();

      final original = _mkMessage(
        id: 'm-preserve',
        ttl: 2,
        hopCount: 5,
        senderId: 'peer-Z',
        mode: MessageMode.direct,
        type: MessageType.sos,
      );
      mesh.inject(original);

      await _settle();
      expect(mesh.sent.length, 1);
      final forwarded = mesh.sent.first;
      expect(forwarded.id, 'm-preserve');
      expect(forwarded.mode, MessageMode.direct);
      expect(forwarded.type, MessageType.sos);
      expect(forwarded.senderId, 'peer-Z');
      expect(forwarded.ttl, 1);
      expect(forwarded.hopCount, 6);
      expect(forwarded.channelId, 'public');

      await relay.stop();
      await mesh.close();
    });
  });

  group('MeshRelay — seen-cache dedup', () {
    test('does not re-broadcast a message id that is already in the cache',
        () async {
      final mesh = _CapturingTransport();
      final cache = LruSeenCache(capacity: 100);
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: cache,
        transports: <Transport>[mesh],
      );
      await relay.start();

      // Pre-seed the cache as if we'd seen it before.
      cache.add('m-already-seen');

      // Inject a message with that id; the loopback will see its own send
      // (mesh = loopback in this test transport), but relay must drop
      // because id is already in the cache.
      mesh.inject(_mkMessage(id: 'm-already-seen', ttl: 5));

      // Wait long enough for the relay to have processed the incoming.
      await _settle();
      expect(mesh.sent, isEmpty,
          reason: 'relay must drop messages whose id is in the seen-cache');

      await relay.stop();
      await mesh.close();
    });

    test('first sighting is re-broadcast once; a second identical '
        'incoming only re-broadcasts the first time', () async {
      final mesh = _CapturingTransport();
      final cache = LruSeenCache(capacity: 100);
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: cache,
        transports: <Transport>[mesh],
      );
      await relay.start();

      mesh.inject(_mkMessage(id: 'm-once', ttl: 4));
      await _settle();
      expect(mesh.sent.length, 1,
          reason: 'first sighting should have re-broadcast exactly once');

      // Inject the same id again — relay must drop because it was just
      // marked seen by the first pass.
      mesh.inject(_mkMessage(id: 'm-once', ttl: 4));
      await _settle();
      expect(mesh.sent.length, 1,
          reason: 'second sighting must not re-broadcast');

      await relay.stop();
      await mesh.close();
    });
  });

  group('MeshRelay — LRU eviction', () {
    test('seen cache evicts the oldest entry when capacity is exceeded',
        () async {
      final cache = LruSeenCache(capacity: 2);
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: cache,
        transports: <Transport>[_CapturingTransport()],
      );
      await relay.start();

      cache.add('first');
      cache.add('second');
      cache.add('third');
      expect(cache.contains('first'), isFalse,
          reason: 'LRU should evict "first" once capacity is exceeded');
      expect(cache.contains('second'), isTrue);
      expect(cache.contains('third'), isTrue);

      await relay.stop();
    });
  });

  group('MeshRelay — self-originated messages', () {
    test('marks own messages seen but does not re-broadcast', () async {
      final mesh = _CapturingTransport();
      final cache = LruSeenCache(capacity: 100);
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: cache,
        transports: <Transport>[mesh],
      );
      await relay.start();

      final ownMsg = _mkMessage(id: 'mine', ttl: 8, senderId: 'me');
      mesh.inject(ownMsg);

      await _settle();
      expect(mesh.sent, isEmpty,
          reason: 'self-originated messages must not be re-broadcast');
      expect(cache.contains('mine'), isTrue,
          reason: 'self-originated messages still go through the seen-cache');

      // Now a neighbor echoes the same id (e.g. via another transport).
      // The relay must drop it without a re-broadcast of its own.
      mesh.inject(_mkMessage(id: 'mine', ttl: 7, senderId: 'peer-B'));
      await _settle();
      expect(mesh.sent, isEmpty,
          reason: 'echo of own id from a neighbor must not loop back');

      await relay.stop();
      await mesh.close();
    });
  });

  group('MeshRelay — multi-transport fan-out', () {
    test('forwards to all available transports, skips unavailable ones',
        () async {
      final t1 = _CapturingTransport(name: 'one');
      final t2 = _CapturingTransport(name: 'two', available: false);
      final t3 = _CapturingTransport(name: 'three');
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: LruSeenCache(capacity: 100),
        transports: <Transport>[t1, t2, t3],
      );
      await relay.start();

      // Inject on t1; relay should send only on t1 and t3.
      t1.inject(_mkMessage(id: 'm-fan', ttl: 2));
      await _settle();

      expect(t1.sent.length, 1);
      expect(t2.sent, isEmpty,
          reason: 'unavailable transport must not be used');
      expect(t3.sent.length, 1);

      // Drain t2's stream so its subscriber path doesn't dangle.
      await relay.stop();
      await t1.close();
      await t2.close();
      await t3.close();
    });
  });

  group('MeshRelay — lifecycle', () {
    test('start then stop cleanly cancels subscriptions', () async {
      final mesh = _CapturingTransport();
      final relay = MeshRelay(
        localDeviceId: 'me',
        seenCache: LruSeenCache(capacity: 100),
        transports: <Transport>[mesh],
      );
      await relay.start();
      await relay.stop();

      // After stop(), further injections must NOT cause any re-broadcast.
      mesh.inject(_mkMessage(id: 'after-stop', ttl: 4));
      await _settle();
      expect(mesh.sent, isEmpty);

      await mesh.close();
    });
  });
}

// (no extra sentinel needed — tests assert on `mesh.sent` instead of on a
// timeout-based future.)
