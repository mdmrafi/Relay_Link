// RelayLink — Ticket #13 DIRECT crypto.
//
// Per Ticket #13 and the D5 verdict (see VERDICT.md), this implements the
// HKDF-chain fallback: a single symmetric HMAC chain per direction,
// seeded from the 32-byte shared secret produced by the QR-exchange ECDH
// (Ticket #02). This gives forward secrecy across the chain — compromise
// of message key N does NOT expose messages 1..N-1 — but does NOT give
// post-compromise secrecy (a leaked current chain key exposes all future
// keys until the chain is re-seeded). For production §6.3 compliance a
// full Double Ratchet would be required; per D5 we ship the HKDF-chain
// fallback for the hackathon demo.
//
// Chain design (mirrors the symmetric half of libsignal's ChainKey):
//   root_alice := HKDF(shared_secret, info=[0x01], out=32)
//   root_bob   := HKDF(shared_secret, info=[0x02], out=32)
//   next_chain_key := HMAC-SHA256(chain_key, [0x02])
//   message_key_seed := HMAC-SHA256(chain_key, [0x01])
//   message_key := HKDF(message_key_seed, info=<dir><msgIndex>, out=64)
//               -> 32-byte AES key + 32-byte HMAC key.
//
// The same shared secret with opposite direction bytes yields
// independent chains.
//
// The message key is used exactly once for AES-256-GCM; the nonce is
// deterministic (derived from direction + msgIndex) because each
// message key is unique, so nonce reuse with the same key is impossible.
// Forward secrecy follows automatically because each chain_key is the
// output of HMAC over the previous one — knowing any later key cannot
// invert HMAC.
//
// Skipped-key storage is intentionally omitted — the ticket marks it
// optional and skipping it keeps the demo scope tight.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

final Hmac _hmacSha256 = Hmac.sha256();
final Hkdf _hkdf64 = Hkdf(hmac: _hmacSha256, outputLength: 64);
final Hkdf _hkdf32 = Hkdf(hmac: _hmacSha256, outputLength: 32);
final AesGcm _aesGcm = AesGcm.with256bits();

final Uint8List _messageKeySeed = Uint8List.fromList([0x01]);
final Uint8List _chainKeySeed = Uint8List.fromList([0x02]);

const int _kInitiatorTag = 0x01; // Alice -> Bob
const int _kResponderTag = 0x02; // Bob -> Alice

Uint8List _hkdfInfo(int directionByte, int msgIndex) {
  final out = Uint8List(1 + 4);
  out[0] = directionByte;
  final b = ByteData.sublistView(out, 1);
  b.setUint32(0, msgIndex, Endian.big);
  return out;
}

Uint8List _fixedNonce(int directionByte, int msgIndex) {
  // Deterministic 12-byte GCM nonce. Safe because every message uses a
  // unique AES key.
  final out = Uint8List(12);
  out[0] = directionByte;
  final b = ByteData.sublistView(out, 4);
  b.setUint32(0, msgIndex, Endian.big);
  return out;
}

Future<Uint8List> _hmacChainStep(
  Uint8List chainKey,
  Uint8List seed,
) async {
  final mac = await _hmacSha256.calculateMac(seed, secretKey: SecretKey(chainKey));
  return Uint8List.fromList(mac.bytes);
}

Future<Uint8List> _deriveMessageKey({
  required Uint8List chainKey,
  required int directionByte,
  required int msgIndex,
}) async {
  final msgSeed = await _hmacChainStep(chainKey, _messageKeySeed);
  final derived = await _hkdf64.deriveKey(
    secretKey: SecretKey(msgSeed),
    info: _hkdfInfo(directionByte, msgIndex),
  );
  return Uint8List.fromList(derived.bytes);
}

/// Wire header that travels alongside the ciphertext. Carries the message
/// index from the sender's chain so the receiver can advance its own
/// stored chain key for this direction by the same number of steps before
/// deriving the message key.
class DirectRatchetHeader {
  /// Sequential index of this message on the sender's chain. Starts at 0.
  final int msgIndex;

  /// Direction byte: 0x01 for initiator->responder, 0x02 for responder->
  /// initiator.
  final int directionByte;

