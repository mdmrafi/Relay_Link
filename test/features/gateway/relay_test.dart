// RelayLink — Ticket #22: Gateway relay orchestrator tests.
//
// These tests pin the safety boundaries of the gateway relay:
//   * When toggle is OFF, no push / no pull / no re-inject.
//   * When toggle is ON:
//       - Mesh-received messages are pushed UP to Firestore UNLESS they
//         are originated here, addressed to self, or already seen.
//       - Sender_id is preserved (the gateway is a courier, not editor).
//       - Pulled messages are re-injected into the mesh transport's
//         outgoing pipeline via the TransportManager.
//       - DIRECT messages are re-injected only if addressed to us or to
//         a known mesh peer.
//       - BROADCAST messages are always re-injected if not seen.
//   * The orchestrator cleans up on stop() and is idempotent.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/features/gateway/relay.dart';
import 'package:relaylink/mesh/transport.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/internet.dart';
import 'package:relaylink/transport/transport.dart';

/// In-memory [FirestoreGateway] for tests. Records every push and lets
/// tests enqueue pull candidates.
class FakeFirestoreGateway implements FirestoreGateway {
  final List<Message> pushed = <Message>[];
  final List<Message> _broadcastQueue = <Message>[];
  final List<Message> _directQueue = <Message>[];

  /// Last time `pullBroadcastSince` was called. Tests use this to assert
  /// the poll loop is firing.
  DateTime lastBroadcastPullAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime lastDirectPullAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Throw on the next push so the relay's catch path is exercised.
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
    lastBroadcastPullAt = DateTime.now().toUtc();
    final out = _broadcastQueue.toList();
    _broadcastQueue.clear();
    return out;
  }

  @override
  Future<List<Message>> pullDirectFor(
    String recipientId,
    DateTime since,
  ) async {
    lastDirectPullAt = DateTime.now().toUtc();
    final out = _directQueue.toList();
    _directQueue.clear();
    return out;
  }

  /// Enqueue a message to be returned by the next broadcast pull.
  void enqueueBroadcastPull(Message msg) => _broadcastQueue.add(msg);

  /// Enqueue a message to be returned by the next direct pull.
  void enqueueDirectPull(Message msg) => _directQueue.add(msg);
}

/// In-memory [SeenCache] for tests.
class FakeSeenCache implements SeenCache {
  final Set<String> _seen = <String>{};

  @override
  Future<bool> has(String id) async => _seen.contains(id);

  @override
  Future<void> mark(String id) async {
    _seen.add(id);
  }

  Set<String> get seenIds => Set<String>.unmodifiable(_seen);
}

/// Build a one-off test message with the given fields.
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

/// Wires up a MeshTransport, InternetTransport, TransportManager, and a
/// GatewayRelay with the given toggle/peers state. Returns the parts so
/// tests can drive them.
class _RelayFixture {
  final MeshTransport mesh = MeshTransport();
  late final InternetTransport internet;
  final TransportManager manager = TransportManager();
  final FakeFirestoreGateway firestore = FakeFirestoreGateway();
  final FakeSeenCache seen = FakeSeenCache();
  late final GatewayRelay relay;

  bool toggle = false;
  final Set<String> knownPeers = <String>{'peer-2'};

  _RelayFixture() {
    manager.register(mesh);
    internet = InternetTransport(
      gateway: firestore,
      ownSenderId: 'me',
      pollInterval: const Duration(milliseconds: 50),
    );
    internet.setAvailable(true);
    manager.register(internet);
    relay = GatewayRelay(
      mesh: mesh,
      internet: internet,
      transportManager: manager,
      seenCache: seen,
      ownSenderIdProvider: () => 'me',
      knownPeersProvider: () => knownPeers,
      isGatewayEnabled: () => toggle,
    );
  }

  /// Drive the relay's queues to a clean state.
  Future<void> cleanUp() async {
    await relay.stop();
    await mesh.dispose();
    await internet.dispose();
  }
}

