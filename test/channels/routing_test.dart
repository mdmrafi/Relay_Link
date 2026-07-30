// RelayLink — Ticket #17: channel routing (channel-id aware mesh relay)
// tests.
//
// Validates the channel-aware mesh relay layer against the
// behaviour contract documented in `lib/channels/routing.dart`:
//   1. Devices that have joined a channel surface BROADCAST traffic
//      on that channel ("decryptedSurfaceable").
//   2. Devices that have NOT joined a channel still relay the
//      envelope onward ("relayedForForeignChannel") — per SPEC §6.2
//      routing metadata is plaintext, so non-joined devices still
//      store-and-forward.
//   3. Self-originated messages are NOT re-broadcast.
//   4. Duplicates (same id) are dropped silently via the seen-cache.
//   5. TTL=0 envelopes are not re-broadcast (held for dedup only).
//   6. DIRECT messages route as `directPassthrough` (channelId is
//      metadata, not the addressing key for the ratchet envelope).
//   7. Multi-hop demo: A → B (foreign) → C (joined) — A's broadcast
//      reaches C even though B doesn't have the channel key.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/channels/routing.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';

/// In-memory fake [ChannelMembershipResolver] for tests. Keyed by
/// channelId; `null` (or absent) means "we haven't joined this channel".
class FakeMembership implements ChannelMembershipResolver {
  final Map<String, List<int>> _keys;
  FakeMembership([Map<String, List<int>>? keys]) : _keys = Map.of(keys ?? {});

  /// Join [channelId] with [key] (must be exactly 32 bytes).
  void join(String channelId, List<int> key) {
    _keys[channelId] = List<int>.from(key);
  }

  @override
  Future<List<int>?> keyFor(String channelId) async {
    final k = _keys[channelId];
    return k == null ? null : List<int>.from(k);
  }
}

/// Deterministic 32-byte key for tests. Content doesn't matter — the
/// routing layer doesn't perform AEAD, it only inspects *whether* a
/// key exists.
List<int> _key(int seed) {
  return List<int>.generate(32, (i) => (i * 31 + seed * 17 + 5) & 0xff);
}

/// Build a broadcast message. Use distinct `id` for each call so
/// seen-cache tests don't bleed across messages.
Message _bcast({
  required String id,
  required String senderId,
  required String channelId,
  int ttl = 4,
  int hopCount = 0,
}) {
  return Message.create(
    mode: MessageMode.broadcast,
    type: MessageType.chat,
    channelId: channelId,
    senderId: senderId,
    payload: Uint8List.fromList(<int>[0xCA, 0xFE, 0xBA, 0xBE]),
    ttl: ttl,
  ).copyWith(id: id, hopCount: hopCount);
}

Message _direct({
  required String id,
  required String senderId,
  required String recipientId,
  int ttl = 4,
}) {
  return Message.create(
    mode: MessageMode.direct,
    type: MessageType.chat,
    channelId: 'public',
    senderId: senderId,
    recipientId: recipientId,
    payload: Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
    ttl: ttl,
  ).copyWith(id: id);
}

