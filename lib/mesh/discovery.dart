// RelayLink — Mesh discovery + connect (Ticket #07).
//
// Wraps the device's nearby-peer radio (Android Nearby Connections or
// iOS Multipeer Connectivity, behind the [MeshDiscoveryPlatform]
// abstraction) and exposes:
//
//   * `start()` / `stop()` — toggle the device's advertisement and
//     discovery (so the battery toggle in settings can flip the whole
//     radio leg off when the user wants).
//   * `peers` — broadcast [Stream] of the current peer set. The peer
//     list is re-emitted whenever a peer is found, lost, connected, or
//     disconnected.
//   * `connect(id)` — establishes a logical connection to a discovered
//     peer. On failure it backs off exponentially: 1s, 2s, 4s, … capped
//     at 30s. The first attempt fires immediately on `peer found`.
//   * `send(msg)` / `incoming` — implements the [Transport] contract
//     by JSON-encoding each [Message] to the wire format described in
//     `SPEC.md §5` and forwarding it to a single connected peer
//     (RelayLink uses a star / one-peer-per-session mesh today; a
//     fan-out relay will switch to a real P2P_CLUSTER implementation
//     in a later ticket).
//
// On iOS, the real implementation is `StubMeshDiscoveryPlatform` until
// the Multipeer Connectivity wrapper lands (Ticket #07 deferred).
//
// CONTRACT (from `.scratch/relaylink-build/issues/07-mesh-discovery.md`):
//   * Advertise ourselves as a RelayLink peer on `start()`.
//   * Discovery picks up other RelayLink peers within radio range.
//   * Connect succeeds on first attempt; on failure back off
//     1s, 2s, 4s, … capped at 30s.
//   * `peers` Stream emits on peer connect / disconnect.
//   * `isAvailable()` is true iff Bluetooth radio is on AND permission
//     granted.
//   * `ensurePermissions()` requests BLUETOOTH_CONNECT /
//     BLUETOOTH_ADVERTISE and returns whether the user granted them.
//
// iOS NOTE: real Multipeer Connectivity wiring is deferred. The stub
// platform returns `isBluetoothEnabled=false` and `hasPermissions=false`
// so `isAvailable()` correctly returns `false` until that work lands.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/message.dart';
import '../transport/transport.dart';

// ---------------------------------------------------------------------------
// Public data types
// ---------------------------------------------------------------------------

/// Status of a single peer in the mesh.
enum PeerStatus {
  /// The peer's advertisement was picked up but we haven't dialled yet.
  discovered,

  /// We're inside the backoff loop trying to dial this peer.
  connecting,

  /// The peer is dialed and we can ship bytes over the radio.
  connected,

  /// The peer went away (lost the advertisement or the dial
  /// session closed).
  disconnected,
}

/// One peer visible to the mesh radio.
class MeshPeer {
  const MeshPeer({
    required this.id,
    required this.name,
    required this.status,
  });

  /// Stable per-peer id (the OS-assigned endpoint id from the
  /// underlying BLE plugin).
  final String id;

  /// Human-readable display name from the advertisement payload.
  final String name;

  /// Current status in our local state machine.
  final PeerStatus status;

