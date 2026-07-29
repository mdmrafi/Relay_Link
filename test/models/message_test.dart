// RelayLink — Message schema round-trip tests (Ticket #04).
//
// These tests pin the JSON wire format used across mesh, SMS, and internet
// transports. The envelope is the contract; any ticket that touches the
// Message class should keep this round-trip stable.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/models/message.dart';

void main() {
  group('MessageDefaults', () {
    test('SOS gets the longest reach (12)', () {
      expect(MessageDefaults.defaultTtlFor(MessageType.sos), 12);
    });

    test('ALERT gets 10 hops', () {
      expect(MessageDefaults.defaultTtlFor(MessageType.alert), 10);
    });

    test('all other types get 8 hops', () {
      const others = [
        MessageType.statusSafe,
        MessageType.statusHelp,
        MessageType.chat,
        MessageType.ack,
        MessageType.evidenceNotice,
      ];
      for (final t in others) {
        expect(MessageDefaults.defaultTtlFor(t), 8, reason: 'for $t');
      }
    });

    test('named TTL constants agree with defaultTtlFor()', () {
      expect(MessageDefaults.sosTtl,
          MessageDefaults.defaultTtlFor(MessageType.sos));
      expect(MessageDefaults.alertTtl,
          MessageDefaults.defaultTtlFor(MessageType.alert));
      expect(MessageDefaults.defaultTtl,
          MessageDefaults.defaultTtlFor(MessageType.chat));
    });
  });

  group('enum wire format', () {
    test('MessageMode round-trip', () {
      for (final m in MessageMode.values) {
        expect(MessageMode.fromJson(m.toJson()), m);
      }
    });

    test('MessageType round-trip', () {
      for (final t in MessageType.values) {
        expect(MessageType.fromJson(t.toJson()), t);
      }
    });

    test('MessageOrigin round-trip', () {
      for (final o in MessageOrigin.values) {
        expect(MessageOrigin.fromJson(o.toJson()), o);
      }
    });

    test('MessageMode.toJson uses upper-case labels', () {
      expect(MessageMode.broadcast.toJson(), 'BROADCAST');
      expect(MessageMode.direct.toJson(), 'DIRECT');
    });

    test('MessageType.toJson uses upper-case labels', () {
      expect(MessageType.sos.toJson(), 'SOS');
      expect(MessageType.statusSafe.toJson(), 'STATUS_SAFE');
      expect(MessageType.evidenceNotice.toJson(), 'EVIDENCE_NOTICE');
    });
  });

  group('GeoLocation', () {
    test('round-trip with accuracy', () {
      const loc = GeoLocation(latitude: 12.34, longitude: 56.78, accuracyMeters: 5.0);
      final json = loc.toJson();
      expect(json['lat'], 12.34);
      expect(json['lon'], 56.78);
      expect(json['accuracy_m'], 5.0);
      final back = GeoLocation.fromJson(json);
      expect(back, loc);
    });

    test('round-trip without accuracy omits the key', () {
      const loc = GeoLocation(latitude: 1, longitude: 2);
      final json = loc.toJson();
      expect(json.containsKey('accuracy_m'), isFalse);
      expect(GeoLocation.fromJson(json), loc);
    });
  });

  group('Message factory defaults', () {
    test('Message.create assigns fresh UUIDv4 and UTC timestamp', () {
      final m = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.sos,
        channelId: 'public',
        senderId: 'device-1',
      );
      // UUIDv4: 36 chars, version nibble '4' at position 14.
      expect(m.id.length, 36);
      expect(m.id[14], '4');
      expect(m.createdAt.isUtc, isTrue);
      // Default TTL for SOS.
      expect(m.ttl, 12);
      expect(m.hopCount, 0);
      expect(m.payload, isEmpty);
    });

    test('Message.create fills ALERT TTL of 10', () {
      final m = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.alert,
        channelId: 'public',
        senderId: 'device-1',
      );
      expect(m.ttl, 10);
    });

    test('Message.create fills CHAT TTL of 8', () {
      final m = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'device-1',
      );
      expect(m.ttl, 8);
    });
  });

  group('Message JSON round-trip', () {
    test('encode → decode yields an equal Message (every field)', () {
      final original = Message(
        id: '11111111-2222-4333-8444-555555555555',
        mode: MessageMode.direct,
        type: MessageType.chat,
        channelId: '',
        senderId: 'device-aaa',
        senderDisplayName: 'Alice',
        origin: MessageOrigin.smsTransport,
        recipientId: 'device-bbb',
        payload: Uint8List.fromList([1, 2, 3, 4, 5, 250, 251, 252, 253, 254, 255]),
        ratchetHeader: Uint8List.fromList(List.generate(32, (i) => i)),
        location: const GeoLocation(
          latitude: 37.7749,
          longitude: -122.4194,
          accuracyMeters: 4.5,
        ),
        createdAt: DateTime.utc(2026, 7, 30, 12, 34, 56, 789),
        ttl: 7,
        hopCount: 3,
        signature: Uint8List.fromList(List.generate(64, (i) => (255 - i) & 0xFF)),
        inResponseTo: '00000000-1111-4222-8333-444444444444',
      );

      final json = original.toJson();
      // Wire-format spot checks — keep these honest so a future refactor
      // can't silently change field names.
      expect(json['id'], original.id);
      expect(json['mode'], 'DIRECT');
      expect(json['type'], 'CHAT');
      expect(json['channel_id'], '');
      expect(json['sender_id'], 'device-aaa');
      expect(json['sender_display_name'], 'Alice');
      expect(json['origin'], 'SMS_TRANSPORT');
      expect(json['recipient_id'], 'device-bbb');
      expect(json['payload'], base64.encode(original.payload));
      expect(json['ratchet_header'], base64.encode(original.ratchetHeader!));
      expect(json['location'], isA<Map<String, dynamic>>());
      expect(json['created_at'], '2026-07-30T12:34:56.789Z');
      expect(json['ttl'], 7);
      expect(json['hop_count'], 3);
      expect(json['signature'], base64.encode(original.signature!));
      expect(json['in_response_to'], original.inResponseTo);

      // Round-trip.
      final decoded = Message.fromJson(json);
      expect(decoded, original);
      expect(decoded.createdAt.isAtSameMomentAs(original.createdAt), isTrue);
    });

    test('round-trip without optional fields (BROADCAST, no extras)', () {
      final original = Message(
        id: 'msg-1',
        mode: MessageMode.broadcast,
        type: MessageType.statusSafe,
        channelId: 'public',
        senderId: 'device-xyz',
        senderDisplayName: '',
        origin: MessageOrigin.mesh,
        recipientId: null,
        payload: Uint8List.fromList([9, 8, 7]),
        ratchetHeader: null,
        location: null,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 0),
        ttl: 8,
        hopCount: 0,
        signature: null,
        inResponseTo: null,
      );

      final json = original.toJson();
      // Optional fields must be absent — keep wire format minimal.
      expect(json.containsKey('recipient_id'), isFalse);
      expect(json.containsKey('ratchet_header'), isFalse);
      expect(json.containsKey('location'), isFalse);
      expect(json.containsKey('signature'), isFalse);
      expect(json.containsKey('in_response_to'), isFalse);

      expect(Message.fromJson(json), original);
    });

    test('ratchet_header is encoded only when mode == DIRECT', () {
      final direct = Message(
        id: 'd-1',
        mode: MessageMode.direct,
        type: MessageType.chat,
        channelId: '',
        senderId: 'a',
        senderDisplayName: '',
        origin: MessageOrigin.mesh,
        recipientId: 'b',
        payload: Uint8List(0),
        ratchetHeader: Uint8List.fromList([1, 2, 3]),
        location: null,
        createdAt: DateTime.utc(2026, 7, 30),
        ttl: 8,
        hopCount: 0,
        signature: null,
        inResponseTo: null,
      );
      final broadcast = direct.copyWith(
        mode: MessageMode.broadcast,
        recipientId: null,
        ratchetHeader: null,
      );

      expect(direct.toJson().containsKey('ratchet_header'), isTrue);
      expect(broadcast.toJson().containsKey('ratchet_header'), isFalse);
    });

    test('fromJson rejects ratchet_header on BROADCAST messages', () {
      final json = {
        'id': 'x',
        'mode': 'BROADCAST',
        'type': 'CHAT',
        'channel_id': 'public',
        'sender_id': 'a',
        'sender_display_name': '',
        'origin': 'MESH',
        'payload': base64.encode(Uint8List(0)),
        'created_at': '2026-07-30T00:00:00.000Z',
        'ttl': 8,
        'hop_count': 0,
        'ratchet_header': base64.encode(Uint8List.fromList([1, 2, 3])),
      };
      expect(() => Message.fromJson(json), throwsA(isA<FormatException>()));
    });

    test('payload round-trips binary bytes faithfully', () {
      final bytes = Uint8List.fromList(List.generate(256, (i) => i));
      final m = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.chat,
        channelId: 'public',
        senderId: 'a',
        payload: bytes,
      );
      final back = Message.fromJson(m.toJson());
      expect(back.payload, bytes);
      expect(back.payload.length, 256);
    });
  });

  group('Message.copyWith', () {
    test('relay-style mutation: decrement ttl, bump hop_count', () {
      final m = Message.create(
        mode: MessageMode.broadcast,
        type: MessageType.sos,
        channelId: 'public',
        senderId: 'a',
      );
      final relayed = m.copyWith(ttl: m.ttl - 1, hopCount: m.hopCount + 1);
      expect(relayed.ttl, m.ttl - 1);
      expect(relayed.hopCount, 1);
      expect(relayed.id, m.id); // same message, same id
    });
  });
}