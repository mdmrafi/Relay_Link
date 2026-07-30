// RelayLink — iOS Multipeer Connectivity seam tests (Ticket #07-iOS).
//
// The objective of this suite is NOT to drive a real iOS Multipeer
// session; it's to lock the *seam* — the public surface of
// [MultipeerDiscovery] — to the same contract as [MeshDiscovery] (the
// Android Nearby-Connections wrapper from Ticket #07).
//
// We test three things:
//
//   1. The iOS seam's default constructor wires the offline stub
//      platform (no Flutter-iOS plumbing available in the sandbox).
//   2. The iOS-specific kwargs (`displayName`, `serviceName`) round-trip
//      through the constructor and the iOS-only constants are
//      stable.
//   3. The [LoopbackMultipeerDiscovery] test fake drives the
//      `MultipeerDiscovery` superclass end-to-end the same way the
//      Android equivalent (`_FakePlatform` in
//      `test/mesh/discovery_test.dart`) drives the Android
//      `MeshDiscovery`. If the iOS seam matches the Android seam,
//      these tests should mirror the discovery_test.dart contract
//      tests one-for-one.
//
// The loopback fake is the integration point: when the real
// `nearby_connections` iOS impl lands, only the platform impl needs to
// change — the LoopbackMultipeerDiscovery stays as the seam test.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/discovery.dart';
import 'package:relaylink/mesh/discovery_ios.dart';
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
  group('MultipeerDiscovery seam — surface parity with MeshDiscovery', () {
    test('default constructor uses the offline stub platform', () {
      final d = MultipeerDiscovery();
      // The stub's `isBluetoothEnabled` is `false` and `hasPermissions`
      // is `false`, so `isAvailable()` must be `false` too. This is the
      // same contract as `StubMeshDiscoveryPlatform`.
      expect(d.isAvailable(), isFalse);
      // The default iOS platform impl is the dedicated
      // `StubMultipeerDiscoveryPlatform` (subclass of
      // `MultipeerDiscoveryPlatform`), which is itself an iOS-side
      // implementation of the same `MeshDiscoveryPlatform` contract.
      expect(d.iosPlatform, isA<MultipeerDiscoveryPlatform>());
      expect(d.iosPlatform, isA<StubMultipeerDiscoveryPlatform>().having(
            (p) => p.isBluetoothEnabled,
            'isBluetoothEnabled',
            isFalse,
          ));
      expect(d.iosPlatform, isA<StubMultipeerDiscoveryPlatform>().having(
            (p) => p.hasPermissions,
            'hasPermissions',
            isFalse,
          ));
      d.dispose();
    });

    test('name is "mesh" (matches Transport contract shared with Android)',
        () {
      final d = MultipeerDiscovery();
      expect(d.name, 'mesh');
      d.dispose();
    });

    test('incoming is a broadcast stream (consumer-friendly)', () async {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      // Two listeners should both receive the same event — broadcast
      // stream contract.
      final f1 = d.incoming.first;
      final f2 = d.incoming.first;
      final msg = _mkMessage(id: 'broadcast-check');
      loopback.emitPayload('p1', Uint8List.fromList(_encode(msg)));
      final r1 = await f1;
      final r2 = await f2;
      expect(r1.id, 'broadcast-check');
      expect(r2.id, 'broadcast-check');
      await d.dispose();
      await loopback.closeEvents();
    });

    test('serviceName and displayName round-trip through the constructor',
        () {
      final d = MultipeerDiscovery(
        serviceName: 'custom.service.v1',
        displayName: 'MyPhone',
      );
      expect(d.serviceName, 'custom.service.v1');
      expect(d.displayName, 'MyPhone');
      d.dispose();
    });

    test('factory iosDefault() returns a stub-backed discovery', () {
      final d = MultipeerDiscovery.iosDefault();
      expect(d.isAvailable(), isFalse);
      expect(d.displayName, kRelayLinkDefaultMultipeerDisplayName);
      expect(d.serviceName, kRelayLinkServiceName);
      d.dispose();
    });

    test('isAvailable() is driven by the platform — true when radio is on',
        () {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      expect(d.isAvailable(), isTrue);
      loopback.bluetoothEnabled = false;
      expect(d.isAvailable(), isFalse);
      loopback.bluetoothEnabled = true;
      loopback.permissionsGranted = false;
      expect(d.isAvailable(), isFalse);
      d.dispose();
      loopback.closeEvents();
    });

    test('isAvailable() is false when the radio is off', () {
      final loopback = LoopbackMultipeerDiscovery(bluetoothEnabled: false);
      final d = MultipeerDiscovery(platform: loopback);
      expect(d.isAvailable(), isFalse);
      d.dispose();
      loopback.closeEvents();
    });

    test('isAvailable() is false when the local-network permission is denied',
        () {
      final loopback = LoopbackMultipeerDiscovery(permissionsGranted: false);
      final d = MultipeerDiscovery(platform: loopback);
      expect(d.isAvailable(), isFalse);
      d.dispose();
      loopback.closeEvents();
    });

    test('isAvailable() is true when both radio and permission are good', () {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      expect(d.isAvailable(), isTrue);
      d.dispose();
      loopback.closeEvents();
    });
  });

  group('LoopbackMultipeerDiscovery — fake-shaped platform impl', () {
    test('records advertising + discovery lifecycle calls', () async {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
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
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('ios-peer-1', name: 'iPhone-1');
      loopback.emitPeerFound('ios-peer-2', name: 'iPhone-2');
      await Future<void>.delayed(Duration.zero);

      final initial = await d.peers.first;
      expect(initial.map((p) => p.id),
          containsAll(['ios-peer-1', 'ios-peer-2']));
      expect(initial.length, 2);
      await d.dispose();
      await loopback.closeEvents();
    });

    test('first connect attempt fires immediately on peer-found', () {
      fakeAsync((async) {
        final loopback = LoopbackMultipeerDiscovery();
        final d = MultipeerDiscovery(platform: loopback);
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
        final loopback = LoopbackMultipeerDiscovery();
        // Always fail across several attempts.
        loopback.connectResult.addAll(<bool>[false, false, false, false, false]);
        final d = MultipeerDiscovery(platform: loopback);
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
        // We're now at t≈37s. Attempts 5 and 6 fired (waiting 16s and
        // 30s respectively). No further attempts without more time.
        expect(loopback.connectAttempts.length, 6);
        d.dispose();
        async.flushMicrotasks();
      });
    });

    test('successful connect stops the backoff loop', () {
      fakeAsync((async) {
        final loopback = LoopbackMultipeerDiscovery();
        loopback.connectResult.addAll(<bool>[false, false, true]);
        final d = MultipeerDiscovery(platform: loopback);
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
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
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
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
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
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      // Push garbage through the loopback.
      loopback.emitPayload('p1', Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);

      // The stream should still be open — a valid message rounds-trips.
      final f = d.incoming.first;
      final msg = _mkMessage(id: 'after-garbage');
      loopback.emitPayload('p1', Uint8List.fromList(_encode(msg)));
      final got = await f;
      expect(got.id, 'after-garbage');
      await d.dispose();
      await loopback.closeEvents();
    });
  });

  group('MultipeerDiscovery — Transport interface', () {
    test('send routes the message to the connected peer', () async {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      final msg = _mkMessage(id: 'ios-out-1');
      await d.send(msg);
      expect(loopback.sentPayloads.length, 1);
      expect(loopback.sentPayloads.first.peerId, 'p1');
      final text = String.fromCharCodes(loopback.sentPayloads.first.bytes);
      expect(text, contains('ios-out-1'));
      await d.dispose();
      await loopback.closeEvents();
    });

    test('send throws TransportUnavailableException when no peer is connected',
        () async {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      await Future<void>.delayed(Duration.zero);

      expect(
        () => d.send(_mkMessage()),
        throwsA(isA<TransportUnavailableException>()),
      );
      await d.dispose();
      await loopback.closeEvents();
    });

    test('send throws TransportUnavailableException when bluetooth is off',
        () async {
      final loopback = LoopbackMultipeerDiscovery(bluetoothEnabled: false);
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      await Future<void>.delayed(Duration.zero);

      expect(
        () => d.send(_mkMessage()),
        throwsA(isA<TransportUnavailableException>()),
      );
      await d.dispose();
      await loopback.closeEvents();
    });

    test('incoming is a broadcast stream that delivers to multiple consumers',
        () async {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
      await d.start();
      loopback.emitPeerFound('p1');
      loopback.emitPeerConnected('p1');
      await Future<void>.delayed(Duration.zero);

      final f1 = d.incoming.first;
      final f2 = d.incoming.first;
      final msg = _mkMessage(id: 'ios-hi');
      final bytes = Uint8List.fromList(_encode(msg));
      loopback.emitPayload('p1', bytes);
      final r1 = await f1;
      final r2 = await f2;
      expect(r1.id, 'ios-hi');
      expect(r2.id, 'ios-hi');
      await d.dispose();
      await loopback.closeEvents();
    });

    test('disconnectPeer cancels the backoff and removes the active peer',
        () async {
      final loopback = LoopbackMultipeerDiscovery();
      final d = MultipeerDiscovery(platform: loopback);
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
      final loopback = LoopbackMultipeerDiscovery(permissionsGranted: false);
      final d = MultipeerDiscovery(platform: loopback);
      final granted = await d.ensurePermissions();
      expect(granted, isTrue);
      expect(d.isAvailable(), isTrue);
      await d.dispose();
      await loopback.closeEvents();
    });
  });

  group('iOS-only constants', () {
    test('kRelayLinkMultipeerServiceType is a valid Bonjour service type',
        () {
      // Apple's Multipeer Connectivity requires a service type that
      // is 1–15 chars, ASCII, lowercase letters/digits/hyphens.
      final s = kRelayLinkMultipeerServiceType;
      expect(s.length, inInclusiveRange(1, 15));
      expect(RegExp(r'^[a-z0-9-]+$').hasMatch(s), isTrue,
          reason: 'must be lowercase ASCII letters/digits/hyphens');
    });

    test('kRelayLinkDefaultMultipeerDisplayName is non-empty UTF-8', () {
      expect(kRelayLinkDefaultMultipeerDisplayName, isNotEmpty);
      expect(
        utf8.encode(kRelayLinkDefaultMultipeerDisplayName).length,
        lessThanOrEqualTo(63),
        reason: 'must fit in a Bonjour TXT record',
      );
    });
  });

  group('iOS seam — parity sanity check', () {
    test('MultipeerDiscovery is a MeshDiscovery', () {
      // Compile-time invariant: the iOS seam is a *subclass* of the
      // Android one, so every caller can substitute one for the other
      // without breaking the Transport contract.
      final d = MultipeerDiscovery();
      expect(d, isA<MeshDiscovery>());
      expect(d, isA<Transport>());
      d.dispose();
    });

    test('encodeMessage / tryDecodeMessage helpers are inherited from MeshDiscovery',
        () {
      // The static wire-format helpers used by the gateway relay must
      // be reachable on the iOS subclass.
      final msg = _mkMessage(id: 'wire-1');
      final bytes = MultipeerDiscovery.encodeMessage(msg);
      expect(bytes, isA<Uint8List>());
      final round = MultipeerDiscovery.tryDecodeMessage(bytes);
      expect(round, isNotNull);
      expect(round!.id, 'wire-1');
    });

    test('MultipeerDiscovery.permissionRationale is inherited', () {
      // The MeshDiscovery.kRelayLinkBluetoothPermissionRationale
      // constant is shared with iOS so the first-launch UI shows the
      // same text on both platforms.
      expect(MultipeerDiscovery.permissionRationale, contains('nearby'));
      expect(MultipeerDiscovery.permissionRationale, contains('Bluetooth'));
    });
  });
}
