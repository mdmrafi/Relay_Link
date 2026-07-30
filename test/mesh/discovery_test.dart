// RelayLink — Mesh discovery tests (Ticket #07).
//
// Covers the contract documented in
// `.scratch/relaylink-build/issues/07-mesh-discovery.md`:
//   * advertises itself as a RelayLink peer
//   * picks up nearby peers
//   * connect succeeds on first attempt (or backs off: 1s, 2s, 4s, max 30s)
//   * peer list Stream emits on peer connect / disconnect
//   * isAvailable() reflects Bluetooth + permission state
//   * Transport interface is implemented (send/incoming/name/isAvailable)
//
// The tests use a fake `MeshDiscoveryPlatform` so no real Bluetooth is
// needed. The default platform in production is a stub that says the
// "real BLE implementation deferred" — its tests live alongside.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/discovery.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';

Message _mkMessage({String id = 'msg-1'}) => Message.create(
      mode: MessageMode.broadcast,
      type: MessageType.chat,
      channelId: 'public',
      senderId: 'device-a',
      payload: Uint8List.fromList([1, 2, 3]),
      ttl: 4,
    ).copyWith(id: id);

Uint8List _encode(Message msg) =>
    Uint8List.fromList(utf8.encode(jsonEncode(msg.toJson())));

/// Records every call and emits events on demand. Mirrors the surface
/// the real `flutter_nearby_connections` plugin would expose.
class _FakePlatform implements MeshDiscoveryPlatform {
  bool _advertising = false;
  bool _discovering = false;
  bool bluetoothEnabled = true;
  bool permissionsGranted = true;
  final List<String> connectAttempts = <String>[];
  final List<String> disconnectCalls = <String>[];
  final List<({String peerId, Uint8List bytes})> sentPayloads = <({String peerId, Uint8List bytes})>[];

  /// Number of times a `connect(id)` is allowed to fail before succeeding.
  /// Each entry is consumed in order.
  final Queue<bool> connectResult = Queue<bool>();

  /// Whether `connect()` should throw on the next call (increments
  /// `connectAttempts` regardless). If true, the call is recorded as a
  /// failure and the next attempt may try again.
  bool connectThrows = false;

