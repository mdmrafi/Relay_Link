// RelayLink — unit tests for MirrorRelayStrategy (Ticket #48 / spec §2).
//
// The strategy is the seam between a peer's incoming stream and the
// relay decision (seen-cache dedup → TTL decrement → hopCount++ →
// re-broadcast). These tests pin that contract at the smallest possible
// surface: one strategy instance + one discovery + two fake peers —
// no harness.
//
// We assert each behavior in isolation, red-first. Each test wires a
// fresh LoopbackMeshDiscovery so broadcast targets are observable via
// the peer's `transport.incoming` stream.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/bloom.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';

import 'loopback_mesh_discovery.dart';
import 'mirror_relay_strategy.dart';

void main() {
  group('MirrorRelayStrategy', () {
    late LoopbackMeshDiscovery discovery;
    late LoopbackTransport tA;
    late LoopbackTransport tB;
    late BloomFilter bloom;

    setUp(() {
      discovery = LoopbackMeshDiscovery(
        deliveryLatency: Duration.zero,
        jitter: Duration.zero,
      );
      tA = LoopbackTransport(name: 'peer-A');
      tB = LoopbackTransport(name: 'peer-B');
      discovery.register('peer-A', (m) {
        if (tA.isAvailable()) tA.send(m);
      });
      discovery.register('peer-B', (m) {
        if (tB.isAvailable()) tB.send(m);
      });
      bloom = BloomFilter.empty();
    });

    tearDown(() {
      tA.close();
      tB.close();
      discovery.close();
    });

    test(
      'onIncoming returns the decremented message and broadcasts it; '
      'second identical message returns null (dedup)',
      () async {
        final strategy = MirrorRelayStrategy(discovery: discovery);
        final msg = Message.create(
          mode: MessageMode.broadcast,
          type: MessageType.chat,
          channelId: 'public',
          senderId: 'peer-X',
          payload: Uint8List(0),
          ttl: 3,
        );

        // First delivery to peer-A: must return decremented message +
        // broadcast to peer-B (peer-A is the sender in the broadcast
        // context, so it does NOT receive its own relay back).
        final received = <Message>[];
        final sub = tB.incoming.listen(received.add);
        final first = strategy.onIncoming(
          peerId: 'peer-A',
          msg: msg,
          seenCache: bloom,
        );
        // Drain microtasks so the synchronous broadcast lands.
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(first, isNotNull);
        expect(first!.ttl, msg.ttl - 1);
        expect(first.hopCount, msg.hopCount + 1);
        expect(received, hasLength(1));
        expect(received.first.id, msg.id);

        // Second delivery of the same id: seen-cache hit → null, no broadcast.
        strategy.duplicateDropCount; // sanity: counter accessor exists for future use
        final receivedAfterDup = <Message>[];
        final sub2 = tB.incoming.listen(receivedAfterDup.add);
        final second = strategy.onIncoming(
          peerId: 'peer-A',
          msg: msg,
          seenCache: bloom,
        );
        await Future<void>.delayed(Duration.zero);
        await sub2.cancel();

        expect(second, isNull);
        expect(receivedAfterDup, isEmpty);
      },
    );

    test(
      'onIncoming with ttl: 0 returns null and does NOT broadcast',
      () async {
        final strategy = MirrorRelayStrategy(discovery: discovery);
        final msg = Message.create(
          mode: MessageMode.broadcast,
          type: MessageType.chat,
          channelId: 'public',
          senderId: 'peer-X',
          payload: Uint8List(0),
          ttl: 0,
        );

        final received = <Message>[];
        final sub = tA.incoming.listen(received.add);
        final result = strategy.onIncoming(
          peerId: 'peer-A',
          msg: msg,
          seenCache: bloom,
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(result, isNull);
        expect(received, isEmpty);
      },
    );

    test(
      'onIncoming with ttl: 3 returns a copy with ttl: 2 and hopCount + 1',
      () async {
        final strategy = MirrorRelayStrategy(discovery: discovery);
        final msg = Message.create(
          mode: MessageMode.broadcast,
          type: MessageType.chat,
          channelId: 'public',
          senderId: 'peer-X',
          payload: Uint8List(0),
          ttl: 3,
        );

        // Drain any broadcast noise so we can isolate the onIncoming return.
        final sub = tA.incoming.listen((_) {});
        final result = strategy.onIncoming(
          peerId: 'peer-A',
          msg: msg,
          seenCache: bloom,
        );
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(result, isNotNull);
        expect(result!.ttl, 2);
        expect(result.hopCount, msg.hopCount + 1);
        // Identity: must be a copy, not the same instance.
        expect(identical(result, msg), isFalse);
        expect(result.id, msg.id);
      },
    );

    test(
      'originate causes discovery.broadcast to fire to all other registered '
      'peers',
      () async {
        final strategy = MirrorRelayStrategy(discovery: discovery);
        final msg = Message.create(
          mode: MessageMode.broadcast,
          type: MessageType.chat,
          channelId: 'public',
          senderId: 'peer-X',
          payload: Uint8List(0),
          ttl: 3,
        );

        final seenAtA = <Message>[];
        final seenAtB = <Message>[];
        final subA = tA.incoming.listen(seenAtA.add);
        final subB = tB.incoming.listen(seenAtB.add);

        strategy.originate(senderId: 'peer-X', msg: msg);

        await Future<void>.delayed(Duration.zero);
        await subA.cancel();
        await subB.cancel();

        // peer-X is the sender → not in either peer's broadcast list.
        // peer-A and peer-B are both recipients.
        expect(seenAtA, hasLength(1));
        expect(seenAtB, hasLength(1));
        expect(seenAtA.first.id, msg.id);
        expect(seenAtB.first.id, msg.id);
      },
    );
  });
}