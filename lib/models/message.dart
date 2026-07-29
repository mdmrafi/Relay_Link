// RelayLink — Message schema + JSON serialization (Ticket #04).
//
// Implements the wire format described in SPEC.md §5 /
// .scratch/relaylink-build/issues/04-message-schema.md.
//
// Design notes:
//   * Routing metadata is plaintext so relays can route without decrypting
//     (per SPEC.md §5). `payload` carries the ciphertext (DIRECT) or
//     group-encrypted blob (BROADCAST) opaque to the message envelope.
//   * `payload` is `Uint8List` in Dart, base64-encoded in JSON so the
//     envelope is text-portable across mesh, SMS, and internet transports.
//     (Base64 lives in `dart:convert`; `package:convert` only adds
//     hex/percent/codepage, not base64.)
//   * `signature` is base64-encoded Ed25519 over ciphertext + metadata.
//   * `ratchet_header` is nullable and only present when `mode == DIRECT`.
//   * Default TTLs: SOS=12, ALERT=10, everything else=8 (SPEC.md §5).
//   * Timestamps are ISO-8601 UTC strings in JSON, `DateTime` in Dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// How a message is addressed.
///
/// [BROADCAST] goes to a channel (default public channel or a custom one)
/// and is encrypted with a symmetric key. [DIRECT] targets a single
/// recipient and is encrypted with the Double Ratchet (SPEC.md §6.3).
enum MessageMode {
  broadcast,
  direct;

  static MessageMode fromJson(String? value) {
    if (value == null) {
      throw const FormatException('Message.mode is required');
    }
    switch (value) {
      case 'BROADCAST':
        return MessageMode.broadcast;
      case 'DIRECT':
        return MessageMode.direct;
      default:
        throw FormatException('Unknown MessageMode: $value');
    }
  }

  String toJson() {
    switch (this) {
      case MessageMode.broadcast:
        return 'BROADCAST';
      case MessageMode.direct:
        return 'DIRECT';
    }
  }
}

/// What kind of payload this message carries.
enum MessageType {
  sos,
  statusSafe,
  statusHelp,
  chat,
  alert,
  ack,
  evidenceNotice;

  static MessageType fromJson(String? value) {
    if (value == null) {
      throw const FormatException('Message.type is required');
    }
    switch (value) {
      case 'SOS':
        return MessageType.sos;
      case 'STATUS_SAFE':
        return MessageType.statusSafe;
      case 'STATUS_HELP':
        return MessageType.statusHelp;
      case 'CHAT':
        return MessageType.chat;
      case 'ALERT':
        return MessageType.alert;
      case 'ACK':
        return MessageType.ack;
      case 'EVIDENCE_NOTICE':
        return MessageType.evidenceNotice;
      default:
        throw FormatException('Unknown MessageType: $value');
    }
  }

  String toJson() {
    switch (this) {
      case MessageType.sos:
        return 'SOS';
      case MessageType.statusSafe:
        return 'STATUS_SAFE';
      case MessageType.statusHelp:
        return 'STATUS_HELP';
      case MessageType.chat:
        return 'CHAT';
      case MessageType.alert:
        return 'ALERT';
      case MessageType.ack:
        return 'ACK';
      case MessageType.evidenceNotice:
        return 'EVIDENCE_NOTICE';
    }
  }
}

/// How this message entered the local pipeline.
///
/// `mesh` is the Bluetooth/fallback path; `smsBridge` is SMS arriving from
/// a feature phone that doesn't run the app; `smsTransport` is SMS between
/// two app users; `internet` is a Firestore push/pop leg (SPEC.md §0).
enum MessageOrigin {
  mesh,
  smsBridge,
  smsTransport,
  internet;

  static MessageOrigin fromJson(String? value) {
    if (value == null) {
      throw const FormatException('Message.origin is required');
    }
    switch (value) {
      case 'MESH':
        return MessageOrigin.mesh;
      case 'SMS_BRIDGE':
        return MessageOrigin.smsBridge;
      case 'SMS_TRANSPORT':
        return MessageOrigin.smsTransport;
      case 'INTERNET':
        return MessageOrigin.internet;
      default:
        throw FormatException('Unknown MessageOrigin: $value');
    }
  }