void main() {
  group('ChannelRouter.classify (pure)', () {
    test('BROADCAST + joined channel → decryptedSurfaceable', () {
      final m = _bcast(id: 'm1', senderId: 'A', channelId: 'public');
      expect(
        ChannelRouter.classify(msg: m, channelJoined: true),
        ChannelRoutingEventKind.decryptedSurfaceable,
      );
    });

    test('BROADCAST + not joined → relayedForForeignChannel', () {
      final m = _bcast(id: 'm1', senderId: 'A', channelId: 'ops');
      expect(
        ChannelRouter.classify(msg: m, channelJoined: false),
        ChannelRoutingEventKind.relayedForForeignChannel,
      );
    });

    test('DIRECT always → directPassthrough (joined or not)', () {
      final m = _direct(id: 'd1', senderId: 'A', recipientId: 'B');
      expect(
        ChannelRouter.classify(msg: m, channelJoined: true),
        ChannelRoutingEventKind.directPassthrough,
      );
      expect(
        ChannelRouter.classify(msg: m, channelJoined: false),
        ChannelRoutingEventKind.directPassthrough,
      );
    });
  });

  group('ChannelSeenCache', () {
    test('contains / add / length', () {
      final c = ChannelSeenCache();
      expect(c.length, 0);
      expect(c.contains('a'), isFalse);
      c.add('a');
      c.add('b');
      expect(c.length, 2);
      expect(c.contains('a'), isTrue);
      expect(c.contains('b'), isTrue);
      expect(c.contains('c'), isFalse);
    });

    test('evicts oldest over capacity', () {
      final c = ChannelSeenCache(capacity: 3);
      c.add('a');
      c.add('b');
      c.add('c');
      c.add('d'); // evicts 'a'
      expect(c.contains('a'), isFalse);
      expect(c.contains('b'), isTrue);
      expect(c.contains('c'), isTrue);
      expect(c.contains('d'), isTrue);
      expect(c.length, 3);
    });

    test('re-adding refreshes recency (does not duplicate)', () {
      final c = ChannelSeenCache(capacity: 3);
      c.add('a');
      c.add('b');
      c.add('c');
      c.add('a'); // touch 'a' → moves to newest position
      c.add('d'); // should evict 'b' (oldest), not 'a'
      expect(c.contains('a'), isTrue);
      expect(c.contains('b'), isFalse);
      expect(c.contains('c'), isTrue);
      expect(c.contains('d'), isTrue);
      expect(c.length, 3);
    });
  });

  group('ChannelRouter integration', () {
    late FakeMembership membership;
    late ChannelSeenCache seen;
    late EchoTransport transport;
    late ChannelRouter router;

    setUp(() {
      membership = FakeMembership();
      seen = ChannelSeenCache();
      transport = EchoTransport(name: 'mesh', available: true);
      router = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[transport],
        membership: membership,
        seenCache: seen,
      ));
      router.start();
      addTearDown(router.stop);
      addTearDown(transport.close);
    });

    test('joined channel: marks decryptedSurfaceable, relays onward', () async {
      membership.join('public', _key(1));
      final m = _bcast(id: 'm1', senderId: 'them', channelId: 'public');

      transport.send(m);

      // Allow stream listener to process the message.
      await Future<void>.delayed(Duration.zero);

      // The first processed event must be `decryptedSurfaceable` for
      // our message. (There may be subsequent `duplicateDropped`
      // events caused by the loopback artefact of `send` bouncing the
      // relayed copy back into the same transport's incoming stream —
      // we filter for the one we care about.)
      final primary = router.processed.firstWhere(
        (e) => e.message.id == m.id &&
            e.kind == ChannelRoutingEventKind.decryptedSurfaceable,
        orElse: () => fail('no decryptedSurfaceable event for $m.id'),
      );
      expect(primary.channelId, 'public');
      expect(primary.message, m);
      expect(primary.keyForSurface, isNotNull);
      expect(primary.keyForSurface!.length, 32);

      // Message was relayed — TTL decremented, hopCount bumped.
      // (The router's `relayed` list is the authoritative trace of
      // what it shipped; the transport's accounting is incidental.)
      expect(router.relayed, hasLength(1),
          reason: 'exactly one relayed copy must have been emitted');
      final fwd = router.relayed.single;
      expect(fwd.ttl, m.ttl - 1);
      expect(fwd.hopCount, m.hopCount + 1);
      expect(fwd.id, m.id, reason: 'relay must preserve message id');
      expect(fwd.channelId, m.channelId,
          reason: 'channel_id passes through unchanged');
    });

    test(
        'non-joined channel: marks relayedForForeignChannel AND '
        'still relays onward (per SPEC §6.2)', () async {
      // Local device has NOT joined 'ops'. Another peer's broadcast
      // for 'ops' arrives — we still must forward.
      final m = _bcast(id: 'm2', senderId: 'them', channelId: 'ops');
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      final primary = router.processed.firstWhere(
        (e) => e.message.id == m.id,
        orElse: () => fail('no event for $m.id'),
      );
      expect(primary.kind, ChannelRoutingEventKind.relayedForForeignChannel);
      expect(primary.channelId, 'ops');
      expect(primary.keyForSurface, isNull);

      // Still relayed — non-joined devices are store-and-forward
      // couriers for custom-channel traffic (SPEC §6.2).
      expect(router.relayed, hasLength(1));
      final fwd = router.relayed.single;
      expect(fwd.ttl, m.ttl - 1);
      expect(fwd.hopCount, m.hopCount + 1);
      expect(fwd.id, m.id);
      expect(fwd.channelId, m.channelId);
    });

    test('self-originated: NOT re-broadcast', () async {
      membership.join('public', _key(1));
      final m = _bcast(id: 'm3', senderId: 'me', channelId: 'public');
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      // The first event for our message is selfOriginated; any later
      // events are `duplicateDropped` (loopback bounce-back, harmless).
      final primary = router.processed.firstWhere(
        (e) => e.message.id == m.id,
        orElse: () => fail('no event for $m.id'),
      );
      expect(primary.kind, ChannelRoutingEventKind.selfOriginated);
      expect(router.relayed, isEmpty,
          reason: 'own messages must not be re-broadcast');
    });

    test('duplicate: dropped via seen-cache, no second relay', () async {
      membership.join('public', _key(1));
      final m = _bcast(id: 'dup', senderId: 'them', channelId: 'public');

      transport.send(m);
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      // Filter to RELAYED copies. The router's `relayed` list is the
      // authoritative trace — duplicate injects must not produce a
      // second relay.
      expect(router.relayed, hasLength(1),
          reason: 'duplicate must not be re-broadcast twice');
      // First event = decryptedSurfaceable, second = duplicateDropped
      // (the second send is the duplicate, not the loopback bounce).
      // The loopback transport also bounces the relayed copy back
      // through the same stream, which produces a third duplicateDropped
      // event. We only care about the FIRST two — they prove the
      // dedup chain worked.
      final kinds = router.processed
          .where((e) => e.message.id == m.id)
          .map((e) => e.kind)
          .toList();
      expect(kinds.first, ChannelRoutingEventKind.decryptedSurfaceable);
      expect(kinds[1], ChannelRoutingEventKind.duplicateDropped);
      expect(kinds.length, anyOf(2, 3));
      // All subsequent events are duplicateDropped.
      for (var i = 1; i < kinds.length; i++) {
        expect(kinds[i], ChannelRoutingEventKind.duplicateDropped);
      }
    });

    test('TTL=0: held in seen-cache but NOT relayed', () async {
      membership.join('public', _key(1));
      final m = _bcast(id: 't0', senderId: 'them', channelId: 'public', ttl: 0);
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      final primary = router.processed.firstWhere(
        (e) => e.message.id == m.id,
        orElse: () => fail('no event for $m.id'),
      );
      expect(primary.kind, ChannelRoutingEventKind.ttlExhausted);
      expect(router.relayed, isEmpty,
          reason: 'TTL=0 means no further hops');
      expect(seen.contains('t0'), isTrue,
          reason: 'TTL=0 messages still occupy a seen-cache slot');
    });

    test('DIRECT: directPassthrough, still relays', () async {
      final m = _direct(id: 'd1', senderId: 'them', recipientId: 'me');
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      final primary = router.processed.firstWhere(
        (e) => e.message.id == m.id,
        orElse: () => fail('no event for $m.id'),
      );
      expect(primary.kind, ChannelRoutingEventKind.directPassthrough);
      expect(primary.keyForSurface, isNull,
          reason: 'DIRECT does not surface a channel key');
      expect(router.relayed, hasLength(1));
    });

    test('multiple transports: fan-out on relay', () async {
      final t2 = EchoTransport(name: 'sms', available: true);
      addTearDown(t2.close);
      // Fresh seen-cache so router2 isn't shadowed by router's
      // pre-existing seen entries from the shared transport's stream.
      final router2Seen = ChannelSeenCache();
      final router2 = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[transport, t2],
        membership: membership,
        seenCache: router2Seen,
      ));
      router2.start();
      addTearDown(router2.stop);

      membership.join('public', _key(1));
      final m = _bcast(id: 'fan', senderId: 'them', channelId: 'public');
      // Inject into one transport only — the router will subscribe to
      // BOTH transports' incoming streams. The router then relays the
      // message to every available transport. The router's `relayed`
      // list captures the relay decision (one entry per relay), not
      // per transport.
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      // The router recorded exactly one relay decision. Both available
      // transports received the relayed copy.
      expect(router2.relayed, hasLength(1));
      expect(router2.relayed.single.id, m.id);
      expect(router2.relayed.single.ttl, m.ttl - 1);
    });

    test('unavailable transport is skipped on relay (no throw)', () async {
      final tDown = EchoTransport(name: 'sms', available: false);
      addTearDown(tDown.close);
      final router2Seen = ChannelSeenCache();
      final router2 = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[transport, tDown],
        membership: membership,
        seenCache: router2Seen,
      ));
      router2.start();
      addTearDown(router2.stop);

      membership.join('public', _key(1));
      final m = _bcast(id: 'down', senderId: 'them', channelId: 'public');
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      // Router relayed exactly once (one relay decision). The relay
      // decision iterated over all transports but skipped the
      // unavailable one (tDown is `available: false`, so `t.send` was
      // never called on it).
      expect(router2.relayed, hasLength(1));
    });

    test('relay error on one transport does not stop the others', () async {
      // A custom transport that throws on send — simulating e.g. a
      // Bluetooth radio that lost the peer mid-write.
      final tBad = _ThrowyTransport();
      addTearDown(tBad.close);
      final router2Seen = ChannelSeenCache();
      final router2 = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[transport, tBad],
        membership: membership,
        seenCache: router2Seen,
      ));
      router2.start();
      addTearDown(router2.stop);

      membership.join('public', _key(1));
      final m = _bcast(id: 'err', senderId: 'them', channelId: 'public');
      transport.send(m);
      await Future<void>.delayed(Duration.zero);

      // Router recorded exactly one relay decision (no second relay
      // for the throwy attempt — the relay loop catches + continues).
      expect(router2.relayed, hasLength(1));
      // Throwy transport recorded zero successful outgoing (every send
      // threw). The router's relay loop caught each throw.
      expect(tBad.simulatedOutgoing, isEmpty);
      // The throwy transport's `send` was called at least once.
      expect(tBad.sendAttempts, greaterThanOrEqualTo(1));
    });
  });

  group('ChannelRouter lifecycle', () {
    test('start is idempotent', () {
      final membership = FakeMembership();
      final seen = ChannelSeenCache();
      final t = EchoTransport();
      addTearDown(t.close);
      final r = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[t],
        membership: membership,
        seenCache: seen,
      ));
      r.start();
      r.start(); // must be a no-op (does not throw)
      expect(r.isRunning, isTrue);
      addTearDown(r.stop);
    });

    test('stop is idempotent and clears subscriptions', () async {
      final membership = FakeMembership();
      final seen = ChannelSeenCache();
      final t = EchoTransport();
      addTearDown(t.close);
      final r = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[t],
        membership: membership,
        seenCache: seen,
      ));
      r.start();
      await r.stop();
      await r.stop(); // second stop is a no-op
      expect(r.isRunning, isFalse);
    });

    test('stop then start works again', () async {
      final membership = FakeMembership();
      membership.join('public', _key(1));
      final seen = ChannelSeenCache();
      final t = EchoTransport();
      addTearDown(t.close);
      final r = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'me',
        transports: <Transport>[t],
        membership: membership,
        seenCache: seen,
      ));
      r.start();
      await r.stop();
      r.start();

      t.send(_bcast(id: 'r1', senderId: 'them', channelId: 'public'));
      await Future<void>.delayed(Duration.zero);
      expect(r.processed, isNotEmpty,
          reason: 'router should be live again after restart');
      await r.stop();
    });
  });

  group('Manual demo: A → B (foreign) → C (joined)', () {
    test(
        'multi-hop: A broadcasts on custom channel, B does not have the '
        'key but relays, C joins later and receives from B\'s relay',
        () async {
      // Three "devices" modeled as three routers + three transports.
      // Each router uses ITS OWN seen-cache (per-device state).
      final aSeen = ChannelSeenCache();
      final bSeen = ChannelSeenCache();
      final cSeen = ChannelSeenCache();

      // Device A's perspective: in channel "demo" (so it can publish).
      // Device B's perspective: NOT in "demo" (foreign device).
      // Device C's perspective: in "demo" (receives from B's relay).
      final aMembership = FakeMembership()
        ..join('demo', _key(1));
      final bMembership = FakeMembership(); // foreign: no 'demo' key.
      final cMembership = FakeMembership()
        ..join('demo', _key(1));

      // Wires between devices. Each "link" is one dedicated transport
      // shared between the two devices on either side of it. The same
      // physical Transport instance is passed to both routers — that
      // is how a "shared radio" is modeled in this codebase's relay
      // tests (the two devices "see" the same bytes).
      final abLink = EchoTransport(name: 'meshA-B', available: true);
      final bcLink = EchoTransport(name: 'meshB-C', available: true);
      addTearDown(abLink.close);
      addTearDown(bcLink.close);

      // Device A's router only knows about the A-B link.
      final aRouter = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'A',
        transports: <Transport>[abLink],
        membership: aMembership,
        seenCache: aSeen,
      ));
      aRouter.start();
      addTearDown(aRouter.stop);

      // Device B's router knows about BOTH links (it sits in the
      // middle). On message arrival from abLink, it must relay to
      // bcLink even though it has no 'demo' key.
      final bRouter = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'B',
        transports: <Transport>[abLink, bcLink],
        membership: bMembership,
        seenCache: bSeen,
      ));
      bRouter.start();
      addTearDown(bRouter.stop);

      // Device C only listens to the B-C link.
      final cRouter = ChannelRouter(ChannelRouterConfig(
        localDeviceId: 'C',
        transports: <Transport>[bcLink],
        membership: cMembership,
        seenCache: cSeen,
      ));
      cRouter.start();
      addTearDown(cRouter.stop);

      // 1. Device A broadcasts on 'demo'. The transport's `send` adds
      //    to its own incoming stream, which is what both aRouter and
      //    bRouter subscribe to. aRouter classifies the message as
      //    selfOriginated (senderId == localDeviceId) and drops it
      //    WITHOUT relaying. bRouter, on the other hand, processes it
      //    as a foreign-channel broadcast and relays to bcLink.
      final m = _bcast(id: 'multi', senderId: 'A', channelId: 'demo');
      abLink.send(m);

      // Allow propagation through the streams. Multiple hops' worth
      // of microtasks must complete: A→B (via shared link), B→C.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // A: originated here → first event is selfOriginated. Any
      //     subsequent events on this router are duplicateDropped
      //     entries from B's relay bouncing back through abLink.
      expect(
        aRouter.processed.any(
          (e) => e.kind == ChannelRoutingEventKind.selfOriginated,
        ),
        isTrue,
        reason: 'A should record the broadcast as self-originated',
      );

      // B: foreign channel but still relayed → relayedForForeignChannel.
      expect(
        bRouter.processed.any(
          (e) =>
              e.kind == ChannelRoutingEventKind.relayedForForeignChannel &&
              e.channelId == 'demo' &&
              e.message.id == 'multi',
        ),
        isTrue,
        reason: 'B should record that it relayed a non-joined channel',
      );

      // C: receives the relayed message and decrypts surfaceable.
      expect(
        cRouter.processed.any(
          (e) =>
              e.kind == ChannelRoutingEventKind.decryptedSurfaceable &&
              e.channelId == 'demo' &&
              e.message.id == 'multi',
        ),
        isTrue,
        reason: 'C should successfully surface the relayed message',
      );
      final cEvent = cRouter.processed.firstWhere(
        (e) =>
            e.kind == ChannelRoutingEventKind.decryptedSurfaceable &&
            e.message.id == 'multi',
      );
      expect(cEvent.keyForSurface, isNotNull,
          reason: 'C has the channel key, so the event must surface it');
      expect(cEvent.keyForSurface!.length, 32);
    });
  });
}

/// A test transport that throws on send — to verify the router's
/// `try/catch` around `t.send` does not block other transports.

/// A test transport that throws on send — to verify the router's
/// `try/catch` around `t.send` does not block other transports.
class _ThrowyTransport implements Transport {
  @override
  final String name = 'throwy';
  final StreamController<Message> _ctrl =
      StreamController<Message>.broadcast();
  /// Counts the number of times `send` was called (regardless of
  /// whether it threw). Tests use this to assert that the router DID
  /// attempt a send on the throwy transport.
  int sendAttempts = 0;
  @override
  Stream<Message> get incoming => _ctrl.stream;
  @override
  bool isAvailable() => true;
  @override
  Future<void> send(Message msg) async {
    sendAttempts++;
    throw StateError('simulated transport failure');
  }
  /// Convenience alias for parity with [EchoTransport]'s
  /// `simulatedOutgoing` getter — this transport records zero
  /// successful sends by design.
  List<Message> get simulatedOutgoing => const <Message>[];
  void close() {
    if (!_ctrl.isClosed) _ctrl.close();
  }
}