  MeshPeer copyWith({
    String? id,
    String? name,
    PeerStatus? status,
  }) {
    return MeshPeer(
      id: id ?? this.id,
      name: name ?? this.name,
      status: status ?? this.status,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MeshPeer &&
          other.id == id &&
          other.name == name &&
          other.status == status;

  @override
  int get hashCode => Object.hash(id, name, status);

  @override
  String toString() => 'MeshPeer(id=$id, name=$name, status=$status)';
}

// ---------------------------------------------------------------------------
// Platform abstraction
// ---------------------------------------------------------------------------

/// Events the platform plugin emits. [MeshDiscovery] translates these
/// into peer-list updates and incoming [Message]s.
sealed class MeshPlatformEvent {
  const MeshPlatformEvent(this.peerId);
  final String peerId;
}

class MeshPlatformPeerFound extends MeshPlatformEvent {
  const MeshPlatformPeerFound(super.peerId, this.name);
  final String name;
}

class MeshPlatformPeerLost extends MeshPlatformEvent {
  const MeshPlatformPeerLost(super.peerId);
}

class MeshPlatformPeerConnected extends MeshPlatformEvent {
  const MeshPlatformPeerConnected(super.peerId);
}

class MeshPlatformPeerDisconnected extends MeshPlatformEvent {
  const MeshPlatformPeerDisconnected(super.peerId);
}

class MeshPlatformPayload extends MeshPlatformEvent {
  const MeshPlatformPayload(super.peerId, this.bytes);
  final Uint8List bytes;
}

/// Thin abstraction over the underlying radio. The real implementation
/// wraps `flutter_nearby_connections` (Android) or `MultipeerConnectivity`
/// (iOS). The default is the [StubMeshDiscoveryPlatform] below.
abstract class MeshDiscoveryPlatform {
  /// `true` iff the Bluetooth radio is on and powered up.
  bool get isBluetoothEnabled;

  /// `true` iff the user has granted BLUETOOTH_CONNECT +
  /// BLUETOOTH_ADVERTISE (and the iOS Multipeer local-network
  /// permission on iOS).
  bool get hasPermissions;

  /// Prompt the user for the Bluetooth / Nearby-Devices permission.
  /// Returns `true` if the user granted. Default Android behaviour
  /// is to resolve once the user taps "Allow".
  Future<bool> requestPermissions();

  /// Begin advertising this device as a RelayLink peer.
  Future<void> startAdvertising({required String serviceName});

  /// Stop advertising.
  Future<void> stopAdvertising();

  /// Begin scanning for RelayLink advertisements.
  Future<void> startDiscovery({required String serviceName});

  /// Stop scanning.
  Future<void> stopDiscovery();

  /// Dial a discovered peer. Implementations may reject a connection
  /// (e.g. already connected) — callers are expected to handle errors.
  Future<void> connect(String peerId);

  /// Hang up on a connected peer.
  Future<void> disconnect(String peerId);

  /// Push [bytes] to the connected peer.
  Future<void> sendPayload(String peerId, Uint8List bytes);

  /// Platform-level events: peer-found/lost, connect/disconnect,
  /// incoming payloads.
  Stream<MeshPlatformEvent> get events;
}

/// Non-functional default. Always reports the radio as off, never
/// discovers peers, never accepts connects. Production code should
/// inject the real `flutter_nearby_connections`-backed platform — see
/// `MeshDiscoveryPlatform` and `example/mesh/real_platform.dart`
/// (TODO: write the real platform in a follow-up ticket).
///
/// Why the stub exists:
///   * Lets the rest of the app compile and run during development
///     without a Bluetooth stack available.
///   * Keeps tests deterministic — no radio collisions in CI.
///   * Surfaces the deferred-implementation note in code so the next
///     contributor finds it immediately.
class StubMeshDiscoveryPlatform implements MeshDiscoveryPlatform {
  const StubMeshDiscoveryPlatform();

  @override
  bool get isBluetoothEnabled => false;

  @override
  bool get hasPermissions => false;

  @override
  Future<bool> requestPermissions() async => false;

  @override
  Future<void> startAdvertising({required String serviceName}) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> startDiscovery({required String serviceName}) async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connect(String peerId) async {
    throw StateError(
      'StubMeshDiscoveryPlatform: real BLE implementation deferred. '
      'Wire flutter_nearby_connections (Android) or '
      'MultipeerConnectivity (iOS) before shipping.',
    );
  }

  @override
  Future<void> disconnect(String peerId) async {}

  @override
  Future<void> sendPayload(String peerId, Uint8List bytes) async {}

  @override
  Stream<MeshPlatformEvent> get events =>
      const Stream<MeshPlatformEvent>.empty();
}

// ---------------------------------------------------------------------------
// Backoff helper (exposed for tests)
// ---------------------------------------------------------------------------

/// Pure function: returns the next backoff delay in milliseconds before
/// retry attempt number [attemptNumber]. The first retry waits 1s, the
/// next 2s, then 4s, 8s, 16s, then capped at 30s.
///
/// [attemptNumber] is the *retry* number (1 = first retry, 2 = second
/// retry, …). The very first attempt fires immediately; this function
/// is only consulted for *subsequent* attempts.
int backoffMsForAttempt(int attemptNumber) {
  if (attemptNumber <= 1) return 1000;
  if (attemptNumber >= 6) return 30000;
  // 2^(attemptNumber-1) seconds, capped at 30s.
  final secs = 1 << (attemptNumber - 1);
  final capped = secs > 30 ? 30 : secs;
  return capped * 1000;
}

// ---------------------------------------------------------------------------
// MeshDiscovery — the public Transport implementation
// ---------------------------------------------------------------------------

/// The default service-name advertised to other RelayLink peers. The
/// platform plugin uses this as the service UUID prefix.
const String kRelayLinkServiceName = 'relaylink.mesh.v1';

/// User-facing rationale shown before requesting
/// `BLUETOOTH_CONNECT` and `BLUETOOTH_ADVERTISE`. The UI must surface
/// this verbatim before calling [MeshDiscovery.ensurePermissions] (see
/// Ticket #07 acceptance: "Permission for BLUETOOTH_CONNECT and
/// BLUETOOTH_ADVERTISE requested on first launch with rationale").
const String kRelayLinkBluetoothPermissionRationale =
    'RelayLink uses Nearby Devices (Bluetooth) to discover and relay '
    'messages to other RelayLink users during disaster and '
    'internet-outage scenarios. Allow Bluetooth access so we can find '
    'peers nearby, even when the cellular network is down.';

/// Mesh discovery + connect + send/receive. Implements [Transport] so
/// it plugs straight into [TransportManager].
class MeshDiscovery implements Transport {
  /// Rationale the first-launch UI should show before requesting the
  /// Android Nearby Devices permissions.
  static const String permissionRationale =
      kRelayLinkBluetoothPermissionRationale;

  /// Build a discovery bound to [platform]. In production use the
  /// default ([StubMeshDiscoveryPlatform]) until the real
  /// flutter_nearby_connections plugin is wired; tests inject a fake.
  MeshDiscovery({
    MeshDiscoveryPlatform? platform,
    this.serviceName = kRelayLinkServiceName,
  }) : _platform = platform ?? const StubMeshDiscoveryPlatform();

  final MeshDiscoveryPlatform _platform;

  /// Service name advertised and discovered. Exposed for diagnostics.
  final String serviceName;

  /// Map of currently-known peers, keyed by peer id.
  final Map<String, MeshPeer> _peers = <String, MeshPeer>{};

  /// Per-peer backoff bookkeeping. When non-null, there's a
  /// `Timer` scheduled that will fire the next connect attempt.
  final Map<String, _BackoffState> _backoff = <String, _BackoffState>{};

  /// Per-peer current "connected" state. A peer is connected only if
  /// the platform reported `MeshPlatformPeerConnected` AND we haven't
  /// seen a disconnect/lost since.
  final Set<String> _connected = <String>{};

  /// The single peer we're currently routing bytes to. RelayLink today
  /// sends over one connection per process; the relay layer will
  /// fan out across multiple peers in a later ticket.
  String? _activePeer;

  final StreamController<List<MeshPeer>> _peersController =
      StreamController<List<MeshPeer>>.broadcast();

  final StreamController<Message> _incomingController =
      StreamController<Message>.broadcast();

  StreamSubscription<MeshPlatformEvent>? _eventsSub;

  bool _running = false;
  bool _disposed = false;

  /// The platform backing this discovery. Tests inject a fake.
  MeshDiscoveryPlatform get platform => _platform;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Start advertising this device and scanning for peers. Idempotent.
  Future<void> start() async {
    if (_disposed || _running) return;
    _running = true;
    // Subscribe to platform events the first time we start. We keep the
    // subscription open for the lifetime of this instance — start/stop
    // toggles the radio only, not the event listener.
    _eventsSub ??= _platform.events.listen(_onPlatformEvent);
    await _platform.startAdvertising(serviceName: serviceName);
    await _platform.startDiscovery(serviceName: serviceName);
  }

  /// Stop advertising and scanning. Keeps the discovered peer cache so
  /// callers can still inspect it after `stop()`. Idempotent.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    // Cancel any pending backoff timers.
    for (final state in _backoff.values) {
      state.timer?.cancel();
    }
    _backoff.clear();
    await _platform.stopAdvertising();
    await _platform.stopDiscovery();
  }

  /// Release all resources. After `dispose()` the instance is unusable.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _eventsSub?.cancel();
    _eventsSub = null;
    if (!_peersController.isClosed) {
      await _peersController.close();
    }
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }

