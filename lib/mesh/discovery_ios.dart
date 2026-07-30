// RelayLink — iOS Multipeer Connectivity wrapper for mesh discovery.
//
// This file is the iOS counterpart of `lib/mesh/discovery.dart` (the
// Android Nearby-Connections wrapper produced by Ticket #07). It exposes:
//
//   * [MultipeerDiscoveryPlatform] — the `MeshDiscoveryPlatform`-shaped
//     class that future Multipeer-Connectivity wiring will plug into.
//   * [MultipeerDiscovery] — the iOS-flavored [MeshDiscovery] subclass.
//     It has the same public API as the Ticket #07 transport (start /
//     stop / peers / connectPeer / disconnectPeer / send / incoming /
//     isAvailable / ensurePermissions / encodeMessage /
//     tryDecodeMessage), so iOS callers plug into [TransportManager]
//     with a single-line change.
//   * [StubMultipeerDiscoveryPlatform] — the offline-development default.
//     It behaves identically to [StubMeshDiscoveryPlatform] but tags the
//     radio as "iOS Multipeer pending" so telemetry can tell which
//     platform was selected.
//
// STATUS: this ticket is the SEAM. The real `nearby_connections` plugin
// on iOS surfaces its Multipeer-Connectivity backend through the same
// `MeshDiscoveryPlatform` interface as Android. We deliberately do not
// add `nearby_connections` (or `flutter_multipeer`) to `pubspec.yaml`
// during the offline build — the real plugin's iOS podspec requires
// Xcode toolchain access that is not available in the sandbox.
//
// When a real iOS build target is in scope:
//
//   1. Add to `pubspec.yaml`:
//        dependencies:
//          nearby_connections: ^x.y.z
//      (https://pub.dev/packages/nearby_connections — the same package
//      that backs the Android path; on iOS it routes through
//      `MultipeerConnectivity`.)
//   2. Replace [StubMultipeerDiscoveryPlatform] below with a real
//      implementation that subscribes to `NearbyConnections` streams
//      and translates its events into the
//      [MeshPlatformPeerFound] / [PeerLost] / [PeerConnected] /
//      [PeerDisconnected] / [Payload] sealed-class cases declared in
//      `lib/mesh/discovery.dart`.
//   3. Wire the platform-side `Info.plist` keys:
//        NSLocalNetworkUsageDescription
//        NSBonjourServices           (array, must include the
//                                      service name from
//                                      [kRelayLinkServiceName]).
//   4. Update `lib/main.dart` to select [MultipeerDiscovery] when
//      `Platform.isIOS` is true and [MeshDiscovery] otherwise.
//
// CONTRACT (mirrors `lib/mesh/discovery.dart` so the iOS path is
// drop-in equivalent to the Android path):
//   * `start()` advertises AND scans.
//   * `stop()` halts both.
//   * `peers` stream emits on every peer-state change.
//   * `connectPeer(id)` backs off exponentially (1s, 2s, 4s, …, capped
//     at 30s) on failure — semantics inherited verbatim from
//     [MeshDiscovery].
//   * `isAvailable()` is `true` iff the radio is on AND permission was
//     granted.
//   * `send` / `incoming` / `name` come from the [Transport] interface.

import 'dart:async';
import 'dart:typed_data';

import '../models/message.dart';
import 'discovery.dart';

/// The default iOS Multipeer Connectivity service type.
///
/// Apple's Multipeer Connectivity framework requires a service type that
/// is 1–15 characters long, ASCII, lowercase letters/digits/hyphens,
/// conventionally reverse-DNS-style. This mirrors
/// [kRelayLinkServiceName] in `lib/mesh/discovery.dart` so both
/// platforms advertise the same logical mesh.
const String kRelayLinkMultipeerServiceType = 'relaylink-mesh';

