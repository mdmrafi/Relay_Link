// RelayLink — MirrorRelayStrategy (Ticket #48 / spec §2).
//
// In-process relay strategy that mirrors the production relay behavior
// against `LoopbackMeshDiscovery`. The relay path is identical to what
// the harness used to inline in `_Peer._onIncoming`:
//
//   1. Dedup against the peer's bloom seen-cache. Hit → return null.
//   2. TTL <= 0 → return null (TTL exhausted).
//   3. Else: build `msg.copyWith(ttl: msg.ttl - 1, hopCount: msg.hopCount + 1)`
//      and broadcast it via the discovery layer. Return the decremented
//      message so the caller can observe the relay outcome.
//
// `originate` simply fans the message out via the discovery layer.

import 'package:relaylink/mesh/bloom.dart';
import 'package:relaylink/models/message.dart';

import 'loopback_mesh_discovery.dart';
import 'relay_strategy.dart';

class MirrorRelayStrategy implements RelayStrategy {
  MirrorRelayStrategy({required this._discovery});

  final LoopbackMeshDiscovery _discovery;

  @override
  Message? onIncoming({
    required String peerId,
    required String localDeviceId,
    required Message msg,
    required BloomFilter seenCache,
  }) {
    if (seenCache.mightContain(msg.id)) {
      return null;
    }
    seenCache.insert(msg.id);
    // Self-echo suppression: don't re-broadcast messages we originated.
    if (msg.senderId == localDeviceId) {
      return null;
    }
    if (msg.ttl <= 0) {
      return null;
    }
    final decremented = msg.copyWith(
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
    );
    // Direct-mode recipient filtering: only re-broadcast when this node is
    // the addressee (or the addressee is unset, defensively).
    if (msg.mode == MessageMode.direct &&
        msg.recipientId != null &&
        msg.recipientId != localDeviceId) {
      return decremented;
    }
    _discovery.broadcast(senderId: peerId, msg: decremented);
    return decremented;
  }

  @override
  void originate({required String senderId, required Message msg}) {
    _discovery.broadcast(senderId: senderId, msg: msg);
  }

  @override
  Future<void> close() async {
    // No timers or subscriptions to drain — the discovery layer owns
    // the lifecycle. Kept async to satisfy the spec signature.
  }
}
