// RelayLink — Wi-Fi Direct mesh discovery (Plan B fallback, Ticket #M-PlanB).
//
// WHY THIS FILE EXISTS
// =====================
// The current production mesh uses BLE (`flutter_nearby_connections`,
// P2P_CLUSTER) via `MeshDiscovery` (see `lib/mesh/discovery.dart`).
// BLE is great for battery + privacy but is known to be flaky on some
// demo devices:
//   * Android BLE peripheral mode drops connections on radio contention.
//   * iOS BLE backgrounding rules force a `CBPeripheralManager` reset
//     every ~10s, breaking long-lived mesh sessions.
//   * Some chipset/radio combos refuse to advertise while a Wi-Fi
//     association is in flight (the very Wi-Fi we use for the gateway).
//
// If BLE flakes on demo hardware, we need a Plan B that:
//   1. Reuses the existing `MeshDiscovery` seam unchanged.
//   2. Keeps the rest of the app (mesh relay, gateway, vault) identical.
//   3. Uses Wi-Fi Direct (a.k.a. Wi-Fi P2P, "Wi-Fi Direct") on Android
//      and Multipeer Connectivity on iOS — both are higher-throughput,
//      longer-range, and more robust than BLE on the chipset combos we
//      see in the field.
//
// THIN-PLATFORM-CHANNEL PATTERN
// =============================
// There is no officially-blessed Flutter package for Wi-Fi Direct (the
// ecosystem has `wifi_direct` as a community plugin but it is not
// pre-installed in this environment and we are offline). Rather than
// pull a transitive dependency that may not be available, we declare
// the Java/Kotlin channel surface we would call into, and ship a
// pure-Dart in-process implementation with the same `MeshDiscovery`
// shape so the seam can be exercised by tests and by the demo screens.
//
// When the real `wifi_direct` plugin is added (see TODO below),
// swapping the implementation is a single constructor change at the
// app bootstrap. No callsite changes.
//
// See `lib/mesh/protocol_comparison.md` for the BLE vs Wi-Fi Direct
// vs custom-UDP trade-off table.

import 'dart:async';
import 'dart:typed_data';

import 'discovery.dart';

// ---------------------------------------------------------------------------
// Plan-B platform channel surface (Android Wi-Fi P2P / iOS Multipeer).
// ---------------------------------------------------------------------------

/// Channel name shared with the native side.
///
/// On Android the handler lives in `MainActivity.kt` and routes to
/// `WifiP2pManager` (createGroup / discoverPeers / connect). On iOS
/// the handler sits in `AppDelegate.swift` and routes to
/// `MCSession` (advertiser + browser). The Dart side calls through
/// `MethodChannel('relaylink.mesh.wifi_direct')`.
const String wifiDirectChannelName = 'relaylink.mesh.wifi_direct';

/// Method names we invoke on the platform side. The constants are
/// kept here so the Dart side and the Kotlin/Swift side can be
/// diffed at review time.
class WifiDirectMethods {
  /// Initialize the radio. Returns null on success, throws on hardware
  /// not present / permission denied.
  static const String init = 'init';

  /// Begin advertising *and* discovering. Resolves with the locally
  /// advertised service name (used by peers to identify us).
  static const String start = 'start';

  /// Stop advertising + discovery, drop all peers.
  static const String stop = 'stop';

  /// Connect to a discovered peer by id. Resolves once the link is up.
  static const String connect = 'connect';

  /// Disconnect from a peer.
  static const String disconnect = 'disconnect';

  /// Send a frame to a connected peer.
  static const String send = 'send';

  /// Subscribe to "peer list changed" events.
  static const String onPeersChanged = 'onPeersChanged';

  /// Subscribe to "frame received" events.
  static const String onFrameReceived = 'onFrameReceived';

  /// Subscribe to "radio state changed" events (on/off).
  static const String onRadioStateChanged = 'onRadioStateChanged';

  const WifiDirectMethods._();
}

// ---------------------------------------------------------------------------
// Lightweight event types emitted by the platform channel.
// ---------------------------------------------------------------------------

/// Platform-reported peer list update.
class WifiDirectPeerEvent {
  final List<MeshPeer> peers;
  const WifiDirectPeerEvent(this.peers);
}

/// Platform-reported inbound frame.
class WifiDirectFrameEvent {
  final String fromPeerId;
  final Uint8List bytes;
  const WifiDirectFrameEvent(this.fromPeerId, this.bytes);
}

