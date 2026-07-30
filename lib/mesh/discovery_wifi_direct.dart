// RelayLink — Wi-Fi Direct wrapper for mesh discovery (Ticket
// #M-mesh-redo).
//
// Plan B for `cutrev-mesh-planb`. The previous attempt reached for
// `MeshPeer` / `MeshFrame` types and an `incomingBytes` accessor that
// aren't part of the [MeshDiscovery] contract shipped on `main` (merged
// from Ticket #07 as commit `8798e79`). This file is the seam against
// the *actual* merged interface:
//
//   * [WifiDirectPlatform] — a [MeshDiscoveryPlatform]-shaped class
//     that the future `WifiP2pManager` wrapper (Android) will plug
//     into. Mirrors [MultipeerDiscoveryPlatform] for iOS, but with the
//     Wi-Fi-radio vocabulary (`isWifiEnabled`, `requestPermissions`,
//     etc.).
//   * [StubWifiDirectPlatform] — the offline-development default.
//     Behaves identically to [StubMeshDiscoveryPlatform] but tags the
//     radio as "Wi-Fi Direct pending" so telemetry can tell which
//     platform was selected.
//   * [WifiDirectMeshDiscovery] — the Android-flavored [MeshDiscovery]
//     subclass. Same public API as [MeshDiscovery] /
//     [MultipeerDiscovery] so callers can swap a single line.
//   * [LoopbackWifiDirectPlatform] — in-process test fake that
//     round-trips frames so tests can drive the discovery end-to-end
//     without a radio.
//
// CONTRACT (mirrors `lib/mesh/discovery.dart` so the Wi-Fi Direct path
// is drop-in equivalent to the BLE path):
//   * `start()` advertises AND scans.
//   * `stop()` halts both.
//   * `peers` stream emits on every peer-state change.
//   * `connectPeer(id)` backs off exponentially (1s, 2s, 4s, …, capped
//     at 30s) on failure — semantics inherited verbatim from
//     [MeshDiscovery].
//   * `isAvailable()` is `true` iff the Wi-Fi radio is on AND the user
//     granted the location / nearby-devices permission (Android
//     requires `ACCESS_FINE_LOCATION` for Wi-Fi P2P service discovery).
//   * `send` / `incoming` / `name` come from the [Transport] interface.
//
// STATUS: this ticket is the SEAM. The real `WifiP2pManager` wrapper
// is deferred — see `TODO` notes inline.

import 'dart:async';
import 'dart:typed_data';

import '../models/message.dart';
import 'discovery.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default device name advertised by this device over Wi-Fi P2P.
///
/// Android's `WifiP2pManager.setDeviceName` accepts UTF-8 strings up to
/// 63 bytes (the same limit `Bonjour` TXT records impose on iOS); we
/// keep the default short so it fits.
const String kRelayLinkDefaultWifiDirectDeviceName = 'RelayLink-WD';

/// Permission rationale string for the Wi-Fi Direct platform. This is
/// the same Bluetooth-rationale string used by the BLE transport
/// (Android requires the same Nearby Devices permission for both
/// radios).
const String kRelayLinkWifiDirectPermissionRationale =
    kRelayLinkBluetoothPermissionRationale;

// ---------------------------------------------------------------------------
// Platform abstraction
// ---------------------------------------------------------------------------

/// Wi-Fi-Direct-flavored [MeshDiscoveryPlatform]. The default concrete
/// implementation is [StubWifiDirectPlatform] (no radio) until the real
/// `WifiP2pManager` wrapper lands.
class WifiDirectPlatform implements MeshDiscoveryPlatform {
  /// Build a platform impl. Tests inject a subclass or a fake;
  /// production uses the default constructor which returns a stub.
  const WifiDirectPlatform();

  // ---- Radio / permission state -----------------------------------
  //
  // Both flags default to `false` so `isAvailable()` is `false` until a
  // real platform impl wires them to the OS state (`WifiManager`,
  // `WifiP2pManager.isWifiEnabled`, plus the `ACCESS_FINE_LOCATION`
  // prompt Android shows when service discovery runs).

  /// Whether the device's Wi-Fi radio is powered on. (Wi-Fi P2P is a
  /// subset of Wi-Fi — no Wi-Fi, no Wi-Fi P2P.)
  @override
  bool get isBluetoothEnabled => isWifiEnabled;

  /// Wi-Fi-Direct-specific alias for [isBluetoothEnabled]. Mirrors
  /// `WifiP2pManager.isWifiEnabled`.
  bool get isWifiEnabled => false;

  /// Whether the user has granted `ACCESS_FINE_LOCATION` (Android
  /// requires this for `WifiP2pManager.discoverServices`).
  @override
  bool get hasPermissions => false;

  /// Prompt for the Wi-Fi / location permission. Default stub returns
  /// `false` so callers know the radio is not yet wired.
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

  // ---- Connect / send / events ------------------------------------