  // ---------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------

  @override
  String get name => 'mesh';

  @override
  bool isAvailable() => _platform.isBluetoothEnabled && _platform.hasPermissions;

  @override
  Stream<Message> get incoming => _incomingController.stream;

  @override
  Future<void> send(Message msg) async {
    if (!isAvailable()) {
      throw TransportUnavailableException(name);
    }
    final active = _activePeer;
    if (active == null) {
      throw TransportUnavailableException(name);
    }
    final bytes = encodeMessage(msg);
    await _platform.sendPayload(active, bytes);
  }

  // ---------------------------------------------------------------------
  // Public streams & helpers
  // ---------------------------------------------------------------------

  /// Snapshot of currently-known peers.
  List<MeshPeer> get currentPeers => List<MeshPeer>.unmodifiable(_peers.values);

  /// Broadcast stream of the peer list. Emits on every state change.
  ///
  /// New subscribers receive the current peer list immediately on
  /// subscription (a `BehaviorSubject`-style cache so consumers can
  /// read the latest snapshot without missing it).
  Stream<List<MeshPeer>> get peers async* {
    final initial = List<MeshPeer>.unmodifiable(_peers.values);
    yield initial;
    yield* _peersController.stream;
  }

  /// Force a connect to [peerId] (used by the auto-loop and exposed for
  /// future manual "kick the dial" actions).
  Future<void> connectPeer(String peerId) => _attemptConnect(peerId);