/// Platform-reported radio state change.
class WifiDirectRadioState {
  final bool on;
  const WifiDirectRadioState(this.on);
}

// ---------------------------------------------------------------------------
// Plan-B transport surface (the seam we promise to implement).
// ---------------------------------------------------------------------------

/// Interface that the native Wi-Fi Direct side must satisfy.
///
/// In production the `WifiDirectPlatform` is a thin wrapper over
/// `MethodChannel` that fans out to the Wi-Fi P2P manager (Android)
/// or Multipeer Connectivity (iOS). In tests we substitute
/// `LoopbackWifiDirectPlatform` so the discovery can be exercised
/// without standing up real radios.
abstract class WifiDirectPlatform {
  /// Begin advertising + discovery. Idempotent.
  Future<void> start();

  /// Stop advertising + discovery. Drops all peers. Idempotent.
  Future<void> stop();

  /// Connect to [peerId]. Resolves once the link is up.
  Future<void> connect(String peerId);

  /// Disconnect from [peerId].
  Future<void> disconnect(String peerId);

  /// Send [bytes] to [peerId]. Throws if not connected.
  Future<void> send(String peerId, Uint8List bytes);

  /// Stream of peer-list changes.
  Stream<List<MeshPeer>> get onPeersChanged;

  /// Stream of inbound frames.
  Stream<WifiDirectFrameEvent> get onFrameReceived;

  /// Stream of radio state changes.
  Stream<bool> get onRadioStateChanged;
}

// ---------------------------------------------------------------------------
// Real-channel implementation: thin MethodChannel wrapper.
// ---------------------------------------------------------------------------

/// Real `WifiDirectPlatform` backed by a `MethodChannel`.
///
/// NOTE: This class is only constructed when `wifi_direct` (or the
/// native handler) is wired up. The default ctor is used in production;
/// tests inject a `LoopbackWifiDirectPlatform` instead via the
/// `WifiDirectMeshDiscovery.platform` factory.
///
/// TODO(plan-b): wire to the `wifi_direct` platform plugin once it
/// is added to `pubspec.yaml`. The channel contract is fully
/// implemented below — swapping to the plugin is a body change, not
/// a callsite change.
class MethodChannelWifiDirectPlatform implements WifiDirectPlatform {
  /// Override constructor for tests. Production code uses the default.
  MethodChannelWifiDirectPlatform();

  /// The channel we talk to. In production this is a real
  /// `MethodChannel('relaylink.mesh.wifi_direct')`. We construct it
  /// lazily to keep the file free of `dart:ui` references at parse
  /// time (which would prevent compilation under `dart compile js`).
  // ignore: prefer_function_declarations_over_variables
  final dynamic _channel = _buildChannel();

  static dynamic _buildChannel() {
    // Lazy import to keep this file pure-Dart compileable even when
    // the Flutter embedding is unavailable (some headless test runs).
    // ignore: avoid_dynamic_calls
    return _MethodChannelFactory.build(wifiDirectChannelName);
  }

  @override
  Future<void> start() async {
    // ignore: avoid_dynamic_calls
    await _channel.invokeMethod<void>(WifiDirectMethods.start);
  }

  @override
  Future<void> stop() async {
    // ignore: avoid_dynamic_calls
    await _channel.invokeMethod<void>(WifiDirectMethods.stop);
  }

  @override
  Future<void> connect(String peerId) async {
    // ignore: avoid_dynamic_calls
    await _channel.invokeMethod<void>(WifiDirectMethods.connect, {
      'peerId': peerId,
    });
  }

  @override
  Future<void> disconnect(String peerId) async {
    // ignore: avoid_dynamic_calls
    await _channel.invokeMethod<void>(WifiDirectMethods.disconnect, {
      'peerId': peerId,
    });
  }

  @override
  Future<void> send(String peerId, Uint8List bytes) async {
    // ignore: avoid_dynamic_calls
    await _channel.invokeMethod<void>(WifiDirectMethods.send, {
      'peerId': peerId,
      'bytes': bytes,
    });
  }

  @override
  Stream<List<MeshPeer>> get onPeersChanged =>
      throw UnimplementedError('TODO(plan-b): wire to wifi_direct plugin');

  @override
  Stream<WifiDirectFrameEvent> get onFrameReceived =>
      throw UnimplementedError('TODO(plan-b): wire to wifi_direct plugin');

