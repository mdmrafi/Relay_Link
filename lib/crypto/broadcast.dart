// RelayLink — Ticket #03: BROADCAST crypto.
//
// Provides AES-256-GCM authenticated encryption for the public/default
// broadcast channel and any additional channels registered at runtime.
//
// Threat-model caveat (per ticket spec):
//   The default `networkKey` is *embedded in the source tree*. This deters
//   casual eavesdropping on the wire, but it is NOT a secret — anyone with
//   the binary can recover it. It is suitable for "deter the curious", not
//   for protecting messages from a resourced adversary. Real privacy on a
//   public channel requires per-recipient encryption (see Ticket #13,
//   DIRECT crypto / Double Ratchet), which is layered on top later.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Identifier for the default public channel that every RelayLink peer ships
/// with. Anyone can read/write to `"public"` using the embedded `networkKey`.
const String kPublicChannelId = 'public';

/// Default AES-256 key for the `"public"` channel.
///
/// ⚠️  EMBEDDED IN SOURCE — NOT A SECRET. See file header for the full
/// threat-model caveat. Generated as 32 random bytes, base64-encoded for
/// compactness. Decode via `base64.decode(networkKey)` before use.
///
/// Caveat (per ticket spec): deters casual eavesdropping, not a resourced
/// adversary — documented in README and inline comment.
final List<int> networkKey = base64.decode(
  'TzzCgUZGoX8fRwZvrvCaKkNRcJX/ij643ULqHD5vcxU=',
);

/// The AES-256-GCM algorithm instance used by [BroadcastCrypto].
///
/// `with256bits` selects a 32-byte key. The default 12-byte nonce length is
/// the recommended size for GCM.
final AesGcm _aesGcm = AesGcm.with256bits();

/// Wire-shape of an encrypted BROADCAST message.
///
/// All fields are byte arrays so the envelope can be JSON-encoded later
/// (Ticket #04 owns the message schema and wire format).
class BroadcastEnvelope {
  /// The channel this message was encrypted under.
  final String channelId;

  /// GCM nonce (12 bytes). Must be unique per (key, message).
  final List<int> nonce;

  /// AES-GCM ciphertext. Same length as plaintext.
  final List<int> ciphertext;

  /// GCM authentication tag (16 bytes). Bind integrity to [channelId].
  final List<int> mac;