/// Default display name advertised by this device on the iOS mesh.
/// Multipeer Connectivity's `MCPeerID.displayName` is limited to
/// UTF-8 strings; we keep it short so it fits inside the 63-byte limit
/// of the underlying `Bonjour` TXT record when running on older iOS
/// versions.
const String kRelayLinkDefaultMultipeerDisplayName = 'RelayLink-iOS';

/// iOS-flavored [MeshDiscoveryPlatform]. The default concrete
/// implementation is [StubMultipeerDiscoveryPlatform] (no radio) until
/// the real `nearby_connections` plugin lands on iOS — see the file
/// header for the migration plan.
class MultipeerDiscoveryPlatform implements MeshDiscoveryPlatform {
  /// Build a platform impl. Tests inject a subclass or a fake; production
  /// uses the default constructor which returns a stub.
  const MultipeerDiscoveryPlatform();

  // ---- Radio / permission state -----------------------------------
  //
  // Both flags default to `false` so `isAvailable()` is `false` until a
  // real platform impl wires them to the OS state (CBRadios in
  // `CoreBluetooth`, `MCNearbyServiceAdvertiser` accessibility in
  // `MultipeerConnectivity`, plus the local-network / Bonjour
  // permission prompts surfaced by iOS 14+).

  /// Whether the underlying radio is powered on.
  @override
  bool get isBluetoothEnabled => false;

  /// Whether the user has granted the local-network / Bonjour /
  /// Multipeer permission.
  @override
  bool get hasPermissions => false;

  /// Prompt for the iOS local-network / Multipeer permission. The
  /// default stub returns `false` so callers know the radio is not
  /// yet wired.
  @override
  Future<bool> requestPermissions() async => false;

  // ---- Advertise / discover --------------------------------------

  @override
  Future<void> startAdvertising({required String serviceName}) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> startDiscovery({required String serviceName}) async {}

  @override
  Future<void> stopDiscovery() async {}

  // ---- Connect / disconnect / send -------------------------------

  @override
  Future<void> connect(String peerId) async {
    throw StateError(
      'MultipeerDiscoveryPlatform: real iOS implementation deferred. '
      'See lib/mesh/discovery_ios.dart for migration notes '
      '(https://pub.dev/packages/nearby_connections).',
    );
  }

  @override
  Future<void> disconnect(String peerId) async {}

  @override
  Future<void> sendPayload(String peerId, Uint8List bytes) async {}

  /// No events emitted by the stub. The real platform's `MCSession`
  /// / `MCSessionDelegate` callbacks translate directly into the
  /// [MeshPlatformPeerFound] / [PeerLost] / [PeerConnected] /
  /// [PeerDisconnected] / [Payload] cases.
  @override
  Stream<MeshPlatformEvent> get events =>
      const Stream<MeshPlatformEvent>.empty();
}

/// Alias so the iOS stub is discoverable in the codebase.
///
/// This is identical to [MultipeerDiscoveryPlatform] today, but kept as
/// a distinct type-name so future telemetry that wants to distinguish
/// "the iOS stub" from "the Android stub" can do so without comparing
/// [StubMeshDiscoveryPlatform] and [MultipeerDiscoveryPlatform] by
/// `runtimeType`.
class StubMultipeerDiscoveryPlatform extends MultipeerDiscoveryPlatform {
  const StubMultipeerDiscoveryPlatform();
}

/// iOS discovery + connect + send/receive.
///
/// Subclasses [MeshDiscovery] so it inherits:
///   * the [Transport] implementation (send / incoming / name /
///     isAvailable),
///   * the connect-with-backoff state machine,
///   * the `peers` snapshot stream + per-event emission,
///   * the JSON wire format helpers ([MeshDiscovery.encodeMessage] /
///     [MeshDiscovery.tryDecodeMessage]).
///
/// Constructor chooses the platform impl:
///   * `MultipeerDiscovery()` (default) — non-functional stub.
///   * `MultipeerDiscovery(platform: myFake)` — test injection.
///
/// Migration is a single substitution: the production caller swaps
/// `MeshDiscovery(platform: MeshDiscoveryPlatformFactory.android())`
/// for `MultipeerDiscovery(platform: myMCPeerSessionBackedPlatform)`
/// based on `Platform.isIOS`. No other call sites change.
class MultipeerDiscovery extends MeshDiscovery {
  /// Build an iOS discovery. Defaults to the offline stub. Tests
  /// inject a custom [MeshDiscoveryPlatform].
  MultipeerDiscovery({
    MeshDiscoveryPlatform? platform,
    super.serviceName = kRelayLinkServiceName,
    this.displayName = kRelayLinkDefaultMultipeerDisplayName,
  }) : super(
          platform: platform ?? const StubMultipeerDiscoveryPlatform(),
        );