  String toJson() {
    switch (this) {
      case MessageOrigin.mesh:
        return 'MESH';
      case MessageOrigin.smsBridge:
        return 'SMS_BRIDGE';
      case MessageOrigin.smsTransport:
        return 'SMS_TRANSPORT';
      case MessageOrigin.internet:
        return 'INTERNET';
    }
  }
}

// ---------------------------------------------------------------------------
// GeoLocation
// ---------------------------------------------------------------------------

/// Optional GPS fix attached to a message.
///
/// `accuracy` is in meters; `null` when the platform didn't report it.
class GeoLocation {
  final double latitude;
  final double longitude;
  final double? accuracyMeters;

  const GeoLocation({
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
  });

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lon': longitude,
        if (accuracyMeters != null) 'accuracy_m': accuracyMeters,
      };

  static GeoLocation fromJson(Map<String, dynamic> json) {
    final lat = json['lat'];
    final lon = json['lon'];
    if (lat is! num || lon is! num) {
      throw const FormatException(
        'GeoLocation requires numeric "lat" and "lon" fields',
      );
    }
    final acc = json['accuracy_m'];
    return GeoLocation(
      latitude: lat.toDouble(),
      longitude: lon.toDouble(),
      accuracyMeters: acc is num ? acc.toDouble() : null,
    );
  }

  GeoLocation copyWith({
    double? latitude,
    double? longitude,
    double? accuracyMeters,
  }) {
    return GeoLocation(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GeoLocation &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.accuracyMeters == accuracyMeters;
  }

  @override
  int get hashCode => Object.hash(latitude, longitude, accuracyMeters);

  @override
  String toString() =>
      'GeoLocation($latitude, $longitude, accuracy=${accuracyMeters ?? 'n/a'})';
}

// ---------------------------------------------------------------------------
// MessageDefaults
// ---------------------------------------------------------------------------

/// Default TTLs (in mesh hops) per message type.
///
/// SOS needs the longest reach — life-safety — so it gets 12 hops.
/// ALERT (verified warnings) gets 10. Everything else gets 8. See
/// SPEC.md §5 "TTLs".
class MessageDefaults {
  const MessageDefaults._();

  static const int sosTtl = 12;
  static const int alertTtl = 10;
  static const int defaultTtl = 8;

  /// The default TTL for a given [type], in mesh hops.
  static int defaultTtlFor(MessageType type) {
    switch (type) {
      case MessageType.sos:
        return sosTtl;
      case MessageType.alert:
        return alertTtl;
      case MessageType.statusSafe:
      case MessageType.statusHelp:
      case MessageType.chat:
      case MessageType.ack:
      case MessageType.evidenceNotice:
        return defaultTtl;
    }
  }
}

// ---------------------------------------------------------------------------
// Message
// ---------------------------------------------------------------------------

/// One RelayLink message envelope, ready for serialization to JSON and
/// dispatch over mesh, SMS, or internet.
///
/// All routing fields are plaintext (id, mode, type, channel_id, ttl,
/// hop_count, origin, recipient_id, created_at, signature). The body
/// (`payload`) is ciphertext opaque to the envelope. `ratchet_header` is
/// also plaintext per SPEC.md §5 so the recipient can derive the message
/// key, but it only exists when [mode] == [MessageMode.direct].
class Message {
  /// UUIDv4 identifying this message. Used for seen-cache dedup and
  /// SMS fragment reassembly (SPEC.md §7).
  final String id;

  /// Broadcast (channel) or direct (1:1).
  final MessageMode mode;

  /// What kind of message this is.
  final MessageType type;

  /// Channel this message belongs to. Empty string for DIRECT messages.
  final String channelId;

  /// Stable pseudonymous device id of the sender.
  final String senderId;

  /// Human-readable display name of the sender (best-effort, may be empty).
  final String senderDisplayName;

  /// Which transport this message entered the local pipeline from.
  final MessageOrigin origin;

  /// For [MessageMode.direct]: recipient device id. `null` for broadcast.
  final String? recipientId;

  /// Encrypted payload (opaque to the envelope). Always present; may be
  /// empty for control messages like ACK.
  final Uint8List payload;

  /// Double-ratchet header — only present when [mode] == [MessageMode.direct].
  final Uint8List? ratchetHeader;

  /// Optional GPS fix.
  final GeoLocation? location;

  /// UTC creation timestamp.
  final DateTime createdAt;

