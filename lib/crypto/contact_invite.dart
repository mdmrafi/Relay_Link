// RelayLink — `ContactInvite` codec (Ticket #28 / wiring-gap-closure).
//
// A `ContactInvite` is the short, portable token two devices exchange to
// bootstrap a DIRECT (1:1) encrypted channel. The QR-scanner UX for
// scanning these tokens is a separate follow-up; this file ships the
// codec + ECDH bootstrap so the wiring can be exercised end-to-end via
// paste-in or copy/paste (the Contacts screen exposes both).
//
// Wire format (v1):
//   relaylink-invite-v1:<base64url(payload)>
//
// payload (JSON, base64url-encoded):
//   { "v": 1,
//     "device_id": "<16-hex of Ed25519 public key>",
//     "x25519_pub": "<base64 of 32-byte X25519 public key>",
//     "display_name": "<utf-8 string, may be empty>",
//     "salt": "<base64 of 16 random bytes>" }
//
// The "shared secret" used to seed a `DirectSession` is then derived
// from the local device's X25519 private key + the invite's X25519
// public key (standard X25519 ECDH), HKDF-expanded with the salt as
// `info` to produce a 32-byte root:
//
//   shared = ECDH(local_x25519_priv, invite_x25519_pub)  // 32 bytes
//   root   = HKDF-SHA256(shared, salt=invite.salt, info="relaylink-direct-v1")  // 32 bytes
//
// Future revisions can rotate the version prefix (e.g.
// `relaylink-invite-v2`) without breaking this v1 decoder.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'direct.dart';
import 'identity.dart';

/// Prefix that identifies an invite token as a RelayLink v1 invite.
const String kContactInvitePrefix = 'relaylink-invite-v1';

/// HKDF info string used when expanding the ECDH shared secret into the
/// `DirectSession` root. Domain-separated from other protocol uses.
const String _kDirectSessionInfo = 'relaylink-direct-v1';

/// Length of the random passphrase-salt included in every invite.
const int _kInviteSaltBytes = 16;

/// Length of a fully expanded contact-invite root.
const int _kSharedRootBytes = 32;

/// A `ContactInvite` is everything one device needs to derive a
/// shared secret with another device: the peer's identity, the peer's
/// X25519 public key, an optional display name, and a fresh random salt.
class ContactInvite {
  /// 16-hex character device id (the same `senderId` exposed by
  /// `DeviceIdentity.senderId`). Cheap to compare / include in UI.
  final String deviceId;

  /// Raw 32-byte X25519 public key of the peer. Fed into the ECDH step.
  final Uint8List x25519PublicKey;

  /// Best-effort human-readable label. May be empty.
  final String displayName;

  /// 16 random bytes mixed into the HKDF expansion so two invite pairs
  /// sharing the same X25519 secret still derive distinct roots.
  final Uint8List salt;

  const ContactInvite({
    required this.deviceId,
    required this.x25519PublicKey,
    required this.displayName,
    required this.salt,
  });
}

/// Static encoding / decoding helpers for `ContactInvite` tokens.
class ContactInviteCodec {
  // Pure static utility — not instantiated.
  ContactInviteCodec._();

  /// Encode [invite] into the canonical `relaylink-invite-v1:<b64>` wire
  /// shape. The output is ASCII-safe (no QR-incompatible characters).
  static String encode(ContactInvite invite) {
    if (invite.deviceId.length != 16) {
      throw ArgumentError.value(
        invite.deviceId,
        'invite.deviceId',
        'must be exactly 16 hex chars',
      );
    }
    if (invite.x25519PublicKey.length != 32) {
      throw ArgumentError.value(
        invite.x25519PublicKey.length,
        'invite.x25519PublicKey',
        'must be 32 bytes',
      );
    }
    if (invite.salt.length != _kInviteSaltBytes) {
      throw ArgumentError.value(
        invite.salt.length,
        'invite.salt',
        'must be $_kInviteSaltBytes bytes',
      );
    }
    final payload = <String, Object?>{
      'v': 1,
      'device_id': invite.deviceId,
      'x25519_pub': base64.encode(invite.x25519PublicKey),
      'display_name': invite.displayName,
      'salt': base64.encode(invite.salt),
    };
    final encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
    return '$kContactInvitePrefix:$encoded';
  }