  /// Display name this device advertises as on the iOS mesh. (Not
  /// consumed by the stub — held for the real Multipeer Connectivity
  /// wiring so callers can pre-configure it.)
  final String displayName;

  /// The platform backing this discovery. Exposed so iOS-specific
  /// diagnostics (e.g. "which Bonjour service type is this device
  /// advertising?") can introspect the runtime impl.
  MeshDiscoveryPlatform get iosPlatform => platform;

  /// Convenience: build a platform impl advertising the canonical
  /// RelayLink iOS Bonjour service type. Equivalent to passing
  /// `platform: MultipeerDiscoveryPlatform()`.
  factory MultipeerDiscovery.iosDefault({
    String serviceName = kRelayLinkServiceName,
    String displayName = kRelayLinkDefaultMultipeerDisplayName,
  }) {
    return MultipeerDiscovery(
      platform: const StubMultipeerDiscoveryPlatform(),
      serviceName: serviceName,
      displayName: displayName,
    );
  }

  // ---------------------------------------------------------------------
  // Static wire-format helpers — Dart does not inherit static members
  // across subclass boundaries, so we re-export the Android-side helpers
  // here so the iOS seam has the same call surface as the Android seam.
  // Tests / gateway relay can wire either transport using the same
  // `MultipeerDiscovery.encodeMessage(msg)` /
  // `MultipeerDiscovery.tryDecodeMessage(bytes)` calls.
  // ---------------------------------------------------------------------

  /// JSON-encode [msg] using [Message.toJson]'s map and UTF-8 bytes.
  /// Static forwarder to [MeshDiscovery.encodeMessage].
  static Uint8List encodeMessage(Message msg) =>
      MeshDiscovery.encodeMessage(msg);

  /// Inverse of [encodeMessage]. Returns `null` if the bytes are
  /// malformed (rather than throwing) so the [incoming] stream can
  /// drop bad envelopes without closing.
  /// Static forwarder to [MeshDiscovery.tryDecodeMessage].
  static Message? tryDecodeMessage(Uint8List bytes) =>
      MeshDiscovery.tryDecodeMessage(bytes);

  /// Same permission rationale the Android side exposes via
  /// [MeshDiscovery.permissionRationale]. Re-exported so `MultipeerDiscovery`
  /// is a drop-in replacement for [MeshDiscovery] in the first-launch UI.
  static const String permissionRationale =
      MeshDiscovery.permissionRationale;
}

/// In-memory loopback transport shim for the iOS seam.
///
/// Mirrors the surface area that the real iOS Multipeer Connectivity
/// platform exposes (the [MeshDiscoveryPlatform] contract), but uses
/// in-memory pipes so tests can drive the discovery end-to-end
/// without a radio. The Android-equivalent test fake is `_FakePlatform`
/// in `test/mesh/discovery_test.dart`; this one is the iOS counterpart
/// and is used by `test/mesh/discovery_ios_test.dart` to verify the
/// [MultipeerDiscovery] seam compiles, the constructor wires the
/// platform impl correctly, and the subclass invariants hold.
///
/// Why a "loopback" fake?
///   * It exercises the same [MeshDiscoveryPlatform] surface the real
///     `nearby_connections` plugin talks to (peer-found / lost /
///     connected / disconnected / payload), so any contract drift
///     between the iOS seam and the iOS platform impl is caught
///     immediately.
///   * It is deterministic — no radio collisions in CI.
///   * Tests can observe peer connect / disconnect events without
///     standing up a multipeer session.
class LoopbackMultipeerDiscovery implements MeshDiscoveryPlatform {
  /// Whether the radio is reported as enabled.
  bool bluetoothEnabled;