  @override
  Future<void> connect(String peerId) async {
    throw StateError(
      'StubWifiDirectPlatform: real Wi-Fi P2P implementation deferred. '
      'Wire WifiP2pManager (Android) before shipping.',
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

/// Alias so the Wi-Fi Direct stub is discoverable in the codebase.
///
/// Identical to [WifiDirectPlatform] today, but kept as a distinct
/// type-name so future telemetry that wants to distinguish "the Wi-Fi
/// Direct stub" from "the BLE stub" can do so without comparing
/// [StubMeshDiscoveryPlatform] and [WifiDirectPlatform] by
/// `runtimeType`.
class StubWifiDirectPlatform extends WifiDirectPlatform {
  const StubWifiDirectPlatform();
}

// ---------------------------------------------------------------------------
// WifiDirectMeshDiscovery — the public Transport implementation
// ---------------------------------------------------------------------------

/// Wi-Fi Direct discovery + connect + send/receive.
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
///   * `WifiDirectMeshDiscovery()` (default) — non-functional stub.
///   * `WifiDirectMeshDiscovery(platform: myFake)` — test injection.
///
/// Migration is a single substitution: the production caller swaps
/// `MeshDiscovery(platform: realBlePlatform)` for
/// `WifiDirectMeshDiscovery(platform: realWifiDirectPlatform)`. No
/// other call sites change.
class WifiDirectMeshDiscovery extends MeshDiscovery {
  /// Build a Wi-Fi-Direct discovery. Defaults to the offline stub.
  /// Tests inject a custom [MeshDiscoveryPlatform].
  WifiDirectMeshDiscovery({
    MeshDiscoveryPlatform? platform,
    super.serviceName = kRelayLinkServiceName,
    this.deviceName = kRelayLinkDefaultWifiDirectDeviceName,
  }) : super(
          platform: platform ?? const StubWifiDirectPlatform(),
        );

  /// Device name advertised over Wi-Fi P2P. (Not consumed by the stub
  /// — held for the real `WifiP2pManager` wiring so callers can
  /// pre-configure it.)
  final String deviceName;

  /// The platform backing this discovery. Exposed so Android-specific
  /// diagnostics (e.g. "which service discovery key is this device
  /// scanning for?") can introspect the runtime impl.
  MeshDiscoveryPlatform get wifiPlatform => platform;

  /// Convenience: build a platform impl advertising the canonical
  /// RelayLink Wi-Fi Direct service name. Equivalent to passing
  /// `platform: WifiDirectPlatform()`.
  factory WifiDirectMeshDiscovery.wifiDirectDefault({
    String serviceName = kRelayLinkServiceName,
    String deviceName = kRelayLinkDefaultWifiDirectDeviceName,
  }) {
    return WifiDirectMeshDiscovery(
      platform: const StubWifiDirectPlatform(),
      serviceName: serviceName,
      deviceName: deviceName,
    );
  }

  // ---------------------------------------------------------------------
  // Static wire-format helpers — Dart does not inherit static members
  // across subclass boundaries, so we re-export the Android-side helpers
  // here so the Wi-Fi Direct seam has the same call surface as the BLE
  // seam. Tests / gateway relay can wire either transport using the same
  // `WifiDirectMeshDiscovery.encodeMessage(msg)` /
  // `WifiDirectMeshDiscovery.tryDecodeMessage(bytes)` calls.
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

  /// Permission rationale this platform surfaces before requesting
  /// `ACCESS_FINE_LOCATION` / Wi-Fi Direct permissions. Same string the
  /// BLE transport uses so the first-launch UI shows one prompt across
  /// both radios.
  static const String permissionRationale =
      kRelayLinkWifiDirectPermissionRationale;
}

// ---------------------------------------------------------------------------
// LoopbackWifiDirectPlatform — in-process test fake
// ---------------------------------------------------------------------------

/// In-memory loopback transport shim for the Wi-Fi Direct seam.
///
/// Mirrors the surface area that the real Android `WifiP2pManager`
/// wrapper exposes (the [MeshDiscoveryPlatform] contract), but uses
/// in-memory pipes so tests can drive the discovery end-to-end without
/// a radio. The Android-equivalent test fake for the BLE transport is
/// `_FakePlatform` in `test/mesh/discovery_test.dart`; the iOS
/// equivalent is `LoopbackMultipeerDiscovery` in
/// `lib/mesh/discovery_ios.dart`. This one is the Wi-Fi Direct
/// counterpart.
///
/// Why a "loopback" fake?
///   * It exercises the same [MeshDiscoveryPlatform] surface the real
///     Android Wi-Fi P2P plugin would talk to (peer-found / lost /
///     connected / disconnected / payload), so any contract drift
///     between the seam and the platform impl is caught immediately.
///   * It is deterministic — no radio collisions in CI.
///   * Tests can observe peer connect / disconnect events without
///     standing up a `WifiP2pManager` session.
///
/// "Round-trips frames in-process" (per the plan-B brief) means
/// `roundTrip(peerId, bytes)` synthesises the same `MeshPlatformPayload`
/// event the real radio would emit on the *receiving* side, so a
/// discovery wired to the same loopback can drive its own `incoming`
/// stream end-to-end in one process.
class LoopbackWifiDirectPlatform implements MeshDiscoveryPlatform {
  /// Whether the Wi-Fi radio is reported as enabled.
  bool wifiEnabled;

  /// Whether the `ACCESS_FINE_LOCATION` permission is reported as
  /// granted.
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

  LoopbackWifiDirectPlatform({
    this.wifiEnabled = true,
    this.permissionsGranted = true,
  });

  @override
  bool get isBluetoothEnabled => wifiEnabled;

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

  /// Round-trip [bytes] as if the platform received them on the wire.
  ///
  /// Synthesises the same [MeshPlatformPayload] event the real Android
  /// Wi-Fi P2P platform would emit on the *receiving* side, so a
  /// [WifiDirectMeshDiscovery] wired to this loopback can drive its
  /// own `incoming` stream end-to-end in one process — no second
  /// discovery needed.
  void roundTrip(String peerId, Uint8List bytes) {
    _events.add(MeshPlatformPayload(peerId, bytes));
  }

  /// Close the underlying event stream. After this the loopback is
  /// single-use; tests typically construct a fresh one per case.
  Future<void> closeEvents() => _events.close();
}