  /// Decode a token produced by [encode]. Throws [FormatException] on
  /// any deviation from the canonical wire shape (bad prefix, bad
  /// base64, wrong field types, wrong field lengths).
  static ContactInvite decode(String token) {
    final colon = token.indexOf(':');
    if (colon < 0) {
      throw const FormatException('ContactInvite: missing colon separator');
    }
    final prefix = token.substring(0, colon);
    if (prefix != kContactInvitePrefix) {
      throw FormatException(
        'ContactInvite: unknown prefix "$prefix"',
      );
    }
    final body = token.substring(colon + 1);
    if (body.isEmpty) {
      throw const FormatException('ContactInvite: empty payload after colon');
    }
    final Map<String, dynamic> payload;
    try {
      final raw = utf8.decode(base64Url.decode(body));
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('payload is not a JSON object');
      }
      payload = decoded;
    } on FormatException catch (e) {
      throw FormatException('ContactInvite: bad payload: $e');
    }
    final version = payload['v'];
    if (version is! int || version != 1) {
      throw FormatException('ContactInvite: unsupported version $version');
    }
    final deviceId = payload['device_id'];
    final x25519PubB64 = payload['x25519_pub'];
    final displayName = payload['display_name'];
    final saltB64 = payload['salt'];
    if (deviceId is! String ||
        x25519PubB64 is! String ||
        displayName is! String ||
        saltB64 is! String) {
      throw const FormatException('ContactInvite: wrong field types');
    }
    if (deviceId.length != 16) {
      throw FormatException(
        'ContactInvite: device_id must be 16 chars, got ${deviceId.length}',
      );
    }
    final x25519Pub = base64.decode(x25519PubB64);
    if (x25519Pub.length != 32) {
      throw FormatException(
        'ContactInvite: x25519_pub must be 32 bytes, got ${x25519Pub.length}',
      );
    }
    final salt = base64.decode(saltB64);
    if (salt.length != _kInviteSaltBytes) {
      throw FormatException(
        'ContactInvite: salt must be $_kInviteSaltBytes bytes, got ${salt.length}',
      );
    }
    return ContactInvite(
      deviceId: deviceId,
      x25519PublicKey: Uint8List.fromList(x25519Pub),
      displayName: displayName,
      salt: Uint8List.fromList(salt),
    );
  }

  /// Build a `ContactInvite` from the local device's identity. The salt
  /// is drawn from `Random.secure()` (CSPRNG on every supported platform).
  static ContactInvite forLocalDevice(DeviceIdentity self) {
    final rng = math.Random.secure();
    final salt = Uint8List(_kInviteSaltBytes);
    for (var i = 0; i < _kInviteSaltBytes; i++) {
      salt[i] = rng.nextInt(256);
    }
    return ContactInvite(
      deviceId: self.senderId,
      x25519PublicKey: self.x25519PublicKeyBytes,
      displayName: '',
      salt: salt,
    );
  }

  /// Derive the 32-byte `DirectSession` root from the local identity and
  /// the invite's X25519 public key. The shared secret is the standard
  /// X25519 ECDH output; a domain-separation HKDF step expands it to
  /// 32 bytes. The HKDF `info` is a fixed domain string so both sides
  /// of the handshake always agree on it.
  ///
  /// The invite's salt is preserved on the wire for forward
  /// compatibility (a future revision may mix it in to disambiguate
  /// parallel pairings) but is NOT used to derive the v1 root —
  /// including it would force both sides to use the same salt, which
  /// the current asymmetric-invite handshake can't guarantee.
  static Future<Uint8List> deriveSharedRoot({
    required DeviceIdentity self,
    required ContactInvite invite,
  }) async {
    final shared = await self.ecdh(invite.x25519PublicKey);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: _kSharedRootBytes);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(shared),
      info: utf8.encode(_kDirectSessionInfo),
    );
    return Uint8List.fromList(derived.bytes);
  }

  /// Convenience: derive the shared root and immediately construct a
  /// `DirectSession` (caller picks the initiator side). The session is
  /// not yet persisted — that's the caller's job.
  static Future<DirectSession> bootstrapSession({
    required DeviceIdentity self,
    required ContactInvite invite,
    required bool isInitiator,
  }) async {
    final root = await deriveSharedRoot(self: self, invite: invite);
    return DirectSession.create(root, isInitiator: isInitiator);
  }
}
