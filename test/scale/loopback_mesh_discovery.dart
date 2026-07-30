// RelayLink — LoopbackMeshDiscovery: in-process device discovery for the
// scale-testing harness.
//
// The real mesh transport (Tickets #06, #08) will use Bluetooth / Nearby-
// Connections discovery. For the scale harness we want a deterministic,
// in-process simulation: spawn N peers, give each a `MeshTransport`-like
// inbox stream, and let a peer "broadcast" a message by emitting it onto
// every OTHER peer's incoming stream.
//
// DESIGN
//   * One registry per harness run. Created up front, peers register as
//     they come online.
//   * "Discovery" is just an in-memory set of `(peerId, inbox)` pairs.
//   * "Broadcast" is: for every peer whose id != senderId, push the message
//     onto that peer's incoming stream. There is no link-quality modelling
//     — every peer is in range of every other peer (this is the
//     fully-connected baseline).
//   * "Direct" is the same fan-out, but recipients whose id is not the
//     `recipientId` drop the message at the relay layer (the relay does
//     the addressing check, not the discovery layer).
//
// This keeps the harness free of mocks for the discovery path while
// letting the relay layer (TTL decrement, seen-cache dedup, fan-out) use
// the SAME abstractions it would in production.

import 'dart:async';
import 'dart:math' as math;

import 'package:relaylink/models/message.dart';

typedef MessageSink = void Function(Message msg);

/// In-process mesh peer registry. One peer = one entry in [peers].
class LoopbackMeshDiscovery {
  /// Map of peer id -> callback that the discovery uses to push messages
  /// into the peer's `incoming` stream. Registered peers are visible to
  /// every other peer for broadcast.
  final Map<String, MessageSink> peers = <String, MessageSink>{};

  /// Per-peer "send" delay (simulated wire latency). Each `broadcast` call
  /// schedules the message onto every peer's sink after this much delay
  /// using a Timer — so timing-sensitive metrics get a stable, measurable
  /// fanout. Defaults to `Duration.zero` (loopback speed) and may be
  /// overridden by the harness via [deliveryLatency].
  Duration deliveryLatency;

  /// Optional random jitter added on top of [deliveryLatency]. Each
  /// `broadcast` call picks a uniform random duration in `[0, jitter]`.
  /// Set to `Duration.zero` for deterministic timing.
  Duration jitter;

  LoopbackMeshDiscovery({
    this.deliveryLatency = Duration.zero,
    this.jitter = Duration.zero,
  });

  int get peerCount => peers.length;

  /// Register a peer. Once registered the peer is visible to broadcasts
  /// from every other peer.
  void register(String peerId, MessageSink sink) {
    peers[peerId] = sink;
  }

  /// Unregister a peer (e.g. when tearing the harness down).
  void unregister(String peerId) {
    peers.remove(peerId);
  }

  /// Deliver [msg] to every peer EXCEPT [senderId]. Each delivery is
  /// scheduled with [deliveryLatency] (+ optional jitter); the function
  /// returns immediately after scheduling.
  ///
  /// Returns the list of peer ids that were targeted.
  List<String> broadcast({
    required String senderId,
    required Message msg,
  }) {
    final targets = <String>[];
    for (final entry in peers.entries) {
      if (entry.key == senderId) continue;
      targets.add(entry.key);
      _schedule(entry.value, msg);
    }
    return targets;
  }

  /// Deliver [msg] only to the peer whose id matches [recipientId]. Used
  /// to mimic DIRECT addressing at the discovery layer (the recipient's
  /// relay layer still performs the addressing check based on
  /// `msg.recipientId`).
  void direct({
    required String senderId,
    required String recipientId,
    required Message msg,
  }) {
    final sink = peers[recipientId];
    if (sink == null || recipientId == senderId) return;
    _schedule(sink, msg);
  }

  void _schedule(MessageSink sink, Message msg) {
    final base = deliveryLatency;
    final dly = jitter == Duration.zero
        ? base
        : Duration(
            microseconds: base.inMicroseconds +
                _rng.nextInt(jitter.inMicroseconds + 1),
          );
    if (dly == Duration.zero) {
      sink(msg);
    } else {
      Timer(dly, () => sink(msg));
    }
  }

  /// Tear down: discard all peers. In-flight Timers continue to run; the
  /// sinks will then be no-ops (the harness should have closed the
  /// downstream streams by this point).
  void close() {
    peers.clear();
  }

  static final math.Random _rng = math.Random();
}