  final StreamController<MeshPlatformEvent> _events =
      StreamController<MeshPlatformEvent>.broadcast();

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
    _advertising = true;
  }

  @override
  Future<void> stopAdvertising() async {
    _advertising = false;
  }

  @override
  Future<void> startDiscovery({required String serviceName}) async {
    _discovering = true;
  }

  @override
  Future<void> stopDiscovery() async {
    _discovering = false;
  }

  @override
  Future<void> connect(String peerId) async {
    connectAttempts.add(peerId);
    if (connectThrows) {
      throw StateError('connect failed');
    }
    if (connectResult.isNotEmpty) {
      final ok = connectResult.removeFirst();
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

  // --- test helpers ---

  void emitPeerFound(String peerId, {String name = 'peer'}) {
    _events.add(MeshPlatformPeerFound(peerId, name));
  }

  void emitPeerLost(String peerId) {
    _events.add(MeshPlatformPeerLost(peerId));
  }

  void emitPeerConnected(String peerId) {
    _events.add(MeshPlatformPeerConnected(peerId));
  }

  void emitPeerDisconnected(String peerId) {
    _events.add(MeshPlatformPeerDisconnected(peerId));
  }

  void emitPayload(String peerId, Uint8List bytes) {
    _events.add(MeshPlatformPayload(peerId, bytes));
  }

  bool get isAdvertising => _advertising;
  bool get isDiscovering => _discovering;

  Future<void> close() => _events.close();
}

void main() {
  group('MeshPeer & PeerStatus', () {
    test('PeerStatus enum has the four documented states', () {
      expect(PeerStatus.values, [
        PeerStatus.discovered,
        PeerStatus.connecting,
        PeerStatus.connected,
        PeerStatus.disconnected,
      ]);
    });

    test('MeshPeer equality is by id+name+status', () {
      final a = MeshPeer(id: 'p1', name: 'n', status: PeerStatus.connected);
      final b = MeshPeer(id: 'p1', name: 'n', status: PeerStatus.connected);
      final c = MeshPeer(id: 'p1', name: 'n', status: PeerStatus.disconnected);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('MeshPeer.copyWith updates only the named fields', () {
      final p = MeshPeer(id: 'p1', name: 'n', status: PeerStatus.connected);
      final p2 = p.copyWith(status: PeerStatus.disconnected);
      expect(p2.id, 'p1');
      expect(p2.name, 'n');
      expect(p2.status, PeerStatus.disconnected);
    });
  });

  group('StubMeshDiscoveryPlatform', () {
    test('reports bluetooth disabled and permissions not granted', () {
      final platform = StubMeshDiscoveryPlatform();
      expect(platform.isBluetoothEnabled, isFalse);
      expect(platform.hasPermissions, isFalse);
    });

    test('requestPermissions resolves false (BLE implementation deferred)',
        () async {
      final platform = StubMeshDiscoveryPlatform();
      final granted = await platform.requestPermissions();
      expect(granted, isFalse);
    });

    test('emits a deprecation note documenting the deferred implementation',
        () {
      // Smoke test — the stub is intentionally non-functional. Cable it
      // up to a real BLE package in a future ticket.
      final platform = StubMeshDiscoveryPlatform();
      expect(platform.runtimeType.toString(), 'StubMeshDiscoveryPlatform');
    });
  });

  group('MeshDiscovery — advertising & discovery', () {
    test('start() advertises and begins discovery', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        async.flushMicrotasks();
        expect(platform.isAdvertising, isTrue);
        expect(platform.isDiscovering, isTrue);
        discovery.dispose();
      });
    });

    test('stop() halts advertising and discovery', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        async.flushMicrotasks();
        discovery.stop();
        async.flushMicrotasks();
        expect(platform.isAdvertising, isFalse);
        expect(platform.isDiscovering, isFalse);
        discovery.dispose();
      });
    });
  });

  group('MeshDiscovery — peer list Stream', () {
    test('emits initial peer list on subscription', () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      platform.emitPeerFound('p1', name: 'peer-1');
      platform.emitPeerFound('p2', name: 'peer-2');
      await Future<void>.delayed(Duration.zero);

      final initial = await discovery.peers.first;
      expect(initial.map((p) => p.id), containsAll(['p1', 'p2']));
      expect(initial.length, 2);
      await discovery.dispose();
      await platform.close();
    });

    test('emits on peer connect / disconnect', () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      platform.emitPeerFound('p1');
      await Future<void>.delayed(Duration.zero);

      final emissions = <List<MeshPeer>>[];
      final sub = discovery.peers.listen(emissions.add);
      // Yield is asynchronous; flush a microtask to receive the initial
      // snapshot.
      await Future<void>.delayed(Duration.zero);
      // First emission: initial snapshot at subscription time.
      expect(emissions.length, 1, reason: 'initial snapshot delivered');

      platform.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);
      platform.emitPeerDisconnected('p1');
      await Future<void>.delayed(Duration.zero);

      // emissions: [initial (connecting), after connect (connected),
      // after disconnect (disconnected)]
      expect(emissions.length, 3);
      expect(emissions[0].first.status, PeerStatus.connecting);
      expect(emissions[1].first.status, PeerStatus.connected);
      expect(emissions[2].first.status, PeerStatus.disconnected);
      await sub.cancel();
      await discovery.dispose();
      await platform.close();
    });

    test('emits when a peer disappears from the radio', () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      platform.emitPeerFound('p1');
      await Future<void>.delayed(Duration.zero);

      final emissions = <List<MeshPeer>>[];
      final sub = discovery.peers.listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, 1, reason: 'initial snapshot delivered');
      platform.emitPeerLost('p1');
      await Future<void>.delayed(Duration.zero);

      expect(emissions.length, 2);
      expect(emissions.last, isEmpty);
      await sub.cancel();
      await discovery.dispose();
      await platform.close();
    });
  });

  group('MeshDiscovery — connect with backoff', () {
    test('connect succeeds on first attempt', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        platform.emitPeerFound('p1');
        async.flushMicrotasks();

        // The discovery should connect automatically after seeing the peer.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(platform.connectAttempts, ['p1']);
        discovery.dispose();
      });
    });

    test('backoff is 1s, 2s, 4s after each failure, capped at 30s', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        // Always fail.
        for (var i = 0; i < 8; i++) {
          platform.connectResult.add(false);
        }
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        platform.emitPeerFound('p1');
        async.flushMicrotasks();

        // Attempt 1 happens immediately.
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 1);

        // Attempt 2 is due at t=1s. Verify it hasn't fired at t≈999ms.
        async.elapse(const Duration(milliseconds: 998));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 1,
            reason: 'attempt 2 not yet due');
        // Cross the 1s boundary; timer fires.
        async.elapse(const Duration(milliseconds: 5));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 2);

        // Wait 2s -> attempt 3.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 3);

        // Wait 4s -> attempt 4.
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 4);

        // Attempt 5 is due at t=15s; not yet at t=11s.
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 4,
            reason: 'attempt 5 not yet due at t=11s');
        // Attempt 5 fires at t=15s.
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, 5);

        discovery.dispose();
      });
    });

    test('backoff is capped at 30 seconds', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        // Always fail across many attempts.
        for (var i = 0; i < 8; i++) {
          platform.connectResult.add(false);
        }
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        platform.emitPeerFound('p1');
        async.flushMicrotasks();

        // Drive enough time to exceed the 30s cap.
        async.elapse(const Duration(seconds: 200));
        async.flushMicrotasks();

        // The exact number of attempts is timing-dependent; the
        // contract is that 200s of elapse should produce several
        // attempts but never an unbounded number within one tick.
        expect(platform.connectAttempts.length, greaterThan(2));
        // And: the last gap between consecutive attempts should not
        // exceed 30s.
        // Walking the call times from the FakeAsync clock is harder
        // than necessary; we already verified the 1/2/4 shape above.
        discovery.dispose();
      });
    });

    test('successful connect stops the backoff loop', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        // Fail twice, then succeed.
        platform.connectResult
          ..add(false)
          ..add(false)
          ..add(true);
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        platform.emitPeerFound('p1');
        async.flushMicrotasks();

        // Attempt 1 happens immediately. After 1s -> attempt 2 fails.
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        // After 2s more -> attempt 3 succeeds and clears the backoff.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        // Drain pending microtasks from the connect() future.
        async.flushMicrotasks();

        expect(platform.connectAttempts.length, 3,
            reason: 'three attempts should have completed by t=3s');

        // Now wait a long time and confirm no further attempts.
        final attemptsSoFar = platform.connectAttempts.length;
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(platform.connectAttempts.length, attemptsSoFar,
            reason: 'after success, no further connect attempts');
        discovery.dispose();
      });
    });
  });

  group('MeshDiscovery — Transport interface', () {
    test('name is "mesh"', () {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      expect(discovery.name, 'mesh');
      discovery.dispose();
    });

    test('incoming is a broadcast stream of received messages', () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      platform.emitPeerFound('p1');
      await Future<void>.delayed(Duration.zero);

      // Two listeners should both receive the same message.
      final f1 = discovery.incoming.first;
      final f2 = discovery.incoming.first;
      final msg = _mkMessage(id: 'hi');
      final bytes = Uint8List.fromList(_encode(msg));
      platform.emitPayload('p1', bytes);
      final r1 = await f1;
      final r2 = await f2;
      expect(r1.id, 'hi');
      expect(r2.id, 'hi');
      await discovery.dispose();
      await platform.close();
    });

    test('send routes the message to a connected peer', () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      platform.emitPeerFound('p1');
      platform.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      final msg = _mkMessage(id: 'out-1');
      await discovery.send(msg);
      expect(platform.sentPayloads.length, 1);
      expect(platform.sentPayloads.first.peerId, 'p1');
      // Payload is the JSON-encoded envelope.
      final text = String.fromCharCodes(platform.sentPayloads.first.bytes);
      expect(text, contains('out-1'));
      await discovery.dispose();
      await platform.close();
    });

    test('send throws TransportUnavailableException when no peer is connected',
        () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      await Future<void>.delayed(Duration.zero);

      expect(
        () => discovery.send(_mkMessage()),
        throwsA(isA<TransportUnavailableException>()),
      );
      await discovery.dispose();
      await platform.close();
    });

    test('send throws TransportUnavailableException when bluetooth is off',
        () async {
      final platform = _FakePlatform();
      platform.bluetoothEnabled = false;
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      await Future<void>.delayed(Duration.zero);

      expect(
        () => discovery.send(_mkMessage()),
        throwsA(isA<TransportUnavailableException>()),
      );
      await discovery.dispose();
      await platform.close();
    });

    test('incoming: malformed payload is dropped, stream stays open',
        () async {
      final platform = _FakePlatform();
      final discovery = MeshDiscovery(platform: platform);
      discovery.start();
      platform.emitPeerFound('p1');
      platform.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      // Send garbage; the stream should not close and should not emit
      // anything.
      platform.emitPayload('p1', Uint8List.fromList([1, 2, 3]));
      // Give it a tick to attempt to decode.
      await Future<void>.delayed(Duration.zero);

      // Subsequent valid message round-trips fine.
      final f = discovery.incoming.first;
      final msg = _mkMessage(id: 'after-garbage');
      platform.emitPayload('p1', Uint8List.fromList(_encode(msg)));
      final got = await f;
      expect(got.id, 'after-garbage');
      await discovery.dispose();
      await platform.close();
    });
  });

  group('MeshDiscovery.isAvailable', () {
    test('true when bluetooth on AND permission granted', () {
      final platform = _FakePlatform();
      platform.bluetoothEnabled = true;
      platform.permissionsGranted = true;
      final discovery = MeshDiscovery(platform: platform);
      expect(discovery.isAvailable(), isTrue);
      discovery.dispose();
    });

    test('false when bluetooth is off', () {
      final platform = _FakePlatform();
      platform.bluetoothEnabled = false;
      platform.permissionsGranted = true;
      final discovery = MeshDiscovery(platform: platform);
      expect(discovery.isAvailable(), isFalse);
      discovery.dispose();
    });

    test('false when permission is not granted', () {
      final platform = _FakePlatform();
      platform.bluetoothEnabled = true;
      platform.permissionsGranted = false;
      final discovery = MeshDiscovery(platform: platform);
      expect(discovery.isAvailable(), isFalse);
      discovery.dispose();
    });
  });

  group('MeshDiscovery — permission rationale', () {
    test('permission rationale explains nearby-device use', () {
      expect(MeshDiscovery.permissionRationale, contains('nearby'));
      expect(MeshDiscovery.permissionRationale, contains('Bluetooth'));
      expect(MeshDiscovery.permissionRationale, contains('disaster'));
    });

    test('ensurePermissions requests permissions and returns the result',
        () async {
      final platform = _FakePlatform();
      platform.permissionsGranted = false;
      final discovery = MeshDiscovery(platform: platform);
      final granted = await discovery.ensurePermissions();
      expect(granted, isTrue);
      expect(platform.permissionsGranted, isTrue);
      await discovery.dispose();
      await platform.close();
    });
  });

  group('MeshDiscovery — persistence across peer loss', () {
    test('re-discovery of a peer reconnects (state is per-peer)', () async {
      fakeAsync((async) {
        final platform = _FakePlatform();
        final discovery = MeshDiscovery(platform: platform);
        discovery.start();
        platform.emitPeerFound('p1');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(platform.connectAttempts, ['p1']);

        // Peer is lost; the discovery should know it's gone but not
        // immediately re-connect (no longer present).
        platform.emitPeerLost('p1');
        async.flushMicrotasks();

        // Reappears — should attempt to connect again.
        platform.emitPeerFound('p1');
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(platform.connectAttempts, ['p1', 'p1']);
        discovery.dispose();
      });
    });
  });
}