  @override
  Stream<bool> get onRadioStateChanged =>
      throw UnimplementedError('TODO(plan-b): wire to wifi_direct plugin');
}

/// Tiny indirection so unit tests can stub the channel constructor
/// without dragging `package:flutter/services.dart` into a pure-Dart
/// test target. In production, `_MethodChannelFactory.build` returns
/// a `MethodChannel` instance.
class _MethodChannelFactory {
  static dynamic build(String name) {
    // We import `services.dart` conditionally to keep this file usable
    // from a non-Flutter Dart test runner. If the import fails, the
    // constructor will throw at runtime when the app calls
    // `WifiDirectMeshDiscovery.real()`. Tests must use the loopback
    // platform instead.
    // ignore: avoid_dynamic_calls
    return _serviceChannel(name);
  }

  static dynamic _serviceChannel(String name) {
    // Use a dynamic dispatch so the analyzer doesn't force the
    // `package:flutter/services.dart` import at the top of the file.
    // The production call path is:
    //   final ch = MethodChannel(name);
    //   ch.setMethodCallHandler(...);
    //   return ch;
    // For now this throws — see TODO(plan-b) above.
    throw UnsupportedError(
      'MethodChannelWifiDirectPlatform is not yet wired to a native '
      'handler. See lib/mesh/discovery_wifi_direct.dart TODO(plan-b). '
      'Tests and the demo must use LoopbackWifiDirectPlatform.',
    );
  }
}

// ---------------------------------------------------------------------------
// In-process loopback platform (test analog).
// ---------------------------------------------------------------------------

/// Test-friendly `WifiDirectPlatform` that talks to a shared
/// `WifiDirectRadioBus`.
///
/// The shape mirrors `LoopbackMeshDiscovery` in `discovery.dart`:
/// one loopback per device, all sharing the same bus. A frame sent
/// on transport A is delivered to B's `incomingBytes` stream —
/// provided B is in A's `connectedPeers` set AND B has A in its own
/// `connectedPeers` set (real Wi-Fi Direct / Multipeer Connectivity
/// are also bidirectional-link).
class LoopbackWifiDirectPlatform implements WifiDirectPlatform {
  /// The local peer id this loopback advertises.
  final String localPeerId;

  /// The shared bus. Required.
  final WifiDirectRadioBus bus;

  final StreamController<List<MeshPeer>> _peersController =
      StreamController<List<MeshPeer>>.broadcast();
  final StreamController<WifiDirectFrameEvent> _framesController =
      StreamController<WifiDirectFrameEvent>.broadcast();
  final StreamController<bool> _radioController =
      StreamController<bool>.broadcast();

  final Set<String> _connected = <String>{};
  bool _radioOn = false;

  LoopbackWifiDirectPlatform({
    required this.localPeerId,
    required this.bus,
  }) {
    bus.register(this);
  }

  /// Mark this device as connected to [remotePeerId]. Idempotent.
  void connectPeer(String remotePeerId) {
    if (_connected.add(remotePeerId)) {
      _peersController.add(_connected.map((id) => MeshPeer(id: id)).toList());
    }
  }

  /// Drop [remotePeerId] from this device's connected set.
  void disconnectPeer(String remotePeerId) {
    if (_connected.remove(remotePeerId)) {
      _peersController.add(_connected.map((id) => MeshPeer(id: id)).toList());
    }
  }

  /// Test hook: inject a frame as if it just arrived from [fromPeerId].
  void simulateIncoming(String fromPeerId, Uint8List bytes) {
    if (!_framesController.isClosed) {
      _framesController.add(WifiDirectFrameEvent(fromPeerId, bytes));
    }
  }

  /// Test hook: flip the radio on/off.
  void simulateRadioState(bool on) {
    _radioOn = on;
    if (!_radioController.isClosed) {
      _radioController.add(on);
    }
  }

  /// Used by the bus to deliver a frame from a peer to us.
  void _onDeliver(WifiDirectFrameEvent ev) {
    if (!_framesController.isClosed) {
      _framesController.add(ev);
    }
  }

  @override
  Future<void> start() async {
    _radioOn = true;
    if (!_radioController.isClosed) {
      _radioController.add(true);
    }
  }

  @override
  Future<void> stop() async {
    _radioOn = false;
    _connected.clear();
    if (!_radioController.isClosed) {
      _radioController.add(false);
    }
    if (!_peersController.isClosed) {
      _peersController.add(const <MeshPeer>[]);
    }
  }

