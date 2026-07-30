// RelayLink — Ticket #20: Direct internet messaging (production transport).
//
// Pins the acceptance criteria for the production `InternetTransport`:
//   * `InternetTransport implements Transport`, `isAvailable()` returns
//     true iff device has internet.
//   * `send` writes to the correct collection per message mode/channel.
//   * Auto-poll loop runs every 30s when online; gracefully exits when
//     offline.
//   * Pulled messages are added to the seen-cache, TTL is decremented,
//     hop_count is incremented, and the message is re-broadcast via the
//     `TransportManager`.
//   * `start()`/`stop()` activate / deactivate the auto-poll; no toggle
//     needed.
//
// The test uses the same `FakeFirestoreGateway` pattern as the gateway
// relay test (ticket #22) so we exercise real wiring without the SDK.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/internet.dart';
import 'package:relaylink/transport/transport.dart';

/// Minimal `InternetSeenCache` for the production transport. Mirrors the
/// `SeenCache` used by SMS transport #26 and Gateway relay #22.
class _FakeSeenCache implements InternetSeenCache {
  final Set<String> _seen = <String>{};

  @override
  Future<bool> isSeen(String id) async => _seen.contains(id);

  @override
  Future<void> markSeen(String id) async {
    _seen.add(id);
  }

  Set<String> get seenIds => Set.unmodifiable(_seen);
}

/// Minimal `InternetTransportManagerHost` for re-broadcast tests.
class _FakeTransportManager implements InternetTransportManagerHost {
  final List<Message> rebroadcasts = <Message>[];

  @override
  Future<void> rebroadcast(Message msg) async {
    rebroadcasts.add(msg);
  }
}

/// In-memory `FirestoreGateway`. Records every push and lets tests enqueue
/// pull candidates directly into the per-poll slot.
class _FakeFirestoreGateway implements FirestoreGateway {
  final List<Message> pushed = <Message>[];

  /// Pending BROADCAST messages to deliver on the next pull.
  final List<Message> broadcastQueue = <Message>[];

  /// Pending DIRECT messages to deliver on the next pull.
  final List<Message> directQueue = <Message>[];

  /// Total broadcast pulls observed.
  int broadcastPulls = 0;

  /// Total direct pulls observed.
  int directPulls = 0;

  /// Throw on the next push to test error surfacing.
  bool throwOnPush = false;

  @override
  Future<void> pushMessage(Message msg) async {
    if (throwOnPush) {
      throwOnPush = false;
      throw const FirestoreGatewayUnavailable();
    }
    pushed.add(msg);
  }

  @override
  Future<List<Message>> pullBroadcastSince(
    DateTime since, {
    Set<String> channelIds = const <String>{},
  }) async {
    broadcastPulls++;
    final out = broadcastQueue.toList();
    broadcastQueue.clear();
    return out;
  }

  @override
  Future<List<Message>> pullDirectFor(
    String recipientId,
    DateTime since,
  ) async {
    directPulls++;
    final out = directQueue.toList();
    directQueue.clear();
    return out;
  }
}

