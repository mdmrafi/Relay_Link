// RelayLink — MeshTransport (Ticket #08 against Ticket #07 discovery).
//
// Real `Transport` implementation backed by Ticket #07's `MeshDiscovery`
// (which wraps the underlying BLE radio via `MeshDiscoveryPlatform`).
//
// WIRE FORMAT
// ===========
// `send(msg)` UTF-8 JSON-encodes the message via `Message.toJson()` and
// calls `MeshDiscoveryPlatform.sendPayload` for every connected peer
// surfaced by `MeshDiscovery.currentPeers`. The wire bytes are the
// exact bytes the discovery module already understands, so the
// platform plugin's `MeshPlatformPayload` handler (see
// `lib/mesh/discovery.dart`) decodes them via the same
// `MeshDiscovery.tryDecodeMessage` helper.
//
// AVAILABILITY
// ============
// `isAvailable()` is true iff the BLE radio is powered on AND
// permissions are granted AND at least one peer is currently in the
// connected set. Legacy test fixtures that flip
// `setSimulatedPeerConnected(true)` continue to drive the transport
// without standing up a real radio.

import 'dart:async';

import '../models/message.dart';
import '../transport/transport.dart';
import 'discovery.dart';

/// Transport adapter that fans out raw Message JSON through Ticket #07's
/// [MeshDiscoveryPlatform] while preserving the legacy relay test hooks.
class MeshTransport implements Transport {
  /// Construct a transport wired to the supplied discovery. Production
  /// code passes a `MeshDiscovery` whose platform is the real BLE
  /// plugin; tests inject a fake platform (see
  /// `test/mesh/transport_test.dart`).
  MeshTransport({MeshDiscovery? discovery})
      : _discovery = discovery ?? MeshDiscovery();

  /// The discovery seam we broadcast on and listen to.
  final MeshDiscovery _discovery;

  /// Outgoing messages this transport has sent. Surfaced via the
  /// `simulatedOutgoing` getter for the legacy Gateway relay tests.
  final List<Message> _outgoing = <Message>[];

  /// Legacy knob: when `true`, `isAvailable()` returns true even if no
  /// real peer is connected. The Gateway relay tests rely on this to
  /// flip availability before injecting messages via `simulateIncoming`.
  bool _simulatedPeerConnected = false;

  /// Subscription to the discovery's decoded message stream. Forwards
  /// every inbound `Message` onto our own `incoming` broadcast stream
  /// so consumers of this transport don't have to know about the
  /// discovery seam.
  StreamSubscription<Message>? _incomingSub;

  /// Broadcast controller for the Transport-facing `incoming` stream.
  final StreamController<Message> _incomingController =
      StreamController<Message>.broadcast();

  @override
  String get name => 'mesh';

  /// Underlying discovery seam. Exposed for advanced tests and for the
  /// app bootstrap to start/stop the radio.
  MeshDiscovery get discovery => _discovery;

  @override
  Stream<Message> get incoming => _incomingController.stream;

  @override
  bool isAvailable() {
    if (_simulatedPeerConnected) return true;
    return _discovery.platform.isBluetoothEnabled &&
        _discovery.platform.hasPermissions &&
        _connectedPeerIds.isNotEmpty;
  }

  /// Snapshot of peer ids currently in the connected state.
  Set<String> get _connectedPeerIds => _discovery.currentPeers
      .where((peer) => peer.status == PeerStatus.connected)
      .map((peer) => peer.id)
      .toSet();

  @override
  Future<void> send(Message msg) async {
    if (!isAvailable()) throw TransportUnavailableException(name);

    final peerIds = _connectedPeerIds;
    if (peerIds.isEmpty && _simulatedPeerConnected) return;
    if (peerIds.isEmpty) throw TransportUnavailableException(name);

    // Record the outgoing message only after the availability check
    // so the legacy hook reflects sends that actually proceeded.
    _outgoing.add(msg);

    final bytes = MeshDiscovery.encodeMessage(msg);
    // NOTE: per-peer errors other than the first are not propagated.
    // For a broadcast relay, only the first failure is rethrown; any
    // additional per-peer failures during the same send are silently
    // dropped. Callers that need full error aggregation should wrap
    // `send` in their own fan-out logic.
    Object? firstError;
    for (final peerId in peerIds) {
      try {
        await _discovery.platform.sendPayload(peerId, bytes);
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Wire `discovery.incoming` into our own broadcast stream. Idempotent.
  void wireIncoming() {
    _incomingSub ??= _discovery.incoming.listen((message) {
      if (!_incomingController.isClosed) _incomingController.add(message);
    });
  }

  /// Power the radio on (idempotent).
  Future<void> startRadio() => _discovery.start();

  /// Power the radio off (idempotent).
  Future<void> stopRadio() => _discovery.stop();

  Future<void> dispose() async {
    await _incomingSub?.cancel();
    _incomingSub = null;
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }

  /// Synchronous tear-down for tests that don't want to await `dispose`.
  void disposeSync() {
    _incomingSub?.cancel();
    _incomingSub = null;
    if (!_incomingController.isClosed) {
      unawaited(_incomingController.close());
    }
  }

  // ---------------------------------------------------------------------
  // Legacy test hooks (preserved for Gateway relay tests).
  // ---------------------------------------------------------------------

  /// Drive [isAvailable] directly. Production code never calls this.
  void setSimulatedPeerConnected(bool connected) {
    _simulatedPeerConnected = connected;
  }

  /// Inject a message onto `incoming` as if it had just been received
  /// from the radio.
  void simulateIncoming(Message msg) {
    if (!_incomingController.isClosed) _incomingController.add(msg);
  }

  /// Read-only view of every message this transport has sent via `send`.
  List<Message> get simulatedOutgoing =>
      List<Message>.unmodifiable(_outgoing);
}