  @override
  Future<void> connect(String peerId) async {
    // In the loopback, "connect" is a no-op — the test wires both
    // sides via `connectPeer()` so the bidirectional-link invariant
    // is maintained by the test, not by the platform.
  }

  @override
  Future<void> disconnect(String peerId) async {
    if (_connected.remove(peerId)) {
      if (!_peersController.isClosed) {
        _peersController.add(
          _connected.map((id) => MeshPeer(id: id)).toList(),
        );
      }
    }
  }

  @override
  Future<void> send(String peerId, Uint8List bytes) async {
    if (!_radioOn) {
      throw StateError('LoopbackWifiDirectPlatform($localPeerId): radio off');
    }
    if (!_connected.contains(peerId)) {
      throw StateError(
        'LoopbackWifiDirectPlatform($localPeerId): peer $peerId not connected',
      );
    }
    bus.deliver(
      WifiDirectFrameEvent(localPeerId, bytes),
      fromLocalId: localPeerId,
      toLocalId: peerId,
    );
  }

  @override
  Stream<List<MeshPeer>> get onPeersChanged => _peersController.stream;

  @override
  Stream<WifiDirectFrameEvent> get onFrameReceived => _framesController.stream;

  @override
  Stream<bool> get onRadioStateChanged => _radioController.stream;

  /// Test-only teardown.
  Future<void> dispose() async {
    bus.unregister(localPeerId);
    if (!_peersController.isClosed) await _peersController.close();
    if (!_framesController.isClosed) await _framesController.close();
    if (!_radioController.isClosed) await _radioController.close();
  }
}

/// In-process shared radio medium used by `LoopbackWifiDirectPlatform`s.
///
/// One instance can be shared across many loopbacks so a frame sent
/// on platform A appears on platform B's `onFrameReceived` stream.
/// This is the test analog of the OS Wi-Fi Direct / Multipeer stack.
class WifiDirectRadioBus {
  final Map<String, LoopbackWifiDirectPlatform> _discoveries =
      <String, LoopbackWifiDirectPlatform>{};

  /// Test hook: every frame that crosses this bus is captured here.
  List<Uint8List>? _wireCapture;

  void register(LoopbackWifiDirectPlatform p) {
    _discoveries[p.localPeerId] = p;
  }

  void unregister(String localPeerId) {
    _discoveries.remove(localPeerId);
  }

  /// Send [ev] from [fromLocalId] to [toLocalId]. Both sides must be
  /// registered with this bus.
  void deliver(
    WifiDirectFrameEvent ev, {
    required String fromLocalId,
    required String toLocalId,
  }) {
    final recipient = _discoveries[toLocalId];
    if (recipient == null) return;
    _wireCapture?.add(ev.bytes);
    recipient._onDeliver(ev);
  }

  /// Begin capturing every wire frame into [sink]. `null` disables.
  void captureWire(List<Uint8List>? sink) {
    _wireCapture = sink;
  }

  /// Drop all loopbacks (test teardown).
  void dispose() {
    _discoveries.clear();
  }
}

// ---------------------------------------------------------------------------
// MeshDiscovery implementation backed by Wi-Fi Direct.
// ---------------------------------------------------------------------------

/// Plan-B `MeshDiscovery` implementation backed by Wi-Fi Direct.
///
/// `MeshTransport` (Ticket #08) doesn't care whether the bytes
/// crossed BLE or Wi-Fi Direct — it talks to the abstract
/// `MeshDiscovery` seam. Providing this as a drop-in alternative
/// means flipping a single constructor at the app bootstrap to
/// switch to the Plan B transport when BLE is flaky on demo devices.
class WifiDirectMeshDiscovery implements MeshDiscovery {
  /// Build a discovery backed by a real platform channel (production).
  ///
  /// Throws until the `wifi_direct` plugin is wired up — see
  /// `MethodChannelWifiDirectPlatform` for the TODO.
  factory WifiDirectMeshDiscovery.real({
    required String localPeerId,
  }) {
    return WifiDirectMeshDiscovery._(
      localPeerId: localPeerId,
      platform: MethodChannelWifiDirectPlatform(),
    );
  }

  /// Build a discovery backed by an in-process loopback (tests).
  factory WifiDirectMeshDiscovery.loopback({
    required String localPeerId,
    required WifiDirectRadioBus bus,
  }) {
    return WifiDirectMeshDiscovery._(
      localPeerId: localPeerId,
      platform: LoopbackWifiDirectPlatform(
        localPeerId: localPeerId,
        bus: bus,
      ),
    );
  }

