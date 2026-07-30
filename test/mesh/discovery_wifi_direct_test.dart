// RelayLink — Wi-Fi Direct mesh seam tests (Ticket #M-mesh-redo).
//
// Plan B for cutrev-mesh: builds a separate, Wi-Fi-Direct-flavored seam
// against the same `MeshDiscovery` interface (Ticket #07, merged on
// `main` as `8798e79`). The previous attempt at `cutrev-mesh-planb`
// reached for `MeshPeer`/`MeshFrame` types that didn't exist and for an
// `incomingBytes` accessor that isn't on the `MeshDiscovery` contract,
// so the seam was incompatible. This suite locks the new seam to the
// *actual* interface shipped in `lib/mesh/discovery.dart`.
//
// The Wi-Fi Direct seam is structurally identical to the iOS Multipeer
// seam (`lib/mesh/discovery_ios.dart`) — it subclasses `MeshDiscovery`,
// swaps in a Wi-Fi-P2P-flavored `MeshDiscoveryPlatform`, and exposes a
// `LoopbackWifiDirectPlatform` test fake. The contract under test is the
// same `Transport` surface, so production callers drop in
// `WifiDirectMeshDiscovery` for `MeshDiscovery` with no other call-site
// changes.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/discovery.dart';
import 'package:relaylink/mesh/discovery_wifi_direct.dart';
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