void main() {
  group('ShouldPushToFirestore (pure decision)', () {
    late _RelayFixture fx;
    setUp(() {
      fx = _RelayFixture();
      fx.toggle = true;
    });
    tearDown(() => fx.cleanUp());

    test('toggle OFF → drops everything', () {
      fx.toggle = false;
      final m = _msg(id: '1', mode: MessageMode.broadcast, type: MessageType.chat);
      expect(fx.relay.shouldPushToFirestore(m), 'toggle-off');
    });

    test('BROADCAST from another sender → push', () {
      final m = _msg(id: '1', mode: MessageMode.broadcast, type: MessageType.chat, senderId: 'other');
      expect(fx.relay.shouldPushToFirestore(m), isNull);
    });

    test('BROADCAST from me → drop (originated-here)', () {
      final m = _msg(id: '1', mode: MessageMode.broadcast, type: MessageType.chat, senderId: 'me');
      expect(fx.relay.shouldPushToFirestore(m), 'originated-here');
    });

    test('DIRECT from someone to me → drop (addressed-to-self)', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        senderId: 'peer-2',
        recipientId: 'me',
      );
      expect(fx.relay.shouldPushToFirestore(m), 'addressed-to-self');
    });

    test('DIRECT addressed to another peer → push', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        senderId: 'peer-2',
        recipientId: 'peer-3',
      );
      expect(fx.relay.shouldPushToFirestore(m), isNull);
    });
  });

  group('ShouldReInjectIntoMesh (pure decision)', () {
    late _RelayFixture fx;
    setUp(() {
      fx = _RelayFixture();
      fx.toggle = true;
    });
    tearDown(() => fx.cleanUp());

    test('toggle OFF → never re-inject', () {
      fx.toggle = false;
      final m = _msg(id: '1', mode: MessageMode.broadcast, type: MessageType.chat);
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{}), isFalse);
    });

    test('seen-cache hit → never re-inject', () {
      final m = _msg(id: '1', mode: MessageMode.broadcast, type: MessageType.chat);
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{'1'}), isFalse);
    });

    test('BROADCAST not seen → re-inject even on custom channel', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'aid-workers',
      );
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{}), isTrue);
    });

    test('DIRECT to me → re-inject', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        recipientId: 'me',
      );
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{}), isTrue);
    });

    test('DIRECT to known peer → re-inject', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        recipientId: 'peer-2',
      );
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{}), isTrue);
    });

    test('DIRECT to unknown peer → drop (no one to deliver to)', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        recipientId: 'peer-NEVER-SEEN',
      );
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{}), isFalse);
    });

    test('DIRECT with null recipient → drop', () {
      final m = _msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        recipientId: null,
      );
      expect(fx.relay.shouldReInjectIntoMesh(m, seenIds: <String>{}), isFalse);
    });
  });

  group('Mesh → Firestore push (live)', () {
    late _RelayFixture fx;
    setUp(() {
      fx = _RelayFixture();
      fx.mesh.setSimulatedPeerConnected(true);
    });
    tearDown(() => fx.cleanUp());

    test('toggle OFF = no push even if message crosses the relay', () async {
      fx.toggle = false;
      fx.relay.start();
      // Wait one microtask cycle so the subscription is wired.
      await Future<void>.delayed(Duration.zero);
      fx.mesh.simulateIncoming(_msg(
        id: '1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed, isEmpty);
      expect(fx.relay.dropped.length, 1);
      expect(fx.relay.dropped.first.reason, 'toggle-off');
    });

    test('toggle ON: push others` BROADCAST to Firestore', () async {
      fx.toggle = true;
      fx.relay.start();
      await Future<void>.delayed(Duration.zero);
      fx.mesh.simulateIncoming(_msg(
        id: '1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'peer-2',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed.length, 1);
      expect(fx.firestore.pushed.first.id, '1');
      expect(fx.firestore.pushed.first.senderId, 'peer-2',
          reason: 'sender_id must be preserved (shadow identity)');
      expect(fx.relay.pushedUp.length, 1);
    });

    test('toggle ON: do NOT push our own messages', () async {
      fx.toggle = true;
      fx.relay.start();
      await Future<void>.delayed(Duration.zero);
      fx.mesh.simulateIncoming(_msg(
        id: '1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'me',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed, isEmpty);
      expect(fx.relay.dropped.length, 1);
      expect(fx.relay.dropped.first.reason, 'originated-here');
    });

    test('toggle ON: do NOT push DIRECT messages addressed to me', () async {
      fx.toggle = true;
      fx.relay.start();
      await Future<void>.delayed(Duration.zero);
      fx.mesh.simulateIncoming(_msg(
        id: '1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        senderId: 'peer-2',
        recipientId: 'me',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed, isEmpty);
      expect(fx.relay.dropped.length, 1);
      expect(fx.relay.dropped.first.reason, 'addressed-to-self');
    });

    test('push failure → drop with "push-failed" reason', () async {
      fx.toggle = true;
      fx.firestore.throwOnPush = true;
      fx.relay.start();
      await Future<void>.delayed(Duration.zero);
      fx.mesh.simulateIncoming(_msg(
        id: '1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'peer-2',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed, isEmpty,
          reason: 'failure leaves nothing pushed');
      expect(fx.relay.dropped.length, 1);
      expect(fx.relay.dropped.first.reason, contains('push-failed'));
    });

    test('seen-cache dedup: same id pushed only once', () async {
      fx.toggle = true;
      fx.relay.start();
      await Future<void>.delayed(Duration.zero);
      final m = _msg(
        id: 'dup',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'peer-2',
      );
      fx.mesh.simulateIncoming(m);
      fx.mesh.simulateIncoming(m);
      fx.mesh.simulateIncoming(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed.length, 1);
      expect(fx.relay.dropped.where((d) => d.reason == 'seen-cache-hit').length,
          2);
    });
  });

  group('Firestore → mesh pull (live)', () {
    late _RelayFixture fx;
    setUp(() {
      fx = _RelayFixture();
      fx.mesh.setSimulatedPeerConnected(true);
    });
    tearDown(() => fx.cleanUp());

    test('toggle OFF: poll loop never starts', () async {
      fx.toggle = false;
      fx.relay.start();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // The orchestrator never starts the poll; the fake gateway's
      // `lastBroadcastPullAt` stays at the epoch default.
      expect(fx.firestore.lastBroadcastPullAt.millisecondsSinceEpoch, 0);
    });

    test('toggle ON: poll loop fires and pulls BROADCAST messages', () async {
      fx.toggle = true;
      fx.relay.start();
      final m = _msg(
        id: 'fcast-1',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'remote-peer',
        channelId: 'public',
      );
      fx.firestore.enqueueBroadcastPull(m);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      fx.relay.onGatewayToggleChanged(true);
      // The orchestrator's `pollStart` is called from `start()` when the
      // toggle is on. The first poll happens immediately. Wait long enough
      // for the stream to drain.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fx.firestore.lastBroadcastPullAt.millisecondsSinceEpoch,
          greaterThan(0));
      expect(fx.relay.reInjected.length, greaterThanOrEqualTo(1));
      expect(fx.relay.reInjected.any((x) => x.id == 'fcast-1'), isTrue);
    });

    test('pulled message is re-injected with hop_count+1', () async {
      fx.toggle = true;
      fx.relay.start();
      final m = _msg(
        id: 'pcast',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'remote-peer',
        hopCount: 2,
      );
      fx.firestore.enqueueBroadcastPull(m);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      fx.relay.onGatewayToggleChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fx.relay.reInjected.any((x) => x.id == 'pcast'), isTrue);
      // The mesh transport's `simulatedOutgoing` list should reflect the
      // fan-out (the TransportManager sent it to mesh because mesh is
      // available).
      expect(fx.mesh.simulatedOutgoing.any((x) => x.id == 'pcast'), isTrue);
      final r = fx.mesh.simulatedOutgoing.firstWhere((x) => x.id == 'pcast');
      expect(r.hopCount, 3, reason: 'hop_count incremented by 1');
    });

    test('DIRECT pulled message addressed to unknown peer is dropped',
        () async {
      fx.toggle = true;
      fx.relay.start();
      final m = _msg(
        id: 'd1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        senderId: 'remote-peer',
        recipientId: 'NOBODY',
      );
      fx.firestore.enqueueDirectPull(m);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      fx.relay.onGatewayToggleChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fx.relay.reInjected, isEmpty);
      expect(
        fx.relay.dropped.any((d) => d.reason == 'unknown-direct-recipient'),
        isTrue,
      );
    });

    test('DIRECT pulled message addressed to known peer IS re-injected',
        () async {
      fx.toggle = true;
      fx.relay.start();
      final m = _msg(
        id: 'd2',
        mode: MessageMode.direct,
        type: MessageType.chat,
        senderId: 'remote-peer',
        recipientId: 'peer-2',
      );
      fx.firestore.enqueueDirectPull(m);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      fx.relay.onGatewayToggleChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fx.relay.reInjected.any((x) => x.id == 'd2'), isTrue);
    });

    test('toggle flip OFF while running stops the poll loop', () async {
      fx.toggle = true;
      fx.relay.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      fx.relay.onGatewayToggleChanged(false);
      // Reset the cursor so we can detect "no new pull".
      fx.firestore.lastBroadcastPullAt = DateTime.fromMillisecondsSinceEpoch(0);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fx.firestore.lastBroadcastPullAt.millisecondsSinceEpoch, 0);
    });
  });

  group('Idempotency / lifecycle', () {
    test('start() is idempotent', () async {
      final fx = _RelayFixture();
      fx.toggle = true;
      fx.mesh.setSimulatedPeerConnected(true);
      fx.relay.start();
      fx.relay.start(); // second call no-op
      expect(fx.relay.isRunning, isTrue);
      await fx.cleanUp();
    });

    test('stop() is idempotent and finally shuts down', () async {
      final fx = _RelayFixture();
      fx.toggle = true;
      fx.mesh.setSimulatedPeerConnected(true);
      fx.relay.start();
      await fx.relay.stop();
      expect(fx.relay.isRunning, isFalse);
      // Calling stop again is safe.
      await fx.relay.stop();
      await fx.cleanUp();
    });
  });

  group('Manual demo scenario (3 devices)', () {
    test('B sends, A relays (preserves B identity), C picks up (simulated)',
        () async {
      // This simulation runs A's relay in one process. B's message flows
      // into A's mesh radio and out through Firestore with B's sender_id
      // preserved. The "C picks up" half is asserted by inspecting the
      // pushed envelope — what C's gateway would pull — which is the same
      // object.
      final fx = _RelayFixture();
      fx.toggle = true;
      fx.mesh.setSimulatedPeerConnected(true);

      final bsMessage = _msg(
        id: 'B-msg-1',
        mode: MessageMode.broadcast,
        type: MessageType.sos,
        senderId: 'B',
        channelId: 'public',
      );

      fx.relay.start();
      fx.mesh.simulateIncoming(bsMessage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // A pushed the message to Firestore with B's identity intact.
      expect(fx.firestore.pushed.length, 1);
      final pushed = fx.firestore.pushed.first;
      expect(pushed.senderId, 'B',
          reason: 'gateway must preserve original sender_id');
      expect(pushed.id, 'B-msg-1');
      expect(pushed.payload, bsMessage.payload,
          reason: 'payload bytes must be byte-identical (we are a courier)');
      expect(pushed.signature, bsMessage.signature);

      await fx.cleanUp();
    });

    test('seen-cache prevents the gateway from re-injecting its own pushes',
        () async {
      // If A pushes B's message up to Firestore, then the same message
      // comes back down the pull loop (e.g. because Firestore's
      // pull-since-cursor is noisy), A should NOT re-inject it. The
      // seen-cache mark from the push side is the dedup guarantee.
      final fx = _RelayFixture();
      fx.toggle = true;
      fx.mesh.setSimulatedPeerConnected(true);
      fx.relay.start();

      final m = _msg(
        id: 'B-msg-2',
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        senderId: 'B',
        channelId: 'public',
      );

      // First, the push path: B's message arrives via mesh, gets pushed
      // up.
      fx.mesh.simulateIncoming(m);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fx.firestore.pushed.length, 1);

      // Now the same id comes back through the pull path. The relay
      // should drop it (seen-cache hit) rather than re-inject.
      fx.firestore.enqueueBroadcastPull(m);
      fx.relay.onGatewayToggleChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fx.relay.reInjected, isEmpty,
          reason: 'seen-cache hit on pull side should drop the message');
      expect(fx.relay.dropped.any((d) => d.reason == 'seen-cache-hit'),
          isTrue);

      await fx.cleanUp();
    });
  });
}