  /// Hang up on [peerId].
  Future<void> disconnectPeer(String peerId) async {
    _backoff.remove(peerId)?.timer?.cancel();
    if (_activePeer == peerId) _activePeer = null;
    _connected.remove(peerId);
    if (_peers.containsKey(peerId)) {
      _peers[peerId] = _peers[peerId]!.copyWith(status: PeerStatus.disconnected);
      _emitPeerList();
    }
    await _platform.disconnect(peerId);
  }

  /// Request BLUETOOTH_CONNECT + BLUETOOTH_ADVERTISE. Returns whether
  /// the user granted the permissions.
  Future<bool> ensurePermissions() => _platform.requestPermissions();

  // ---------------------------------------------------------------------
  // Wire format helpers (exposed for tests)
  // ---------------------------------------------------------------------

  /// JSON-encode [msg] using [Message.toJson]'s map and UTF-8 bytes.
  static Uint8List encodeMessage(Message msg) {
    return Uint8List.fromList(utf8.encode(jsonEncode(msg.toJson())));
  }

  /// Inverse of [encodeMessage]. Returns `null` if the bytes are
  /// malformed (rather than throwing) so the [incoming] stream can
  /// drop bad envelopes without closing.
  static Message? tryDecodeMessage(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) return null;
      return Message.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Internal: platform event handling
  // ---------------------------------------------------------------------