  const DirectRatchetHeader({
    required this.msgIndex,
    required this.directionByte,
  });
}

/// Encrypted DIRECT message: ciphertext-with-tag + ratchet header. Also
/// carries the chain key that was live just AFTER encrypting (i.e. the
/// next chain key), exposed for the forward-secrecy test (and useful for
/// any state-sync machinery later).
class DirectMessage {
  final Uint8List ciphertext;
  final DirectRatchetHeader ratchetHeader;
  final Uint8List chainKeyAfterMessage;

  const DirectMessage({
    required this.ciphertext,
    required this.ratchetHeader,
    required this.chainKeyAfterMessage,
  });
}

/// A two-direction HKDF-chain session. Each side holds a sender chain
/// (which it advances on every [encrypt]) and a receiver chain (which it
/// advances on every [decrypt]). The two chains are NOT the same because
/// the direction byte is mixed into the root derivation.
///
/// NOTE: this class is the LEGACY HKDF-chain fallback from the original
/// ticket #13 work. The full Double Ratchet has since been implemented
/// and lives at `package:relaylink/crypto/double_ratchet.dart`
/// ([DoubleRatchetSession]). Use [DoubleRatchetSession] for new code
/// that needs post-compromise secrecy; this class is preserved verbatim
/// because the on-the-wire format it produces is still consumed by
/// older app installs and is exercised by
/// `test/crypto/direct_test.dart`. The alias [DirectSession.legacy] is
/// provided as an explicit entry point:
///
/// ```dart
/// final alice = await DirectSession.legacy(seed, isInitiator: true);
/// ```
class DirectSession {
  Uint8List _sendChainKey;
  int _sendCounter;
  Uint8List _recvChainKey;
  int _recvCounter;
  final int _initiatorTag;

  DirectSession._(
    this._sendChainKey,
    this._sendCounter,
    this._recvChainKey,
    this._recvCounter,
    this._initiatorTag,
  );

  /// Construct a new session from a 32-byte shared secret.
  ///
  /// [isInitiator]: true if the user initiated the QR exchange (Alice in
  /// the canonical demo), false if they responded to it (Bob). The two
  /// sides MUST use opposite values for the chains to be independent.
  ///
  /// This is the LEGACY HKDF-chain fallback. For new code that needs
  /// post-compromise secrecy, use
  /// `package:relaylink/crypto/double_ratchet.dart` instead. This
  /// factory is preserved for backward compatibility with the
  /// integrations in `lib/sms/direct_adapter.dart` and
  /// `lib/transport/internet.dart` and the unit tests in
  /// `test/crypto/direct_test.dart`.
  static Future<DirectSession> create(
    List<int> sharedSecret, {
    required bool isInitiator,
  }) async {
    if (sharedSecret.length != 32) {
      throw ArgumentError.value(
        sharedSecret.length,
        'sharedSecret.length',
        'HKDF-chain fallback requires a 32-byte shared secret',
      );
    }
    // Two independent root keys, derived from the same shared secret by
    // mixing the direction byte into the HKDF info.
    final aliceRoot = await _deriveRoot(sharedSecret, _kInitiatorTag);
    final bobRoot = await _deriveRoot(sharedSecret, _kResponderTag);
    if (isInitiator) {
      // Alice: writes on Alice->Bob chain (aliceRoot), reads on
      // Bob->Alice chain (bobRoot).
      return DirectSession._(aliceRoot, 0, bobRoot, 0, _kInitiatorTag);
    }
    return DirectSession._(bobRoot, 0, aliceRoot, 0, _kResponderTag);
  }

  /// Construct a session that continues from a known chain key. Used by
  /// the forward-secrecy test to simulate compromise of [chainKey]
  /// followed by a new sender starting from it.
  static Future<DirectSession> fromChainKey(
    List<int> chainKey, {
    required bool isInitiator,
    int nextMessageIndex = 0,
  }) async {
    if (chainKey.length != 32) {
      throw ArgumentError.value(
        chainKey.length,
        'chainKey.length',
        'fromChainKey requires a 32-byte chain key',
      );
    }
    final oppositeRoot = await _deriveRoot(
      chainKey,
      isInitiator ? _kResponderTag : _kInitiatorTag,
    );
    return DirectSession._(
      Uint8List.fromList(chainKey),
      nextMessageIndex,
      oppositeRoot,
      0,
      isInitiator ? _kInitiatorTag : _kResponderTag,
    );
  }