void main() {
  group('WifiDirectMeshDiscovery — surface parity with MeshDiscovery', () {
    test('default constructor uses the offline stub platform', () {
      final d = WifiDirectMeshDiscovery();
      // Stub reports the Wi-Fi radio as off and permissions as not
      // granted, so `isAvailable()` must be `false` until a real
      // platform impl lands (mirrors `StubMeshDiscoveryPlatform`).
      expect(d.isAvailable(), isFalse);
      // The default Wi-Fi-Direct platform impl is the dedicated
      // `StubWifiDirectPlatform` (subclass of `WifiDirectPlatform`),
      // which is itself an Android-side implementation of the same
      // `MeshDiscoveryPlatform` contract that backs BLE.
      expect(d.wifiPlatform, isA<WifiDirectPlatform>());
      expect(d.wifiPlatform, isA<StubWifiDirectPlatform>().having(
            (p) => p.isWifiEnabled,
            'isWifiEnabled',
            isFalse,
          ));
      expect(d.wifiPlatform, isA<StubWifiDirectPlatform>().having(
            (p) => p.hasPermissions,
            'hasPermissions',
            isFalse,
          ));
      d.dispose();
    });

    test('name is "mesh" (matches Transport contract shared with BLE/ANFC)',
        () {
      final d = WifiDirectMeshDiscovery();
      expect(d.name, 'mesh');
      d.dispose();
    });

    test('incoming is a broadcast stream (consumer-friendly)', () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      // Two listeners should both receive the same event — broadcast
      // stream contract.
      final f1 = d.incoming.first;
      final f2 = d.incoming.first;
      final msg = _mkMessage(id: 'wd-broadcast-check');
      loopback.emitPayload('p1', Uint8List.fromList(_encode(msg)));
      final r1 = await f1;
      final r2 = await f2;
      expect(r1.id, 'wd-broadcast-check');
      expect(r2.id, 'wd-broadcast-check');
      await d.dispose();
      await loopback.closeEvents();
    });

    test('serviceName and deviceName round-trip through the constructor', () {
      final d = WifiDirectMeshDiscovery(
        serviceName: 'custom.wifi.direct.v1',
        deviceName: 'MyAndroidPhone',
      );
      expect(d.serviceName, 'custom.wifi.direct.v1');
      expect(d.deviceName, 'MyAndroidPhone');
      d.dispose();
    });

    test('factory wifiDirectDefault() returns a stub-backed discovery', () {
      final d = WifiDirectMeshDiscovery.wifiDirectDefault();
      expect(d.isAvailable(), isFalse);
      expect(
          d.deviceName, kRelayLinkDefaultWifiDirectDeviceName);
      expect(d.serviceName, kRelayLinkServiceName);
      d.dispose();
    });

    test('WifiDirectMeshDiscovery is a MeshDiscovery / Transport', () {
      // Compile-time invariant: the Wi-Fi Direct seam is a *subclass*
      // of `MeshDiscovery`, so every caller can substitute one for the
      // other without breaking the Transport contract.
      final d = WifiDirectMeshDiscovery();
      expect(d, isA<MeshDiscovery>());
      expect(d, isA<Transport>());
      d.dispose();
    });
  });

  group('WifiDirectMeshDiscovery — availability', () {
    test('isAvailable() is driven by the platform — true when radio + perms',
        () {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      expect(d.isAvailable(), isTrue);
      loopback.wifiEnabled = false;
      expect(d.isAvailable(), isFalse);
      loopback.wifiEnabled = true;
      loopback.permissionsGranted = false;
      expect(d.isAvailable(), isFalse);
      d.dispose();
      loopback.closeEvents();
    });

    test('isAvailable() is false when the Wi-Fi radio is off', () {
      final loopback = LoopbackWifiDirectPlatform(wifiEnabled: false);
      final d = WifiDirectMeshDiscovery(platform: loopback);
      expect(d.isAvailable(), isFalse);
      d.dispose();
      loopback.closeEvents();
    });

    test('isAvailable() is false when the location permission is denied',
        () {
      final loopback =
          LoopbackWifiDirectPlatform(permissionsGranted: false);
      final d = WifiDirectMeshDiscovery(platform: loopback);
      expect(d.isAvailable(), isFalse);
      d.dispose();
      loopback.closeEvents();
    });
  });

  group('LoopbackWifiDirectPlatform — fake-shaped platform impl', () {
    test('records advertising + discovery lifecycle calls', () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      expect(loopback.advertising, isTrue);
      expect(loopback.discovering, isTrue);
      await d.stop();
      expect(loopback.advertising, isFalse);
      expect(loopback.discovering, isFalse);
      await d.dispose();
      await loopback.closeEvents();
    });

    test('emits the initial peer-list snapshot on subscription', () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('wd-peer-1', name: 'Pixel-1');
      loopback.emitPeerFound('wd-peer-2', name: 'Pixel-2');
      await Future<void>.delayed(Duration.zero);

      final initial = await d.peers.first;
      expect(initial.map((p) => p.id),
          containsAll(['wd-peer-1', 'wd-peer-2']));
      expect(initial.length, 2);
      await d.dispose();
      await loopback.closeEvents();
    });

    test('first connect attempt fires immediately on peer-found', () {
      fakeAsync((async) {
        final loopback = LoopbackWifiDirectPlatform();
        final d = WifiDirectMeshDiscovery(platform: loopback);
        d.start();
        loopback.emitPeerFound('p1');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(loopback.connectAttempts, ['p1']);
        d.dispose();
        async.flushMicrotasks();
      });
    });

    test('backoff is 1s, 2s, 4s after each failure, capped at 30s', () {
      fakeAsync((async) {
        final loopback = LoopbackWifiDirectPlatform();
        loopback.connectResult.addAll(<bool>[
          false,
          false,
          false,
          false,
          false,
          false,
        ]);
        final d = WifiDirectMeshDiscovery(platform: loopback);
        d.start();
        loopback.emitPeerFound('p1');
        async.flushMicrotasks();

        // Attempt 1 fires immediately.
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, 1);

        // Attempt 2 due at t=1s; not yet at t≈999ms.
        async.elapse(const Duration(milliseconds: 998));
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, 1,
            reason: 'attempt 2 not yet due');
        async.elapse(const Duration(milliseconds: 5));
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, 2);

        // Wait 2s -> attempt 3.
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, 3);

        // Wait 4s -> attempt 4.
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, 4);

        // Cap kicks in at attempt 6 (>= 30s wait).
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, 6,
            reason: 'attempts 5+6 fire within the 30s cap');
        d.dispose();
        async.flushMicrotasks();
      });
    });

    test('successful connect stops the backoff loop', () {
      fakeAsync((async) {
        final loopback = LoopbackWifiDirectPlatform();
        loopback.connectResult.addAll(<bool>[false, false, true]);
        final d = WifiDirectMeshDiscovery(platform: loopback);
        d.start();
        loopback.emitPeerFound('p1');
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        async.flushMicrotasks(); // drain pending microtasks

        expect(loopback.connectAttempts.length, 3,
            reason: 'three attempts completed by t=3s');

        final attemptsSoFar = loopback.connectAttempts.length;
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(loopback.connectAttempts.length, attemptsSoFar,
            reason: 'no further attempts after success');
        d.dispose();
      });
    });

    test('emits on peer connect / disconnect and tracks MeshPeer status',
        () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      await Future<void>.delayed(Duration.zero);

      final emissions = <List<MeshPeer>>[];
      final sub = d.peers.listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, 1, reason: 'initial snapshot delivered');

      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);
      loopback.emitPeerDisconnected('p1');
      await Future<void>.delayed(Duration.zero);

      expect(emissions.length, 3);
      expect(emissions[0].first.status, PeerStatus.connecting);
      expect(emissions[1].first.status, PeerStatus.connected);
      expect(emissions[2].first.status, PeerStatus.disconnected);
      await sub.cancel();
      await d.dispose();
      await loopback.closeEvents();
    });

    test('peer-lost removes the peer from the list', () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      await Future<void>.delayed(Duration.zero);

      final emissions = <List<MeshPeer>>[];
      final sub = d.peers.listen(emissions.add);
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, 1);
      loopback.emitPeerLost('p1');
      await Future<void>.delayed(Duration.zero);
      expect(emissions.length, 2);
      expect(emissions.last, isEmpty);
      await sub.cancel();
      await d.dispose();
      await loopback.closeEvents();
    });

    test('incoming: malformed payload is dropped, stream stays open',
        () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      loopback.emitPayload('p1', Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);

      final f = d.incoming.first;
      final msg = _mkMessage(id: 'wd-after-garbage');
      loopback.emitPayload('p1', Uint8List.fromList(_encode(msg)));
      final got = await f;
      expect(got.id, 'wd-after-garbage');
      await d.dispose();
      await loopback.closeEvents();
    });

    test('round-trips a frame in-process (loopback contract)', () async {
      // The "loopback" fake exposes the same platform surface the real
      // Android `WifiP2pManager` wrapper would expose. A round-trip
      // test pins the surface and shows that bytes pushed via
      // `sendPayload` end up as a decoded `Message` on `incoming` on
      // the *same* loopback — i.e. the fake pipes events back to the
      // discovery end-to-end.
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      final received = d.incoming.first;
      final msg = _mkMessage(id: 'wd-round-trip');
      loopback.roundTrip('p1', Uint8List.fromList(_encode(msg)));
      final got = await received;
      expect(got.id, 'wd-round-trip');
      await d.dispose();
      await loopback.closeEvents();
    });
  });

  group('WifiDirectMeshDiscovery — Transport interface', () {
    test('send routes the message to the connected peer', () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      final msg = _mkMessage(id: 'wd-out-1');
      await d.send(msg);
      expect(loopback.sentPayloads.length, 1);
      expect(loopback.sentPayloads.first.peerId, 'p1');
      final text = String.fromCharCodes(loopback.sentPayloads.first.bytes);
      expect(text, contains('wd-out-1'));
      await d.dispose();
      await loopback.closeEvents();
    });

    test('send throws TransportUnavailableException when no peer is connected',
        () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      await Future<void>.delayed(Duration.zero);

      expect(
        () => d.send(_mkMessage()),
        throwsA(isA<TransportUnavailableException>()),
      );
      await d.dispose();
      await loopback.closeEvents();
    });

    test('send throws TransportUnavailableException when Wi-Fi is off',
        () async {
      final loopback = LoopbackWifiDirectPlatform(wifiEnabled: false);
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      await Future<void>.delayed(Duration.zero);

      expect(
        () => d.send(_mkMessage()),
        throwsA(isA<TransportUnavailableException>()),
      );
      await d.dispose();
      await loopback.closeEvents();
    });

    test('incoming delivers to multiple consumers (broadcast)', () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      final f1 = d.incoming.first;
      final f2 = d.incoming.first;
      final msg = _mkMessage(id: 'wd-hi');
      final bytes = Uint8List.fromList(_encode(msg));
      loopback.emitPayload('p1', bytes);
      final r1 = await f1;
      final r2 = await f2;
      expect(r1.id, 'wd-hi');
      expect(r2.id, 'wd-hi');
      await d.dispose();
      await loopback.closeEvents();
    });

    test('disconnectPeer cancels the backoff and removes the active peer',
        () async {
      final loopback = LoopbackWifiDirectPlatform();
      final d = WifiDirectMeshDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      await d.disconnectPeer('p1');
      expect(loopback.disconnectCalls, ['p1']);
      expect(d.currentPeers.first.status, PeerStatus.disconnected);
      await d.dispose();
      await loopback.closeEvents();
    });

    test('ensurePermissions returns true once the loopback grants access',
        () async {
      final loopback =
          LoopbackWifiDirectPlatform(permissionsGranted: false);
      final d = WifiDirectMeshDiscovery(platform: loopback);
      final granted = await d.ensurePermissions();
      expect(granted, isTrue);
      expect(d.isAvailable(), isTrue);
      await d.dispose();
      await loopback.closeEvents();
    });
  });

  group('Wi-Fi Direct only constants', () {
    test('kRelayLinkDefaultWifiDirectDeviceName is non-empty UTF-8', () {
      // Android `WifiP2pManager.setDeviceName` accepts UTF-8 strings
      // limited to 63 bytes (the same Bonjour TXT record limit iOS
      // uses). Keep the default short so it fits.
      final s = kRelayLinkDefaultWifiDirectDeviceName;
      expect(s, isNotEmpty);
      expect(utf8.encode(s).length, lessThanOrEqualTo(63),
          reason: 'must fit in a Wi-Fi P2P device name');
    });
  });

  group('Wi-Fi Direct seam — parity sanity check', () {
    test('encodeMessage / tryDecodeMessage helpers are inherited', () {
      final msg = _mkMessage(id: 'wd-wire-1');
      final bytes = WifiDirectMeshDiscovery.encodeMessage(msg);
      expect(bytes, isA<Uint8List>());
      final round = WifiDirectMeshDiscovery.tryDecodeMessage(bytes);
      expect(round, isNotNull);
      expect(round!.id, 'wd-wire-1');
    });

    test('permissionRationale is inherited from MeshDiscovery', () {
      // The MeshDiscovery.kRelayLinkBluetoothPermissionRationale
      // constant is shared with the Wi-Fi Direct seam so the
      // first-launch UI shows the same text.
      expect(
          WifiDirectMeshDiscovery.permissionRationale, contains('nearby'));
      expect(
          WifiDirectMeshDiscovery.permissionRationale, contains('Bluetooth'));
    });
  });
}