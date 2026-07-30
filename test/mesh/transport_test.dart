import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/discovery.dart';
import 'package:relaylink/mesh/transport.dart';
import 'package:relaylink/models/message.dart';

class _FakePlatform implements MeshDiscoveryPlatform {
  final eventsController = StreamController<MeshPlatformEvent>.broadcast();
  final sent = <String, List<Uint8List>>{};

  @override
  bool isBluetoothEnabled = true;

  @override
  bool hasPermissions = true;

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<void> startAdvertising({required String serviceName}) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> startDiscovery({required String serviceName}) async {}

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> connect(String peerId) async {}

  @override
  Future<void> disconnect(String peerId) async {}

  @override
  Future<void> sendPayload(String peerId, Uint8List bytes) async {
    sent.putIfAbsent(peerId, () => []).add(bytes);
  }

  @override
  Stream<MeshPlatformEvent> get events => eventsController.stream;

  Future<void> dispose() => eventsController.close();
}

Message _message() => Message.create(
      mode: MessageMode.broadcast,
      type: MessageType.chat,
      channelId: 'public',
      senderId: 'device-a',
      payload: Uint8List.fromList([1, 2, 3]),
      ttl: 4,
    );

void main() {
  test('MeshTransport fans out encoded messages to connected discovery peers',
      () async {
    final platform = _FakePlatform();
    final discovery = MeshDiscovery(platform: platform);
    final transport = MeshTransport(discovery: discovery);
    await discovery.start();
    platform.eventsController.add(const MeshPlatformPeerFound('peer-1', 'One'));
    platform.eventsController.add(const MeshPlatformPeerConnected('peer-1'));
    await Future<void>.delayed(Duration.zero);

    final msg = _message();
    await transport.send(msg);

    final sentToPeer = platform.sent['peer-1'];
    expect(sentToPeer, isNotNull);
    expect(sentToPeer, hasLength(1));
    final wire = sentToPeer!.single;
    expect(utf8.decode(wire).trim(), isNotEmpty);
    // Ensure it's parseable JSON of the original message.
    final decoded = jsonDecode(utf8.decode(wire)) as Map<String, dynamic>;
    expect(decoded['sender_id'], 'device-a');
    expect(decoded['mode'], 'BROADCAST');
    expect(decoded['channel_id'], 'public');
    expect(decoded['payload'], 'AQID');
    await transport.dispose();
    await discovery.dispose();
    await platform.dispose();
  });
}