  void _onPlatformEvent(MeshPlatformEvent event) {
    switch (event) {
      case MeshPlatformPeerFound():
        _peers[event.peerId] = MeshPeer(
          id: event.peerId,
          name: event.name,
          status: PeerStatus.discovered,
        );
        _emitPeerList();
        // Kick off the backoff loop for the newly-discovered peer.
        // The first attempt is immediate.
        unawaited(_attemptConnect(event.peerId));
      case MeshPlatformPeerConnected():
        _connected.add(event.peerId);
        _backoff.remove(event.peerId)?.timer?.cancel();
        _peers[event.peerId] = (_peers[event.peerId] ??
                MeshPeer(id: event.peerId, name: '', status: PeerStatus.connected))
            .copyWith(status: PeerStatus.connected);
        _activePeer ??= event.peerId;
        _emitPeerList();
      case MeshPlatformPeerDisconnected():
        _connected.remove(event.peerId);
        if (_activePeer == event.peerId) _activePeer = null;
        _peers[event.peerId] = (_peers[event.peerId] ??
                MeshPeer(id: event.peerId, name: '', status: PeerStatus.disconnected))
            .copyWith(status: PeerStatus.disconnected);
        _emitPeerList();
        // Re-try the dial after backoff so we re-establish a session
        // if the radio drops us.
        if (_running) {
          _scheduleRetry(event.peerId);
        }
      case MeshPlatformPeerLost():
        _connected.remove(event.peerId);
        if (_activePeer == event.peerId) _activePeer = null;
        _backoff.remove(event.peerId)?.timer?.cancel();
        _peers.remove(event.peerId);
        _emitPeerList();
      case MeshPlatformPayload():
        final msg = tryDecodeMessage(event.bytes);
        if (msg == null) return; // malformed — drop
        if (!_incomingController.isClosed) {
          _incomingController.add(msg);
        }
    }
  }

  void _emitPeerList() {
    if (_peersController.isClosed) return;
    _peersController.add(List<MeshPeer>.unmodifiable(_peers.values));
  }

  // ---------------------------------------------------------------------
  // Internal: connect with backoff
  // ---------------------------------------------------------------------

  Future<void> _attemptConnect(String peerId) async {
    if (_disposed || !_running) return;
    if (_connected.contains(peerId)) return;

    // Move the peer to "connecting" so the UI can show progress.
    final existing = _peers[peerId];
    if (existing != null && existing.status != PeerStatus.connecting) {
      _peers[peerId] = existing.copyWith(status: PeerStatus.connecting);
      _emitPeerList();
    }

    final state = _backoff.putIfAbsent(
      peerId,
      () => _BackoffState(),
    );

    try {
      await _platform.connect(peerId);
      // Success path: the platform will emit `PeerConnected` and we'll
      // clear the backoff state there.
      state.attempts += 1;
    } catch (_) {
      state.attempts += 1;
      if (_running && !_connected.contains(peerId)) {
        _scheduleRetry(peerId);
      }
    }
  }

  void _scheduleRetry(String peerId) {
    final state = _backoff[peerId];
    if (state == null) return;
    // Delay before the *next* retry = backoff(attempts already made).
    // After the first failure we've made 1 attempt, so retry #2 waits
    // backoffMsForAttempt(1) = 1s. After retry #2 fails we've made 2
    // attempts and the next retry waits 2s. Etc.
    final delayMs = backoffMsForAttempt(state.attempts);
    state.timer?.cancel();
    state.timer = Timer(Duration(milliseconds: delayMs), () {
      if (_disposed || !_running) return;
      if (_connected.contains(peerId)) return;
      unawaited(_attemptConnect(peerId));
    });
  }
}

class _BackoffState {
  int attempts = 0;
  Timer? timer;
}