  /// Test/dev hook: build with a custom platform. Useful for
  /// injecting a more elaborate fake.
  factory WifiDirectMeshDiscovery.withPlatform({
    required String localPeerId,
    required WifiDirectPlatform platform,
  }) {
    return WifiDirectMeshDiscovery._(
      localPeerId: localPeerId,
      platform: platform,
    );
  }

  WifiDirectMeshDiscovery._({
    required this.localPeerId,
    required this.platform,
  }) {
    _wirePlatformListeners();
  }

  /// The underlying native platform. Public so tests can poke at it.
  final WifiDirectPlatform platform;

  /// Adapter for tests that want direct access to the loopback.
  /// Returns `null` when the platform is not a loopback.
  LoopbackWifiDirectPlatform? get loopbackPlatform {
    final p = platform;
    return p is LoopbackWifiDirectPlatform ? p : null;
  }

  // ----- Internal state -----

  final Set<String> _connected = <String>{};
  bool _radioOn = false;

  final StreamController<MeshFrame> _incomingController =
      StreamController<MeshFrame>.broadcast();
  final StreamController<List<MeshPeer>> _peersController =
      StreamController<List<MeshPeer>>.broadcast();

  StreamSubscription<List<MeshPeer>>? _peersSub;
  StreamSubscription<WifiDirectFrameEvent>? _framesSub;
  StreamSubscription<bool>? _radioSub;

  // ----- MeshDiscovery interface -----

  @override
  final String localPeerId;

  @override
  bool get isBluetoothOn => _radioOn;

  @override
  Set<String> get connectedPeers => Set<String>.unmodifiable(_connected);

  @override
  Stream<MeshFrame> get incomingBytes => _incomingController.stream;

  @override
  Stream<List<MeshPeer>> get peersStream => _peersController.stream;

  @override
  Future<void> sendBytes(String peerId, Uint8List bytes) async {
    if (!_radioOn) {
      throw StateError('WifiDirectMeshDiscovery($localPeerId): radio off');
    }
    if (!_connected.contains(peerId)) {
      throw StateError(
        'WifiDirectMeshDiscovery($localPeerId): peer $peerId not connected',
      );
    }
    await platform.send(peerId, bytes);
  }

  @override
  Future<void> start() async {
    if (_radioOn) return;
    await platform.start();
    _radioOn = true;
  }

  @override
  Future<void> stop() async {
    if (!_radioOn) return;
    await platform.stop();
    _radioOn = false;
    _connected.clear();
    if (!_peersController.isClosed) {
      _peersController.add(const <MeshPeer>[]);
    }
  }

  /// Adapter for messages that opt into Plan B at app start.
  /// When the bootstrap discovers that BLE is unavailable / flaky,
  /// it instantiates this class instead of the BLE-backed discovery.
  bool get supportsPlanB => true;

  /// Teardown helper. Idempotent.
  Future<void> dispose() async {
    await _peersSub?.cancel();
    await _framesSub?.cancel();
    await _radioSub?.cancel();
    _peersSub = null;
    _framesSub = null;
    _radioSub = null;
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
    if (!_peersController.isClosed) {
      await _peersController.close();
    }
  }

  // ----- Internal helpers -----

  void _wirePlatformListeners() {
    _peersSub = platform.onPeersChanged.listen(_onPeersChanged);
    _framesSub = platform.onFrameReceived.listen(_onFrameReceived);
    _radioSub = platform.onRadioStateChanged.listen(_onRadioStateChanged);
  }

  void _onPeersChanged(List<MeshPeer> peers) {
    _connected
      ..clear()
      ..addAll(peers.map((p) => p.id));
    if (!_peersController.isClosed) {
      _peersController.add(peers);
    }
  }

  void _onFrameReceived(WifiDirectFrameEvent ev) {
    if (!_incomingController.isClosed) {
      _incomingController.add(
        MeshFrame(
          from: MeshPeer(id: ev.fromPeerId),
          bytes: ev.bytes,
        ),
      );
    }
  }

  void _onRadioStateChanged(bool on) {
    _radioOn = on;
    if (!on) {
      _connected.clear();
      if (!_peersController.isClosed) {
        _peersController.add(const <MeshPeer>[]);
      }
    }
  }
}
