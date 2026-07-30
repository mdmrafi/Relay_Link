// Tests for the Bloom-filter peer-sync (Ticket #11).
//
// The harness simulates two devices. Each device has:
//   * a `PeerSync` (local Bloom + message store)
//   * a `LoopbackPeerChannel` whose `remote` is the *other* device's loopback
//
// `sendMessage` on one loopback lands on the *other* loopback's relay
// inbox, mirroring the BLE behavior of two devices on the same link.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/bloom.dart';
import 'package:relaylink/mesh/peer_sync.dart';
import 'package:relaylink/models/message.dart';

/// In-memory peer channel. Two of these are wired together (`a.remote = b`,
/// `b.remote = a`) so anything one side sends lands in the other's inbox.
class LoopbackPeerChannel implements PeerChannel {
  LoopbackPeerChannel({this.name = 'loop', this.remote});

  final String name;
  LoopbackPeerChannel? remote;

  /// Active sessions, in connect-order. The loopback channel can multiplex
  /// multiple concurrent sessions (tests typically use one); control
  /// frames are delivered to the most recently connected session.
  final List<LoopbackPeerSession> _activeSessions = <LoopbackPeerSession>[];

  /// Public stream of Message envelopes delivered by the *remote side*.
  /// Tests subscribe to this on the receiver to see what got pushed.
  final StreamController<Message> incomingRelay =
      StreamController<Message>.broadcast();

  /// All messages we've sent via `sendMessage` — i.e. the payload side of
  /// the sync. Most-recent last.
  final List<Message> sentMessages = <Message>[];

  /// All control envelopes we've sent via `sendControl`. Most-recent last.
  final List<PeerSyncEnvelope> sentControls = <PeerSyncEnvelope>[];

  /// Counter for envelopes delivered to `incoming` on a session.
  int receivedEnvelopeCount = 0;

  @override
  Future<PeerSession> connect() async {
    final session = LoopbackPeerSession(this);
    _activeSessions.add(session);
    return session;
  }

  @override
  Future<void> sendMessage(Message msg) async {
    sentMessages.add(msg);
    final r = remote;
    if (r != null && !r.incomingRelay.isClosed) {
      r.incomingRelay.add(msg);
    }
  }

  /// Used by the loopback session to forward a control envelope to us.
  /// Delivers to all live sessions — the most recent one is the "current"
  /// handshake, but the loopback is permissive for symmetry.
  void deliverControl(PeerSyncEnvelope env) {
    receivedEnvelopeCount++;
    for (final session in _activeSessions) {
      session.deliver(env);
    }
  }

  /// Test helper: drop a session from the active list (called from
  /// `LoopbackPeerSession.close`).
  void _dropSession(LoopbackPeerSession session) {
    _activeSessions.remove(session);
  }
}

class LoopbackPeerSession implements PeerSession {
  LoopbackPeerSession(this._channel);
  final LoopbackPeerChannel _channel;

  /// The controller. Default (single-subscription) so any envelopes
  /// added before a listener attaches are queued and replayed on
  /// listen. This is critical for the bloom handshake where one side
  /// may `sendControl` before the other has gotten to `.listen`.
  StreamController<PeerSyncEnvelope>? _ctrl;

  @override
  Stream<PeerSyncEnvelope> get incoming {
    final ctrl = _ctrl ??= StreamController<PeerSyncEnvelope>();
    return ctrl.stream;
  }

  @override
  Future<void> sendControl(PeerSyncEnvelope env) async {
    _channel.sentControls.add(env);
    final remote = _channel.remote;
    if (remote != null) {
      remote.deliverControl(env);
    }
  }

  @override
  Future<void> close() async {
    _channel._dropSession(this);
    final ctrl = _ctrl;
    if (ctrl != null && !ctrl.isClosed) {
      await ctrl.close();
    }
  }

  /// Test channel-side helper: enqueue an envelope for delivery.
  void deliver(PeerSyncEnvelope env) {
    final ctrl = _ctrl;
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(env);
      return;
    }
    // No controller yet — lazily create one and queue the event. When
    // the caller invokes `incoming.listen(...)`, the queued event is
    // replayed (single-subscription streams buffer events that arrive
    // before the listener subscribes).
    final pending = _ctrl ??= StreamController<PeerSyncEnvelope>();
    if (!pending.isClosed) pending.add(env);
  }
}