Message _msg({
  required String id,
  required MessageMode mode,
  required MessageType type,
  String senderId = 'sender-1',
  String? recipientId,
  String channelId = 'public',
  int ttl = 8,
  int hopCount = 0,
  String origin = 'MESH',
}) {
  return Message(
    id: id,
    mode: mode,
    type: type,
    channelId: channelId,
    senderId: senderId,
    senderDisplayName: '',
    origin: MessageOrigin.fromJson(origin),
    recipientId: recipientId,
    payload: Uint8List.fromList('hello'.codeUnits),
    ratchetHeader: null,
    location: null,
    createdAt: DateTime.utc(2026, 7, 30, 12, 0, 0),
    ttl: ttl,
    hopCount: hopCount,
    signature: null,
    inResponseTo: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InternetTransport implements Transport', () {
    test('isA<Transport>()', () {
      final transport = InternetTransport(
        gateway: _FakeFirestoreGateway(),
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 30),
      );
      expect(transport, isA<Transport>());
    });

    test('name is "internet"', () {
      final transport = InternetTransport(
        gateway: _FakeFirestoreGateway(),
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
      );
      expect(transport.name, 'internet');
    });

    test('isAvailable() returns false by default (no internet)', () {
      final transport = InternetTransport(
        gateway: _FakeFirestoreGateway(),
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
      );
      expect(transport.isAvailable(), isFalse);
    });

    test('isAvailable() returns true after setAvailable(true)', () {
      final transport = InternetTransport(
        gateway: _FakeFirestoreGateway(),
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
      );
      transport.setAvailable(true);
      expect(transport.isAvailable(), isTrue);
      transport.setAvailable(false);
      expect(transport.isAvailable(), isFalse);
    });
  });

  group('InternetTransport.send', () {
    test('offline → throws TransportUnavailableException', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
      );
      expect(
        () => transport.send(_msg(
          id: 'a',
          mode: MessageMode.broadcast,
          type: MessageType.chat,
        )),
        throwsA(isA<TransportUnavailableException>()),
      );
      expect(fx.pushed, isEmpty);
    });

    test('BROADCAST → pushMessage called once', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
      );
      transport.setAvailable(true);
      await transport.send(_msg(
        id: 'a',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'aid-workers',
      ));
      expect(fx.pushed.length, 1);
      expect(fx.pushed.first.id, 'a');
      expect(fx.pushed.first.mode, MessageMode.broadcast);
      expect(fx.pushed.first.channelId, 'aid-workers');
    });

    test('DIRECT → pushMessage called once with the message intact', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
      );
      transport.setAvailable(true);
      await transport.send(_msg(
        id: 'b',
        mode: MessageMode.direct,
        type: MessageType.chat,
        recipientId: 'peer-2',
      ));
      expect(fx.pushed.length, 1);
      expect(fx.pushed.first.id, 'b');
      expect(fx.pushed.first.mode, MessageMode.direct);
      expect(fx.pushed.first.recipientId, 'peer-2');
    });
  });

  group('InternetTransport auto-poll lifecycle', () {
    test('start() runs a poll immediately when online', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 50),
      );
      transport.setAvailable(true);
      transport.start();
      // Pump the event loop so the immediate poll completes.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fx.broadcastPulls, greaterThanOrEqualTo(1),
          reason: 'first pull is fired synchronously from start()');
      expect(fx.directPulls, greaterThanOrEqualTo(1));
      await transport.stop();
    });

    test('poll runs on the configured interval while online', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 50),
      );
      transport.setAvailable(true);
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      // After ~180ms with a 50ms interval, expect at least 2-3 pulls.
      expect(fx.broadcastPulls, greaterThanOrEqualTo(2));
      await transport.stop();
    });

    test('offline: start() does not poll while _available=false', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 30),
      );
      // Do NOT call setAvailable(true) — device is offline.
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fx.broadcastPulls, 0,
          reason: 'no pulls should fire while offline');
      await transport.stop();
    });

    test('gracefully exits when connectivity drops mid-poll', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final pullsBefore = fx.broadcastPulls;
      expect(pullsBefore, greaterThan(0));
      // Simulate connectivity drop.
      transport.setAvailable(false);
      // Wait 3 intervals; pulls must NOT increment.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fx.broadcastPulls, pullsBefore);
      await transport.stop();
    });

    test('reactivates when connectivity returns', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fx.broadcastPulls, 0);
      transport.setAvailable(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fx.broadcastPulls, greaterThanOrEqualTo(1));
      await transport.stop();
    });

    test('start() is idempotent', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 50),
      );
      transport.setAvailable(true);
      transport.start();
      transport.start();
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Single timer; should be ~2 pulls after 100ms with a 50ms interval,
      // not 6. Generous upper bound: <= 5 to avoid timer edge-case flakes.
      expect(fx.broadcastPulls, lessThanOrEqualTo(5));
      await transport.stop();
    });

    test('stop() cancels the timer', () async {
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final pullsBefore = fx.broadcastPulls;
      expect(pullsBefore, greaterThan(0));
      await transport.stop();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fx.broadcastPulls, pullsBefore,
          reason: 'no further pulls after stop()');
    });
  });

  group('InternetTransport pull-side processing', () {
    test('BROADCAST pulled → seen-cache marked, TTL decremented, '
        'hop_count incremented, emitted, rebroadcast', () async {
      final fx = _FakeFirestoreGateway();
      final seen = _FakeSeenCache();
      final manager = _FakeTransportManager();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: seen,
        manager: manager,
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      final original = _msg(
        id: 'cast-1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'remote',
        channelId: 'public',
        ttl: 8,
        hopCount: 2,
      );
      fx.broadcastQueue.add(original);
      final emitted = <Message>[];
      final sub = transport.incoming.listen(emitted.add);
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Pump the loop a little more so the timer + queue drains.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen.seenIds, contains('cast-1'));
      expect(emitted.any((m) => m.id == 'cast-1'), isTrue);
      expect(manager.rebroadcasts.any((m) => m.id == 'cast-1'), isTrue);
      final r = manager.rebroadcasts.firstWhere((m) => m.id == 'cast-1');
      expect(r.ttl, 7, reason: 'TTL decremented on relay');
      expect(r.hopCount, 3, reason: 'hop_count incremented on relay');
      expect(r.origin, MessageOrigin.internet,
          reason: 'origin set to internet on relay');
      await sub.cancel();
      await transport.stop();
    });

    test('DIRECT pulled → seen-cache marked, TTL decremented, '
        'hop_count incremented, emitted, rebroadcast', () async {
      final fx = _FakeFirestoreGateway();
      final seen = _FakeSeenCache();
      final manager = _FakeTransportManager();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: seen,
        manager: manager,
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      final original = _msg(
        id: 'dir-1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        senderId: 'remote',
        recipientId: 'me',
        ttl: 10,
        hopCount: 1,
      );
      fx.directQueue.add(original);
      final emitted = <Message>[];
      final sub = transport.incoming.listen(emitted.add);
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen.seenIds, contains('dir-1'));
      expect(emitted.any((m) => m.id == 'dir-1'), isTrue);
      expect(manager.rebroadcasts.any((m) => m.id == 'dir-1'), isTrue);
      final r = manager.rebroadcasts.firstWhere((m) => m.id == 'dir-1');
      expect(r.ttl, 9);
      expect(r.hopCount, 2);
      expect(r.recipientId, 'me');
      await sub.cancel();
      await transport.stop();
    });

    test('duplicate id across polls → seen-cache hit, no double rebroadcast',
        () async {
      final fx = _FakeFirestoreGateway();
      final seen = _FakeSeenCache();
      final manager = _FakeTransportManager();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: seen,
        manager: manager,
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      final original = _msg(
        id: 'dup',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'remote',
      );
      fx.broadcastQueue
        ..add(original)
        ..add(original);
      final sub = transport.incoming.listen((_) {});
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        manager.rebroadcasts.where((m) => m.id == 'dup').length,
        1,
        reason: 'second occurrence should hit the seen-cache and be dropped',
      );
      expect(seen.seenIds, contains('dup'));
      await sub.cancel();
      await transport.stop();
    });

    test('pulled message with empty id is dropped, not rebroadcast', () async {
      final fx = _FakeFirestoreGateway();
      final seen = _FakeSeenCache();
      final manager = _FakeTransportManager();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: seen,
        manager: manager,
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      // Empty id → malformed envelope per spec §9 / Ticket #26 rules.
      fx.broadcastQueue.add(_msg(
        id: '',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'remote',
      ));
      final sub = transport.incoming.listen((_) {});
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(manager.rebroadcasts, isEmpty);
      await sub.cancel();
      await transport.stop();
    });

    test('pulled message with ttl <= 0 is dropped (no rebroadcast)',
        () async {
      final fx = _FakeFirestoreGateway();
      final seen = _FakeSeenCache();
      final manager = _FakeTransportManager();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: seen,
        manager: manager,
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      fx.broadcastQueue.add(_msg(
        id: 'expired',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'remote',
        ttl: 0,
      ));
      final sub = transport.incoming.listen((_) {});
      transport.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(manager.rebroadcasts.where((m) => m.id == 'expired'), isEmpty);
      await sub.cancel();
      await transport.stop();
    });
  });

  group('Gateway-relay integration (no behavior change)', () {
    test('pollStart/pollStop still drive an additional poll timer '
        '(compatibility with #22)', () async {
      // The #22 gateway relay uses pollStart() / pollStop() on the same
      // InternetTransport instance. Those methods must still drive a poll
      // loop (the gateway code path), independent of the auto-poll loop.
      final fx = _FakeFirestoreGateway();
      final transport = InternetTransport(
        gateway: fx,
        ownSenderId: 'me',
        seenCache: _FakeSeenCache(),
        manager: _FakeTransportManager(),
        pollInterval: const Duration(milliseconds: 30),
      );
      transport.setAvailable(true);
      transport.pollStart();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final pullsAfterGateway = fx.broadcastPulls;
      expect(pullsAfterGateway, greaterThan(0),
          reason: 'pollStart() must still drive pulls');
      transport.pollStop();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fx.broadcastPulls, pullsAfterGateway);
    });
  });
}