  /// Remaining mesh hops. Decremented at each relay.
  final int ttl;

  /// How many hops this message has already traversed.
  final int hopCount;

  /// Ed25519 signature over ciphertext + metadata, base64-encoded.
  /// `null` only for unsigned control messages (rare; see SPEC.md §5).
  final Uint8List? signature;

  /// If this message is a reply to another, the original message's id.
  final String? inResponseTo;

  const Message({
    required this.id,
    required this.mode,
    required this.type,
    required this.channelId,
    required this.senderId,
    required this.senderDisplayName,
    required this.origin,
    required this.recipientId,
    required this.payload,
    required this.ratchetHeader,
    required this.location,
    required this.createdAt,
    required this.ttl,
    required this.hopCount,
    required this.signature,
    required this.inResponseTo,
  });

  /// Build a Message with sensible defaults for a freshly authored outgoing
  /// message: fresh UUIDv4 id, UTC timestamp, default TTL for [type],
  /// hop_count = 0, no signature, no ratchet header, no location, no reply.
  factory Message.create({
    required MessageMode mode,
    required MessageType type,
    required String channelId,
    required String senderId,
    String senderDisplayName = '',
    MessageOrigin origin = MessageOrigin.mesh,
    String? recipientId,
    Uint8List? payload,
    Uint8List? ratchetHeader,
    GeoLocation? location,
    int? ttl,
    Uint8List? signature,
    String? inResponseTo,
  }) {
    return Message(
      id: const Uuid().v4(),
      mode: mode,
      type: type,
      channelId: channelId,
      senderId: senderId,
      senderDisplayName: senderDisplayName,
      origin: origin,
      recipientId: recipientId,
      payload: payload ?? Uint8List(0),
      ratchetHeader: ratchetHeader,
      location: location,
      createdAt: DateTime.now().toUtc(),
      ttl: ttl ?? MessageDefaults.defaultTtlFor(type),
      hopCount: 0,
      signature: signature,
      inResponseTo: inResponseTo,
    );
  }

  /// Decodes a [Message] from a JSON map. Byte fields (`payload`,
  /// `ratchet_header`, `signature`) are base64-encoded.
  factory Message.fromJson(Map<String, dynamic> json) {
    final mode = MessageMode.fromJson(json['mode'] as String?);
    final ratchetHeaderB64 = json['ratchet_header'] as String?;
    Uint8List? ratchetHeaderBytes;
    if (ratchetHeaderB64 != null) {
      ratchetHeaderBytes = base64.decode(ratchetHeaderB64);
      if (mode != MessageMode.direct) {
        // SPEC.md §5: ratchet_header is only present when mode == DIRECT.
        // Be strict on decode so malformed envelopes fail loudly.
        throw const FormatException(
          'ratchet_header is only valid when mode == DIRECT',
        );
      }
    } else if (mode == MessageMode.direct) {
      // Not strictly required by §5 (a DIRECT message could legitimately
      // be the very first one with no header yet), so allow null.
    }

    final signatureB64 = json['signature'] as String?;
    final payloadB64 = json['payload'] as String?;
    if (payloadB64 == null) {
      throw const FormatException('Message.payload is required');
    }

    final locationJson = json['location'];
    GeoLocation? location;
    if (locationJson is Map<String, dynamic>) {
      location = GeoLocation.fromJson(locationJson);
    } else if (locationJson != null) {
      throw const FormatException(
        'Message.location must be a JSON object when present',
      );
    }

    final createdAtRaw = json['created_at'];
    if (createdAtRaw is! String) {
      throw const FormatException('Message.created_at must be an ISO-8601 string');
    }
    final createdAt = DateTime.parse(createdAtRaw).toUtc();

    final recipientRaw = json['recipient_id'];
    final recipientId = recipientRaw is String ? recipientRaw : null;

    final inResponseToRaw = json['in_response_to'];
    final inResponseTo = inResponseToRaw is String ? inResponseToRaw : null;

    return Message(
      id: json['id'] as String,
      mode: mode,
      type: MessageType.fromJson(json['type'] as String?),
      channelId: (json['channel_id'] as String?) ?? '',
      senderId: (json['sender_id'] as String?) ?? '',
      senderDisplayName: (json['sender_display_name'] as String?) ?? '',
      origin: MessageOrigin.fromJson(json['origin'] as String?),
      recipientId: recipientId,
      payload: base64.decode(payloadB64),
      ratchetHeader: ratchetHeaderBytes,
      location: location,
      createdAt: createdAt,
      ttl: (json['ttl'] as num).toInt(),
      hopCount: (json['hop_count'] as num).toInt(),
      signature: signatureB64 != null ? base64.decode(signatureB64) : null,
      inResponseTo: inResponseTo,
    );
  }