/// Helper: build a Message with a fixed id and a stub payload. We don't
/// need cryptographic fidelity for sync tests — just a unique id and a
/// stable identity.
Message _makeMessage(String id, {MessageType type = MessageType.chat}) {
  return Message(
    id: id,
    mode: MessageMode.broadcast,
    type: type,
    channelId: 'public',
    senderId: 'device-$id',
    senderDisplayName: 'device-$id',
    origin: MessageOrigin.mesh,
    recipientId: null,
    payload: Uint8List.fromList(utf8.encode('hello-$id')),
    ratchetHeader: null,
    location: null,
    createdAt: DateTime.utc(2026, 7, 30),
    ttl: 8,
    hopCount: 0,
    signature: null,
    inResponseTo: null,
  );
}

void main() {
  group('PeerSync — basic state', () {
    test('starts empty and records messages idempotently', () {
      final sync = PeerSync(selfPeerId: 'me');
      expect(sync.storedCount, 0);
      sync.registerMessage(_makeMessage('a'));
      sync.registerMessage(_makeMessage('a'));
      expect(sync.storedCount, 1);
      sync.registerMessages([_makeMessage('b'), _makeMessage('c')]);
      expect(sync.storedCount, 3);
      expect(sync.localBloom.mightContain('a'), isTrue);
      expect(sync.localBloom.mightContain('b'), isTrue);
    });

    test('registerSeenIds populates the Bloom but not the message store',
        () {
      final sync = PeerSync(selfPeerId: 'me');
      sync.registerSeenIds(['x', 'y', 'z']);
      expect(sync.localBloom.mightContain('x'), isTrue);
      expect(sync.localBloom.mightContain('y'), isTrue);
      expect(sync.localBloom.mightContain('z'), isTrue);
      // No payloads were stored.
      expect(sync.storedCount, 0);
    });
  });

  group('PeerSync — symmetric-difference handshake', () {
    test('two devices exchange blooms and push only the messages the other is missing',
        () async {
      // Two devices, each with a partial (overlapping) history.
      final alice = PeerSync(selfPeerId: 'alice');
      final bob = PeerSync(selfPeerId: 'bob');

      // Shared history: both Alice and Bob have seen messages 1..5.
      for (var i = 1; i <= 5; i++) {
        alice.registerMessage(_makeMessage('shared-$i'));
        bob.registerMessage(_makeMessage('shared-$i'));
      }
      // Alice-only history: 6..10.
      for (var i = 6; i <= 10; i++) {
        alice.registerMessage(_makeMessage('alice-$i'));
      }
      // Bob-only history: 11..15.
      for (var i = 11; i <= 15; i++) {
        bob.registerMessage(_makeMessage('bob-$i'));
      }

      // Wire two loopback channels back-to-back.
      final aliceCh = LoopbackPeerChannel(name: 'aliceCh');
      final bobCh = LoopbackPeerChannel(name: 'bobCh');
      aliceCh.remote = bobCh;
      bobCh.remote = aliceCh;

      // Track what each side decides to push.
      final alicePush = <Message>[];
      final bobPush = <Message>[];
      alice.onPush = (m) => alicePush.add(m);
      bob.onPush = (m) => bobPush.add(m);

      // Subscribe each side to whatever relay messages the link delivers.
      // In a real device this is the mesh's `incoming` stream; for the
      // sync test we just record what arrived.
      final aliceInbox = <Message>[];
      final bobInbox = <Message>[];
      final aliceInboxSub = aliceCh.incomingRelay.stream.listen(aliceInbox.add);
      final bobInboxSub = bobCh.incomingRelay.stream.listen(bobInbox.add);

      // Run both handshakes in parallel — real devices don't sequence.
      await Future.wait([
        alice.handleConnect(aliceCh),
        bob.handleConnect(bobCh),
      ]);

      // Drain event loop so the broadcast streams flush.
      await Future<void>.delayed(Duration.zero);

      // Assertions.
      // 1. Alice's push list contains exactly her alice-only messages.
      final alicePushIds = alicePush.map((m) => m.id).toList()..sort();
      expect(
          alicePushIds,
          equals({
            'alice-6',
            'alice-7',
            'alice-8',
            'alice-9',
            'alice-10',
          }),
          reason: 'Alice should push exactly her alice-only messages');
      // Bob's push list contains exactly his bob-only messages.
      final bobPushIds = bobPush.map((m) => m.id).toList()..sort();
      expect(
          bobPushIds,
          equals({
            'bob-11',
            'bob-12',
            'bob-13',
            'bob-14',
            'bob-15',
          }),
          reason: 'Bob should push exactly his bob-only messages');
      // 2. The shared messages were NOT pushed — Bloom says "already seen".
      for (var i = 1; i <= 5; i++) {
        expect(alicePushIds.contains('shared-$i'), isFalse,
            reason: 'Alice should not re-push shared-$i');
        expect(bobPushIds.contains('shared-$i'), isFalse,
            reason: 'Bob should not re-push shared-$i');
      }
      // 3. Bob's wired channel received Alice's 5 alice-only messages.
      final bobInboxIds = bobInbox.map((m) => m.id).toList()..sort();
      expect(
          bobInboxIds,
          equals({
            'alice-6',
            'alice-7',
            'alice-8',
            'alice-9',
            'alice-10',
          }));
      // 4. Alice's wired channel received Bob's 5 bob-only messages.
      final aliceInboxIds = aliceInbox.map((m) => m.id).toList()..sort();
      expect(
          aliceInboxIds,
          equals({
            'bob-11',
            'bob-12',
            'bob-13',
            'bob-14',
            'bob-15',
          }));
      // 5. No duplicates: each side only pushed messages *unique* to it.
      expect(alicePushIds.length, 5);
      expect(bobPushIds.length, 5);

      await aliceInboxSub.cancel();
      await bobInboxSub.cancel();
      await aliceCh.incomingRelay.close();
      await bobCh.incomingRelay.close();
    });

    test('empty peers exchange empty filters and push nothing', () async {
      final alice = PeerSync(selfPeerId: 'alice');
      final bob = PeerSync(selfPeerId: 'bob');

      final aliceCh = LoopbackPeerChannel(name: 'aliceCh');
      final bobCh = LoopbackPeerChannel(name: 'bobCh');
      aliceCh.remote = bobCh;
      bobCh.remote = aliceCh;

      await Future.wait([
        alice.handleConnect(aliceCh),
        bob.handleConnect(bobCh),
      ]);

      expect(aliceCh.sentMessages, isEmpty);
      expect(bobCh.sentMessages, isEmpty);
      expect(aliceCh.sentControls.length, 1);
      expect(bobCh.sentControls.length, 1);

      await aliceCh.incomingRelay.close();
      await bobCh.incomingRelay.close();
    });

    test('one-sided history: only the side with extras pushes', () async {
      final alice = PeerSync(selfPeerId: 'alice');
      final bob = PeerSync(selfPeerId: 'bob');

      // Bob has 100 messages; Alice has none.
      for (var i = 0; i < 100; i++) {
        bob.registerMessage(_makeMessage('bob-$i'));
      }

      final aliceCh = LoopbackPeerChannel(name: 'aliceCh');
      final bobCh = LoopbackPeerChannel(name: 'bobCh');
      aliceCh.remote = bobCh;
      bobCh.remote = aliceCh;

      await Future.wait([
        alice.handleConnect(aliceCh),
        bob.handleConnect(bobCh),
      ]);

      // Alice pushes nothing (her filter is empty -> peerFilter contains 0).
      // Bob pushes to Alice (her filter says she's seen almost nothing).
      expect(aliceCh.sentMessages, isEmpty);
      expect(bobCh.sentMessages.length, 100);

      await aliceCh.incomingRelay.close();
      await bobCh.incomingRelay.close();
    });

    test('handshake surfaces a timeout when the peer never sends a filter',
        () async {
      // Bob never calls handleConnect — there is no remote filter to
      // receive. Alice's handshake should hit its `handshakeTimeout`
      // and surface the error via `onError` (rather than throw).
      final alice = PeerSync(selfPeerId: 'alice');
      alice.registerMessage(_makeMessage('alice-1'));

      final aliceCh = LoopbackPeerChannel(name: 'aliceCh');
      final bobCh = LoopbackPeerChannel(name: 'bobCh');
      aliceCh.remote = bobCh;
      bobCh.remote = aliceCh;

      Object? capturedError;
      final completer = Completer<void>();

      // Alice's handshake: tiny timeout, no peer filter arrives.
      await alice.handleConnect(
        aliceCh,
        handshakeTimeout: const Duration(milliseconds: 50),
        onError: (e, _) {
          capturedError = e;
          if (!completer.isCompleted) completer.complete();
        },
      );

      // The captured error should be a TimeoutException.
      expect(capturedError, isNotNull,
          reason: 'Alice should have surfaced a timeout error');
      expect(capturedError, isA<TimeoutException>());

      await aliceCh.incomingRelay.close();
      await bobCh.incomingRelay.close();
    });
  });

  group('PeerSyncEnvelope encode/decode', () {
    test('PeerSyncFilter roundtrips through JSON', () {
      final filter = BloomFilter.empty();
      filter.insert('hello');
      filter.insert('world');
      final env = PeerSyncFilter(peerId: 'me', filterBytes: filter.encode());
      final json = env.toJson();
      expect(json['kind'], 'bloom_filter');
      expect(json['peer_id'], 'me');
      final round = PeerSyncEnvelope.decode(json);
      expect(round, isA<PeerSyncFilter>());
      final r = round as PeerSyncFilter;
      expect(r.peerId, 'me');
      // Decoded Bloom should still contain the inserted ids.
      final decoded = BloomFilter.decode(r.filterBytes);
      expect(decoded.mightContain('hello'), isTrue);
      expect(decoded.mightContain('world'), isTrue);
    });

    test('PeerSyncEnvelope.decode rejects unknown kinds', () {
      expect(
        () => PeerSyncEnvelope.decode({'kind': 'mystery'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('PeerSyncFilter.fromJson validates types', () {
      expect(
        () => PeerSyncFilter.fromJson({
          'kind': 'bloom_filter',
          'peer_id': 42,
          'filter': 'xxx',
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PeerSyncFilter.fromJson({
          'kind': 'bloom_filter',
          'peer_id': 'me',
          'filter': 42,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PeerSync — registration of received messages', () {
    test('messages delivered via the relay inbox can be registered post-sync',
        () async {
      final alice = PeerSync(selfPeerId: 'alice');
      final bob = PeerSync(selfPeerId: 'bob');

      // Alice has 3 messages.
      for (var i = 0; i < 3; i++) {
        alice.registerMessage(_makeMessage('alice-$i'));
      }

      final aliceCh = LoopbackPeerChannel(name: 'aliceCh');
      final bobCh = LoopbackPeerChannel(name: 'bobCh');
      aliceCh.remote = bobCh;
      bobCh.remote = aliceCh;

      // Pretend the relay is wired up: when the loopback channel delivers
      // a message to Bob, we register it into Bob's local store.
      final bobInboxSub = bobCh.incomingRelay.stream.listen((m) {
        bob.registerMessage(m);
      });

      await Future.wait([
        alice.handleConnect(aliceCh),
        bob.handleConnect(bobCh),
      ]);

      // Wait a tick for the broadcast stream to flush.
      await Future<void>.delayed(Duration.zero);

      // Bob now knows about Alice's 3 messages.
      expect(bob.storedCount, 3);
      expect(bob.localBloom.mightContain('alice-0'), isTrue);
      expect(bob.localBloom.mightContain('alice-1'), isTrue);
      expect(bob.localBloom.mightContain('alice-2'), isTrue);

      await bobInboxSub.cancel();
      await aliceCh.incomingRelay.close();
      await bobCh.incomingRelay.close();
    });
  });
}
