// RelayLink — RelayStrategy abstract class (Ticket #48 / spec §2).
//
// This is the seam between a peer's incoming stream and the relay
// decision. The current scale harness uses `MirrorRelayStrategy`
// against `LoopbackMeshDiscovery`; when the real mesh transport lands,
// a `MeshRelayStrategy` will implement the same interface without
// touching the harness scenarios or metrics code.
//
// The signatures are locked by the spec — do not rename or reshape
// parameters.

import 'package:relaylink/mesh/bloom.dart';
import 'package:relaylink/models/message.dart';

abstract class RelayStrategy {
  /// Called when a peer's `incoming` stream produces a message.
  /// Returns the relayed Message (TTL decremented, hopCount incremented),
  /// or null if the message was dropped (seen-cache hit or TTL=0).
  Message? onIncoming({
    required String peerId,
    required Message msg,
    required BloomFilter seenCache,
  });

  /// Called to send a freshly-originated message into the network.
  void originate({
    required String senderId,
    required Message msg,
  });

  /// Tear down timers and subscriptions.
  Future<void> close();
}
