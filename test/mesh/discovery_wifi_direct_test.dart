// Tests for `WifiDirectMeshDiscovery` (Plan B mesh transport).
//
// Pattern mirrors `LoopbackMeshDiscovery` / `MeshRadioBus` tests in
// the same package: a `WifiDirectRadioBus` shared between two
// loopback platforms, frames round-trip between them, peer-link
// state is mirrored on both sides (real Wi-Fi Direct / Multipeer
// are bidirectional-link too).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/discovery_wifi_direct.dart';

void main() {
  group('LoopbackWifiDirectPlatform', () {
    test('start flips radio state and emits on the radio stream', () async {
      final bus = WifiDirectRadioBus();
      final platform =
          LoopbackWifiDirectPlatform(localPeerId: 'A', bus: bus);

      expect(platform.onRadioStateChanged, isNotNull);
      final radioFuture =
          platform.onRadioStateChanged.firstWhere((on) => on).timeout(
                const Duration(seconds: 2),
              );
      await platform.start();
      await radioFuture;

      await platform.dispose();
      bus.dispose();
    });

    test('send throws when radio is off', () async {
      final bus = WifiDirectRadioBus();
      final platform =
          LoopbackWifiDirectPlatform(localPeerId: 'A', bus: bus);
      platform.connectPeer('B');
      await platform.stop();

      Uint8List bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        () => platform.send('B', bytes),
        throwsStateError,
      );

      await platform.dispose();
      bus.dispose();
    });

    test('send throws when peer is not connected', () async {
      final bus = WifiDirectRadioBus();
      final platform =
          LoopbackWifiDirectPlatform(localPeerId: 'A', bus: bus);
      await platform.start();

      Uint8List bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        () => platform.send('B', bytes),
        throwsStateError,
      );

      await platform.dispose();
      bus.dispose();
    });
  });

  group('WifiDirectMeshDiscovery (loopback)', () {
    test('localPeerId is the value passed at construction', () {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'device-1',
        bus: bus,
      );
      expect(discovery.localPeerId, 'device-1');
      // Radio is off until start() is called.
      expect(discovery.isBluetoothOn, isFalse);
      expect(discovery.connectedPeers, isEmpty);
      discovery.dispose();
      bus.dispose();
    });

    test('start flips isBluetoothOn, stop clears it and the peer list',
        () async {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      await discovery.start();
      expect(discovery.isBluetoothOn, isTrue);

      // Add a peer via the loopback adapter, simulate the platform
      // reporting it back via onPeersChanged.
      final lp = discovery.loopbackPlatform!;
      lp.connectPeer('B');
      // Wait a microtask for the listener to drain.
      await Future<void>.delayed(Duration.zero);
      expect(discovery.connectedPeers, contains('B'));

      await discovery.stop();
      expect(discovery.isBluetoothOn, isFalse);
      expect(discovery.connectedPeers, isEmpty);

      await discovery.dispose();
      bus.dispose();
    });

    test('sendBytes requires the radio to be on', () async {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      // Not started, but pretend we have a peer.
      discovery.loopbackPlatform!.connectPeer('B');
      await Future<void>.delayed(Duration.zero);

      Uint8List bytes = Uint8List.fromList([1, 2, 3]);
      // Note: sendBytes checks _radioOn before _connected, so radio-off
      // wins regardless of peer state.
      expect(
        () => discovery.sendBytes('B', bytes),
        throwsStateError,
      );

      await discovery.dispose();
      bus.dispose();
    });

    test('sendBytes requires the peer to be connected', () async {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      await discovery.start();

      Uint8List bytes = Uint8List.fromList([1, 2, 3]);
      expect(
        () => discovery.sendBytes('Z', bytes),
        throwsStateError,
      );

      await discovery.dispose();
      bus.dispose();
    });

    test(
      'frames sent from A land on B.incomingBytes when both sides are linked',
      () async {
        final bus = WifiDirectRadioBus();
        final a = WifiDirectMeshDiscovery.loopback(
          localPeerId: 'A',
          bus: bus,
        );
        final b = WifiDirectMeshDiscovery.loopback(
          localPeerId: 'B',
          bus: bus,
        );

        await a.start();
        await b.start();

        // Bidirectional link — both sides declare each other.
        a.loopbackPlatform!.connectPeer('B');
        b.loopbackPlatform!.connectPeer('A');
        await Future<void>.delayed(Duration.zero);

        // A's peers should include B and vice versa.
        expect(a.connectedPeers, contains('B'));
        expect(b.connectedPeers, contains('A'));

        final frameBytes = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);
        final received = b.incomingBytes.firstWhere(
          (f) => f.bytes.length == frameBytes.length,
        ).timeout(const Duration(seconds: 2));

        await a.sendBytes('B', frameBytes);
        final frame = await received;
        expect(frame.from.id, 'A');
        expect(frame.bytes, frameBytes);

        await a.dispose();
        await b.dispose();
        bus.dispose();
      },
    );

    test('incoming frames from the radio appear on incomingBytes', () async {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      await discovery.start();

      final bytes = Uint8List.fromList([9, 8, 7]);
      final got = discovery.incomingBytes.firstWhere(
        (f) => f.bytes.length == bytes.length,
      ).timeout(const Duration(seconds: 2));

      discovery.loopbackPlatform!.simulateIncoming('B', bytes);
      final frame = await got;
      expect(frame.from.id, 'B');
      expect(frame.bytes, bytes);

      await discovery.dispose();
      bus.dispose();
    });

    test('peersStream emits when the platform reports a peer change',
        () async {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      await discovery.start();

      final lp = discovery.loopbackPlatform!;
      final emitted = discovery.peersStream
          .firstWhere((p) => p.any((peer) => peer.id == 'B'))
          .timeout(const Duration(seconds: 2));
      lp.connectPeer('B');
      final peers = await emitted;
      expect(peers.map((p) => p.id), contains('B'));

      await discovery.dispose();
      bus.dispose();
    });

    test('WifiDirectRadioBus.captureWire records every frame that crosses',
        () async {
      final bus = WifiDirectRadioBus();
      final a = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      final b = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'B',
        bus: bus,
      );
      await a.start();
      await b.start();
      a.loopbackPlatform!.connectPeer('B');
      b.loopbackPlatform!.connectPeer('A');
      await Future<void>.delayed(Duration.zero);

      final sink = <Uint8List>[];
      bus.captureWire(sink);

      final frameBytes = Uint8List.fromList([0x01, 0x02]);
      await a.sendBytes('B', frameBytes);
      // allow the bus to deliver
      await Future<void>.delayed(Duration.zero);

      expect(sink, hasLength(1));
      expect(sink.first, frameBytes);

      await a.dispose();
      await b.dispose();
      bus.dispose();
    });

    test('stop clears connectedPeers and emits an empty peer list',
        () async {
      final bus = WifiDirectRadioBus();
      final discovery = WifiDirectMeshDiscovery.loopback(
        localPeerId: 'A',
        bus: bus,
      );
      await discovery.start();

      final lp = discovery.loopbackPlatform!;
      lp.connectPeer('B');
      await Future<void>.delayed(Duration.zero);
      expect(discovery.connectedPeers, contains('B'));

      final empty = discovery.peersStream
          .firstWhere((p) => p.isEmpty)
          .timeout(const Duration(seconds: 2));
      await discovery.stop();
      await empty;
      expect(discovery.connectedPeers, isEmpty);

      await discovery.dispose();
      bus.dispose();
    });
  });

  group('WifiDirectMeshDiscovery construction', () {
    test('real() throws until the native channel is wired', () {
      // The MethodChannelWifiDirectPlatform body is a stub until the
      // wifi_direct plugin is added to pubspec.yaml. We assert the
      // throw so a missing plugin is detected at startup rather than
      // mid-demo.
      expect(
        () => WifiDirectMeshDiscovery.real(localPeerId: 'X'),
        throwsUnsupportedError,
      );
    });

    test('withPlatform builds with an injected platform', () {
      final bus = WifiDirectRadioBus();
      final platform =
          LoopbackWifiDirectPlatform(localPeerId: 'X', bus: bus);
      final discovery = WifiDirectMeshDiscovery.withPlatform(
        localPeerId: 'X',
        platform: platform,
      );
      expect(discovery.localPeerId, 'X');
      expect(discovery.loopbackPlatform, same(platform));
      discovery.dispose();
      bus.dispose();
    });
  });
}