  const BroadcastEnvelope({
    required this.channelId,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  /// Decode an envelope from raw UTF-8 JSON bytes (as carried in a
  /// `Message.payload` field). Used by the chat widget test seam and by
  /// any relay that needs to peek at the embedded channel id.
  ///
  /// Throws [FormatException] if the input is not a `{channelId, nonce,
  /// ciphertext, mac}` JSON object.
  factory BroadcastEnvelope.fromJsonBytes(List<int> bytes) {
    final map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return BroadcastEnvelope(
      channelId: map['channelId'] as String,
      nonce: _decodeB64(map['nonce'] as String),
      ciphertext: _decodeB64(map['ciphertext'] as String),
      mac: _decodeB64(map['mac'] as String),
    );
  }

  /// Serialize this envelope to a JSON-compatible map. Used by the
  /// `LocalChatController` to encode the ciphertext into a
  /// `Message.payload` field.
  Map<String, dynamic> toJsonMap() => <String, dynamic>{
        'channelId': channelId,
        'nonce': base64.encode(nonce),
        'ciphertext': base64.encode(ciphertext),
        'mac': base64.encode(mac),
      };
}

List<int> _decodeB64(String s) => base64.decode(s);

/// Thrown when [BroadcastCrypto.decrypt] is called with a [channelId] we
/// have no key for.
///
/// This is distinct from a generic crypto failure so callers can
/// meaningfully handle "I don't have this channel" vs. "key is wrong but
/// MAC checked out for some other reason" — the former is recoverable
/// (e.g. ask the peer for the channel invite), the latter is a bug or
/// an active attack.
class UnknownChannelException implements Exception {
  /// The channelId we were asked to decrypt for.
  final String channelId;

  const UnknownChannelException(this.channelId);

  @override
  String toString() => 'UnknownChannelException: no key registered for '
      'channel "$channelId"';
}

/// Authenticated encryption for the BROADCAST transport.
///
/// Usage:
///
/// ```dart
/// final crypto = BroadcastCrypto();
///
/// // Default public channel.
/// final env = await crypto.encryptString('hello world', kPublicChannelId);
/// final pt  = await crypto.decryptString(env);
///
/// // Custom channel.
/// crypto.setChannelKey('ops', some32ByteKey);
/// final env2 = await crypto.encryptString('ops note', 'ops');
/// ```
///
/// Internally:
///   * Uses AES-256-GCM via the `cryptography` package (no hand-rolled
///     primitives).
///   * Binds the [channelId] into the GCM AAD so an attacker can't replay
///     a ciphertext from one channel under a different channel id.
class BroadcastCrypto {
  /// Channel-id → 32-byte AES key. Seeded with the default public channel.
  final Map<String, List<int>> _keys;

  /// Construct with the default public channel pre-registered. If you want
  /// an empty registry (e.g. tests), use [BroadcastCrypto.withKeys] with an
  /// empty map.
  BroadcastCrypto()
      : _keys = <String, List<int>>{
          kPublicChannelId: List<int>.unmodifiable(networkKey),
        };

  /// Construct with an explicit key map. Useful for tests.
  BroadcastCrypto.withKeys(Map<String, List<int>> keys) : _keys = Map.of(keys);

  /// Register (or replace) the AES-256 key for [channelId].
  ///
  /// [key] MUST be exactly 32 bytes for AES-256-GCM. An [ArgumentError] is
  /// thrown otherwise — we deliberately fail loud rather than silently
  /// truncating or padding.
  void setChannelKey(String channelId, List<int> key) {
    if (key.length != 32) {
      throw ArgumentError.value(
        key,
        'key',
        'AES-256-GCM requires a 32-byte key, got ${key.length} bytes',
      );
    }
    _keys[channelId] = List<int>.unmodifiable(key);
  }

  /// Whether a key is registered for [channelId].
  bool hasChannelKey(String channelId) => _keys.containsKey(channelId);

  /// Encrypt [plaintext] (raw bytes) under [channelId]'s registered key.
  ///
  /// Throws [UnknownChannelException] if no key is registered for
  /// [channelId].
  Future<BroadcastEnvelope> encrypt(
    List<int> plaintext,
    String channelId,
  ) async {
    final key = _lookupKey(channelId);
    final secretKey = SecretKey(key);
    // AAD binds the ciphertext to its channel — an envelope captured on the
    // public channel cannot be replayed under a custom channel id.
    final aad = utf8.encode(channelId);

    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      aad: aad,
    );

    return BroadcastEnvelope(
      channelId: channelId,
      nonce: Uint8List.fromList(box.nonce),
      ciphertext: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Decrypt [envelope] back to plaintext.
  ///
  /// Throws:
  ///   * [UnknownChannelException] — no key for `envelope.channelId`.
  ///   * [SecretBoxAuthenticationError] (from `cryptography`) — the MAC did
  ///     not verify, i.e. ciphertext or channelId was tampered with, or the
  ///     wrong key was used. Never partial-leaks plaintext.
  Future<List<int>> decrypt(BroadcastEnvelope envelope) async {
    final key = _lookupKey(envelope.channelId);
    final secretKey = SecretKey(key);
    final aad = utf8.encode(envelope.channelId);

    final box = SecretBox(
      envelope.ciphertext,
      nonce: envelope.nonce,
      mac: Mac(envelope.mac),
    );

    // AAD binds the ciphertext to its channel — an envelope captured on the
    // public channel cannot be replayed under a custom channel id.
    return _aesGcm.decrypt(box, secretKey: secretKey, aad: aad);
  }

  /// Convenience: encrypt a UTF-8 string.
  Future<BroadcastEnvelope> encryptString(
    String plaintext,
    String channelId,
  ) =>
      encrypt(utf8.encode(plaintext), channelId);

  /// Convenience: decrypt to a UTF-8 string.
  Future<String> decryptString(BroadcastEnvelope envelope) async {
    final bytes = await decrypt(envelope);
    return utf8.decode(bytes);
  }

  List<int> _lookupKey(String channelId) {
    final key = _keys[channelId];
    if (key == null) {
      throw UnknownChannelException(channelId);
    }
    return key;
  }
}