  /// Encodes this [Message] to a JSON map. Byte fields (`payload`,
  /// `ratchet_header`, `signature`) are base64-encoded.
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'mode': mode.toJson(),
      'type': type.toJson(),
      'channel_id': channelId,
      'sender_id': senderId,
      'sender_display_name': senderDisplayName,
      'origin': origin.toJson(),
      'payload': base64.encode(payload),
      'created_at': createdAt.toUtc().toIso8601String(),
      'ttl': ttl,
      'hop_count': hopCount,
    };
    if (recipientId != null) {
      map['recipient_id'] = recipientId;
    }
    if (mode == MessageMode.direct && ratchetHeader != null) {
      map['ratchet_header'] = base64.encode(ratchetHeader!);
    }
    if (location != null) {
      map['location'] = location!.toJson();
    }
    if (signature != null) {
      map['signature'] = base64.encode(signature!);
    }
    if (inResponseTo != null) {
      map['in_response_to'] = inResponseTo;
    }
    return map;
  }

  /// Returns a copy with the supplied fields replaced. Used heavily by
  /// the relay path: decrement `ttl`, increment `hop_count`, update
  /// `origin` when a message is re-injected from another transport.
  Message copyWith({
    String? id,
    MessageMode? mode,
    MessageType? type,
    String? channelId,
    String? senderId,
    String? senderDisplayName,
    MessageOrigin? origin,
    String? recipientId,
    Uint8List? payload,
    Uint8List? ratchetHeader,
    GeoLocation? location,
    DateTime? createdAt,
    int? ttl,
    int? hopCount,
    Uint8List? signature,
    String? inResponseTo,
  }) {
    return Message(
      id: id ?? this.id,
      mode: mode ?? this.mode,
      type: type ?? this.type,
      channelId: channelId ?? this.channelId,
      senderId: senderId ?? this.senderId,
      senderDisplayName: senderDisplayName ?? this.senderDisplayName,
      origin: origin ?? this.origin,
      recipientId: recipientId ?? this.recipientId,
      payload: payload ?? this.payload,
      ratchetHeader: ratchetHeader ?? this.ratchetHeader,
      location: location ?? this.location,
      createdAt: createdAt ?? this.createdAt,
      ttl: ttl ?? this.ttl,
      hopCount: hopCount ?? this.hopCount,
      signature: signature ?? this.signature,
      inResponseTo: inResponseTo ?? this.inResponseTo,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Message &&
        other.id == id &&
        other.mode == mode &&
        other.type == type &&
        other.channelId == channelId &&
        other.senderId == senderId &&
        other.senderDisplayName == senderDisplayName &&
        other.origin == origin &&
        other.recipientId == recipientId &&
        _bytesEqual(other.payload, payload) &&
        _bytesEqual(other.ratchetHeader, ratchetHeader) &&
        other.location == location &&
        other.createdAt.isAtSameMomentAs(createdAt) &&
        other.ttl == ttl &&
        other.hopCount == hopCount &&
        _bytesEqual(other.signature, signature) &&
        other.inResponseTo == inResponseTo;
  }

  @override
  int get hashCode => Object.hash(
        id,
        mode,
        type,
        channelId,
        senderId,
        senderDisplayName,
        origin,
        recipientId,
        Object.hashAll(payload),
        Object.hashAll(ratchetHeader ?? Uint8List(0)),
        location,
        createdAt,
        ttl,
        hopCount,
        Object.hashAll(signature ?? Uint8List(0)),
        inResponseTo,
      );

  @override
  String toString() {
    return 'Message(id=$id, mode=${mode.toJson()}, type=${type.toJson()}, '
        'channel=$channelId, sender=$senderId, '
        'origin=${origin.toJson()}, ttl=$ttl, hop=$hopCount)';
  }
}

bool _bytesEqual(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}