  /// Encrypt [plaintext] (UTF-8 string) under the SENDER chain. Returns
  /// a [DirectMessage] carrying the ciphertext (with 16-byte GCM tag
  /// appended) and a ratchet header.
  Future<DirectMessage> encrypt(String plaintext) async {
    final msgIndex = _sendCounter;
    final senderTag = _initiatorTag; // initiator writes Alice->Bob.

    final msgKey = await _deriveMessageKey(
      chainKey: _sendChainKey,
      directionByte: senderTag,
      msgIndex: msgIndex,
    );
    final aesKey = msgKey.sublist(0, 32);
    final nextChainKey = await _hmacChainStep(_sendChainKey, _chainKeySeed);

    final nonce = _fixedNonce(senderTag, msgIndex);
    final aad = utf8.encode('relaylink-direct-v1');
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(aesKey),
      nonce: nonce,
      aad: aad,
    );

    final header = DirectRatchetHeader(
      msgIndex: msgIndex,
      directionByte: senderTag,
    );

    _sendChainKey = nextChainKey;
    _sendCounter = msgIndex + 1;

    return DirectMessage(
      ciphertext: Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]),
      ratchetHeader: header,
      chainKeyAfterMessage: nextChainKey,
    );
  }

  /// Decrypt [ciphertext] (with appended 16-byte GCM tag) produced by a
  /// peer's [encrypt]. Advances the RECEIVER chain by the number of
  /// messages between the last seen header and this one, then derives the
  /// message key from the resulting chain key.
  Future<String> decrypt(
    List<int> ciphertext,
    DirectRatchetHeader header,
  ) async {
    final expectedTag = (_initiatorTag == _kInitiatorTag) ? _kResponderTag : _kInitiatorTag;
    if (header.directionByte != expectedTag) {
      throw ArgumentError(
        'decrypt: header direction byte ${header.directionByte} does '
        'not match the expected receiver tag $expectedTag',
      );
    }

    var chainKey = _recvChainKey;
    var counter = _recvCounter;
    while (counter < header.msgIndex) {
      chainKey = await _hmacChainStep(chainKey, _chainKeySeed);
      counter++;
    }

    final msgKey = await _deriveMessageKey(
      chainKey: chainKey,
      directionByte: header.directionByte,
      msgIndex: header.msgIndex,
    );
    final aesKey = msgKey.sublist(0, 32);

    final ct = Uint8List.fromList(ciphertext);
    if (ct.length < 16) {
      throw ArgumentError('ciphertext too short to contain GCM tag');
    }
    final body = ct.sublist(0, ct.length - 16);
    final mac = ct.sublist(ct.length - 16);
    final box = SecretBox(
      body,
      nonce: _fixedNonce(header.directionByte, header.msgIndex),
      mac: Mac(mac),
    );
    final aad = utf8.encode('relaylink-direct-v1');
    final ptBytes = await _aesGcm.decrypt(box, secretKey: SecretKey(aesKey), aad: aad);

    final advancedChainKey = await _hmacChainStep(chainKey, _chainKeySeed);
    _recvChainKey = advancedChainKey;
    _recvCounter = header.msgIndex + 1;
    return utf8.decode(ptBytes);
  }

  static Future<Uint8List> _deriveRoot(List<int> secret, int directionByte) async {
    final derived = await _hkdf32.deriveKey(
      secretKey: SecretKey(secret),
      info: Uint8List.fromList([directionByte]),
    );
    return Uint8List.fromList(derived.bytes);
  }

  /// Explicit synonym for [create]. Surfaces to callers that this is
  /// the LEGACY HKDF-chain fallback rather than the modern Double
  /// Ratchet (which lives in
  /// `package:relaylink/crypto/double_ratchet.dart`).
  static Future<DirectSession> legacy(
    List<int> sharedSecret, {
    required bool isInitiator,
  }) =>
      create(sharedSecret, isInitiator: isInitiator);
}