  /// Whether the local-network permission is reported as granted.
  bool permissionsGranted;

  /// `true` once [startAdvertising] has fired (used by tests).
  bool advertising = false;

  /// `true` once [startDiscovery] has fired (used by tests).
  bool discovering = false;

  /// Peers the fake has been asked to dial. Most-recent last.
  final List<String> connectAttempts = <String>[];

  /// Peers the fake has been asked to hang up on. Most-recent last.
  final List<String> disconnectCalls = <String>[];

  /// `(peerId, bytes)` tuples the fake has been asked to ship.
  final List<({String peerId, Uint8List bytes})> sentPayloads =
      <({String peerId, Uint8List bytes})>[];

  /// Sequence of `(ok, fail)` results for `connect()`. Each call
  /// consumes one entry: `ok=true` -> success, `ok=false` -> throws.
  final List<bool> connectResult = <bool>[];

  /// Whether `connect()` should throw once regardless of
  /// [connectResult]. After the throw the flag auto-resets.
  bool connectThrowsOnce = false;

  final StreamController<MeshPlatformEvent> _events =
      StreamController<MeshPlatformEvent>.broadcast();

  LoopbackMultipeerDiscovery({
    this.bluetoothEnabled = true,
    this.permissionsGranted = true,
  });

  @override
  bool get isBluetoothEnabled => bluetoothEnabled;

  @override
  bool get hasPermissions => permissionsGranted;

  @override
  Future<bool> requestPermissions() async {
    permissionsGranted = true;
    return true;
  }

  @override
  Future<void> startAdvertising({required String serviceName}) async {
    advertising = true;
  }

  @override
  Future<void> stopAdvertising() async {
    advertising = false;
  }

  @override
  Future<void> startDiscovery({required String serviceName}) async {
    discovering = true;
  }

  @override
  Future<void> stopDiscovery() async {
    discovering = false;
  }

  @override
  Future<void> connect(String peerId) async {
    connectAttempts.add(peerId);
    if (connectThrowsOnce) {
      connectThrowsOnce = false;
      throw StateError('connect failed ($peerId)');
    }
    if (connectResult.isNotEmpty) {
      final ok = connectResult.removeAt(0);
      if (!ok) {
        throw StateError('connect failed ($peerId)');
      }
    }
  }

  @override
  Future<void> disconnect(String peerId) async {
    disconnectCalls.add(peerId);
  }

  @override
  Future<void> sendPayload(String peerId, Uint8List bytes) async {
    sentPayloads.add((peerId: peerId, bytes: bytes));
  }

  @override
  Stream<MeshPlatformEvent> get events => _events.stream;

  /// Test helper: emit a peer-found event.
  void emitPeerFound(String peerId, {String name = 'peer'}) {
    _events.add(MeshPlatformPeerFound(peerId, name));
  }

  /// Test helper: emit a peer-lost event.
  void emitPeerLost(String peerId) {
    _events.add(MeshPlatformPeerLost(peerId));
  }

  /// Test helper: emit a peer-connected event.
  void emitPeerConnected(String peerId) {
    _events.add(MeshPlatformPeerConnected(peerId));
  }

  /// Test helper: emit a peer-disconnected event.
  void emitPeerDisconnected(String peerId) {
    _events.add(MeshPlatformPeerDisconnected(peerId));
  }

  /// Test helper: push an incoming payload envelope.
  void emitPayload(String peerId, Uint8List bytes) {
    _events.add(MeshPlatformPayload(peerId, bytes));
  }

  /// Close the underlying event stream. After this the loopback is
  /// single-use; tests typically construct a fresh one per case.
  Future<void> closeEvents() => _events.close();
}
