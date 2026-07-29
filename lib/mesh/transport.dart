// RelayLink — Minimal MeshTransport (Ticket #08 minimal compatible stub).
//
// This file implements a minimal, in-memory `MeshTransport` that satisfies
// the `Transport` contract from `lib/transport/transport.dart` for the
// purposes of the Gateway relay (Ticket #22). The real Ticket #08
// implementation will replace this with a Nearby-Connections /
// Multipeer-Connectivity backed transport.
//
// CONTRACT (a subset of Ticket #08's contract):
//   * `send(msg)` — in-memory, simply stores the message in a per-instance
//     outbox stream. The real implementation will JSON-encode and ship over
//     BLE.
//   * `incoming` — a broadcast stream of messages that have been "received"
//     from the (mock) peer radio. The Gateway relay subscribes to this.
//   * `isAvailable()` — true once at least one "peer" has been simulated
//     via `simulateIncoming`. The real impl checks Bluetooth radio state.
//   * `simulateIncoming(msg)` — test/dev hook: pretend a peer radio just
//     gave us this message.
//   * `simulateOutgoing(msg)` — test/dev hook: return the last message that
//     was sent so tests can assert what the relay pushed back into mesh.
//
// The relay layer does NOT depend on the real Bluetooth stack — it only
// depends on the abstract `Transport` interface above. Switching to the
// real Ticket #08 mesh transport is a single-line change in the app
// bootstrap.

import 'dart:async';

import '../models/message.dart';
import '../transport/transport.dart';

/// Minimal in-memory mesh transport. Used by the Gateway relay's tests
/// and as a placeholder for the real Bluetooth-backed mesh.
class MeshTransport implements Transport {
  @override
  final String name = 'mesh';

  /// Whether the simulated mesh has at least one connected peer.
  /// In real Ticket #08 this is "Bluetooth radio on AND permission granted
  /// AND at least one service active".
  bool _simulatedPeerConnected = false;

  /// Outgoing messages "the device" has sent. Useful for tests.
  final List<Message> _outgoing = <Message>[];

  /// Broadcast stream of incoming messages.
  final StreamController<Message> _incomingController =
      StreamController<Message>.broadcast();

  /// Whether the mesh transport is currently usable.
  @override
  bool isAvailable() => _simulatedPeerConnected;

  /// Connect / disconnect the simulated peer radio. Production code in
  /// Ticket #08 will replace this with platform-event state.
  void setSimulatedPeerConnected(bool connected) {
    _simulatedPeerConnected = connected;
  }

  /// Send a message "over the mesh". In this stub, the message is captured
  /// for tests and an error is thrown if the mesh is unavailable.
  @override
  Future<void> send(Message msg) async {
    if (!isAvailable()) {
      throw TransportUnavailableException(name);
    }
    _outgoing.add(msg);
  }

  /// Broadcast stream of incoming messages.
  @override
  Stream<Message> get incoming => _incomingController.stream;

  /// Test/dev hook: inject a message as if it had just been received from
  /// a peer radio. The receiver (e.g. the Gateway relay) sees it on
  /// [incoming].
  void simulateIncoming(Message msg) {
    if (_incomingController.isClosed) return;
    _incomingController.add(msg);
  }

  /// Test/dev hook: list all messages sent via [send]. Most-recent last.
  List<Message> get simulatedOutgoing => List<Message>.unmodifiable(_outgoing);

  /// Free resources. Calling this will close [incoming] so any subscribers
  /// complete.
  Future<void> dispose() async {
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }
}
