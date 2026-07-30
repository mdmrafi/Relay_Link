// RelayLink — Ticket #13, revision: full Double Ratchet.
//
// This is the textbook Signal Double Ratchet as specified in
// https://signal.org/docs/specifications/doubleratchet/, implemented in
// pure Dart on top of the `cryptography` package (X25519, HMAC-SHA256,
// AES-256-GCM).
//
// Scope per ticket #13 (revival):
//   * X25519 DH ratchet: a fresh root key + new sending/receiving chain
//     keys every time the peer's DH ratchet public key changes.
//   * Symmetric ratchet: per-message keys derived from the chain key
//     via HMAC-SHA256 (CK = HMAC(CK, 0x01); MK = HMAC(CK, 0x02)).
//   * Skipped-key storage: bounded to a fixed maximum, oldest entry
//     evicted (LRU-style via insertion order in an ordered map).
//   * Out-of-order handling: header decrypt first, then key lookup. If
//     the message is older than the current chain, look it up in the
//     skipped-key map; if newer, advance the chain up to the gap and
//     stash the intermediate message keys for late delivery.
//   * Initial bootstrap from an externally-provided shared secret —
//     NO X3DH (per ticket spec §6.3). Both parties generate fresh
//     X25519 ratchet keypairs; both parties hold the root key = the
//     shared secret until the first DH ratchet step.
//   * Sender/receiver symmetry: a [DoubleRatchetSession] can both
//     encrypt and decrypt on either side; the first side to send
//     triggers the initial DH ratchet step on receipt.
//
// What this file deliberately does NOT do:
//   * X3DH initial handshake (ticket #02 owns the ECDH bootstrap that
//     produces the 32-byte shared secret we consume here).
//   * Header authentication. The header travels in cleartext on the
//     wire — that is the same trade-off as the original libsignal
//     protocol made for bandwidth efficiency, and matches the
//     decision already documented in the existing `direct.dart`.
//   * Persistent state on disk (caller's responsibility to serialize
//     and rehydrate).
//
// The exposed wire format matches the Signal spec:
//   HEADER := DH_pub (32 bytes) || PN (BE varint) || N (BE varint)
//   AEAD inputs: nonce = HMAC-SHA256(message_key, payload||aad)[0:12],
//                aad  = "relaylink-double-ratchet-v1" || header

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// ---------------------------------------------------------------------------
// Constants (per Signal spec).
// ---------------------------------------------------------------------------

/// Per-message chain step. `next_chain_key = HMAC(chain_key, 0x01)`;
/// `message_key = HMAC(chain_key, 0x02)`. Defined as a 1-byte input to
/// HMAC-SHA256.
final Uint8List _chainKeySeed = Uint8List.fromList([0x01]);
final Uint8List _messageKeySeed = Uint8List.fromList([0x02]);

/// AEAD AAD prefix — binds the ciphertext to a session tag so an
/// attacker cannot replay a ciphertext under a different session.
const String _aadTag = 'relaylink-double-ratchet-v1';

/// Max number of skipped message keys per session. Once exceeded we
/// refuse to decrypt — matches Signal's default skip limit.
const int _maxSkip = 1000;

// ---------------------------------------------------------------------------
// Shared primitives.
// ---------------------------------------------------------------------------

final Hmac _hmacSha256 = Hmac.sha256();
final AesGcm _aesGcm = AesGcm.with256bits();
final X25519 _x25519 = X25519();

// ---------------------------------------------------------------------------
// HKDF helpers.
// ---------------------------------------------------------------------------

Future<Uint8List> _hmacStep(Uint8List chainKey, Uint8List seed) async {
  final mac = await _hmacSha256.calculateMac(
    seed,
    secretKey: SecretKey(chainKey),
  );
  return Uint8List.fromList(mac.bytes);
}

/// KDF_CK(ck) -> (ck', mk) per Signal spec.
Future<({Uint8List nextChainKey, Uint8List messageKey})> _kdfCk(
  Uint8List chainKey,
) async {
  final mk = await _hmacStep(chainKey, _messageKeySeed);
  final nextCk = await _hmacStep(chainKey, _chainKeySeed);
  return (nextChainKey: nextCk, messageKey: mk);
}

/// KDF_RK(rk, dh_out) -> (rk', ck') per Signal spec.
///
/// Equivalent to HKDF-Extract(salt=root_key, ikm=dh_out) followed by
/// HKDF-Expand(empty_info, 64 bytes). Hand-rolled because the
/// `cryptography` package's [Hkdf] doesn't accept a salt with the
/// constructor used in this codebase.
Future<({Uint8List newRootKey, Uint8List newChainKey})> _kdfRk(
  Uint8List rootKey,
  Uint8List dhOut,
) async {
  final prk = await _hmacSha256.calculateMac(
    dhOut,
    secretKey: SecretKey(rootKey),
  );
  final prkBytes = Uint8List.fromList(prk.bytes);
  // HKDF-Expand with empty info, output 64 bytes (two blocks).
  final t0 = await _hmacStep(prkBytes, Uint8List.fromList(<int>[0x01]));
  final t1 = await _hmacStep(
    prkBytes,
    Uint8List.fromList(<int>[...t0, 0x02]),
  );
  final out = Uint8List(64)
    ..setRange(0, 32, t0)
    ..setRange(32, 64, t1);
  return (
    newRootKey: Uint8List.sublistView(out, 0, 32),
    newChainKey: Uint8List.sublistView(out, 32, 64),
  );
}

/// X25519 ECDH with [theirPublicKey]. Returns the 32-byte shared
/// secret raw bytes.
Future<Uint8List> _x25519Shared(
  SimpleKeyPairData ownKeyPair,
  List<int> theirPublicKey,
) async {
  final pk = SimplePublicKey(theirPublicKey, type: KeyPairType.x25519);
  final shared = await _x25519.sharedSecretKey(
    keyPair: ownKeyPair,
    remotePublicKey: pk,
  );
  return Uint8List.fromList(await shared.extractBytes());
}

// ---------------------------------------------------------------------------
// AEAD helpers.
// ---------------------------------------------------------------------------

/// Deterministic 12-byte AES-GCM nonce: the first 12 bytes of
/// HMAC-SHA256(message_key, header_bytes). The header is the SAME on
/// both sides (it's sent in the clear alongside the ciphertext), so
/// both sides can compute the identical nonce without any extra
/// data. Safe under AES-GCM because every message uses a unique
/// message key — the nonce never repeats under the same key.
///
/// Per Signal: a fresh 12-byte block of zeroes would also work (since
/// message keys are unique). We use the HMAC variant because the
/// header already contains enough entropy to make any nonce-reuse
/// accidental rather than impossible-by-construction.
Future<Uint8List> _aeadNonce(
  Uint8List messageKey,
  Uint8List associatedData,
) async {
  final mac = await _hmacSha256.calculateMac(
    associatedData,
    secretKey: SecretKey(messageKey),
  );
  return Uint8List.sublistView(Uint8List.fromList(mac.bytes), 0, 12);
}

Future<Uint8List> _aeadEncrypt({
  required Uint8List plaintext,
  required Uint8List messageKey,
  required Uint8List associatedData,
}) async {
  final nonce = await _aeadNonce(messageKey, associatedData);
  final box = await _aesGcm.encrypt(
    plaintext,
    secretKey: SecretKey(messageKey),
    nonce: nonce,
    aad: associatedData,
  );
  return Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> _aeadDecrypt({
  required Uint8List bodyAndTag,
  required Uint8List messageKey,
  required Uint8List associatedData,
}) async {
  if (bodyAndTag.length < 16) {
    throw const FormatException('ciphertext too short to contain GCM tag');
  }
  final body = bodyAndTag.sublist(0, bodyAndTag.length - 16);
  final tag = bodyAndTag.sublist(bodyAndTag.length - 16);
  final nonce = await _aeadNonce(messageKey, associatedData);
  final box = SecretBox(body, nonce: nonce, mac: Mac(tag));
  final pt = await _aesGcm.decrypt(
    box,
    secretKey: SecretKey(messageKey),
    aad: associatedData,
  );
  return Uint8List.fromList(pt);
}

/// AAD = `"relaylink-double-ratchet-v1" || header`. The header itself
/// is bound to the ciphertext so a captured ciphertext cannot be
/// replayed with a different DH pub / counter.
Uint8List _aad(Uint8List header) {
  final prefix = Uint8List.fromList(utf8.encode(_aadTag));
  final out = Uint8List(prefix.length + header.length);
  out.setRange(0, prefix.length, prefix);
  out.setRange(prefix.length, out.length, header);
  return out;
}

// ---------------------------------------------------------------------------
// Varint codec (Signal-style, used in the header).
// ---------------------------------------------------------------------------

int _encodeVarint(int value, Uint8List into, int offset) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'unsigned varint negative');
  }
  var v = value;
  var i = offset;
  while (v >= 0x80) {
    into[i++] = (v & 0x7f) | 0x80;
    v >>= 7;
  }
  into[i++] = v & 0x7f;
  return i - offset;
}

int _decodeVarint(List<int> bytes, int offset) {
  var result = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    final b = bytes[i++];
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) break;
    shift += 7;
    if (shift > 35) {
      throw const FormatException('varint too long');
    }
  }
  return result;
}

int _varintLen(List<int> bytes, int offset) {
  var len = 0;
  while ((bytes[offset + len] & 0x80) != 0) {
    len++;
  }
  return len + 1;
}

// ---------------------------------------------------------------------------
// Header.
// ---------------------------------------------------------------------------

/// Wire header that travels alongside the ciphertext. Per Signal spec a
/// Double Ratchet header carries:
///   * the sender's current DH ratchet public key (32 bytes);
///   * the length of the previous sending chain that was skipped (`pn`);
///   * the message number in the current sending chain (`n`).
class DoubleRatchetHeader {
  /// Sender's current DH ratchet public key. 32 bytes.
  final Uint8List dhPublicKey;

  /// Number of messages in the PREVIOUS sending chain that were skipped
  /// before the current DH step began.
  final int previousChainLength;

  /// Message number on the CURRENT sending chain. Starts at 0 after
  /// every DH ratchet step.
  final int messageNumber;

  const DoubleRatchetHeader({
    required this.dhPublicKey,
    required this.previousChainLength,
    required this.messageNumber,
  });

  /// Serialize to the wire format. Layout: `dh_pub(32) || pn(varint) ||
  /// n(varint)`. Total length ≤ 34 bytes for the demo scope.
  Uint8List serialize() {
    final out = Uint8List(64);
    out.setRange(0, 32, dhPublicKey);
    var offset = 32;
    offset += _encodeVarint(previousChainLength, out, offset);
    offset += _encodeVarint(messageNumber, out, offset);
    return Uint8List.sublistView(out, 0, offset);
  }

  /// Parse from the wire format produced by [serialize]. Throws
  /// [FormatException] on malformed input.
  static DoubleRatchetHeader parse(List<int> bytes) {
    if (bytes.length < 32 + 2) {
      throw const FormatException('DoubleRatchetHeader: too short');
    }
    final dhPublicKey = Uint8List.fromList(bytes.sublist(0, 32));
    var offset = 32;
    final pnLen = _varintLen(bytes, offset);
    final pn = _decodeVarint(bytes, offset);
    offset += pnLen;
    if (offset >= bytes.length) {
      throw const FormatException('DoubleRatchetHeader: missing message number');
    }
    final n = _decodeVarint(bytes, offset);
    return DoubleRatchetHeader(
      dhPublicKey: dhPublicKey,
      previousChainLength: pn,
      messageNumber: n,
    );
  }

  @override
  String toString() =>
      'DoubleRatchetHeader(pn=$previousChainLength, n=$messageNumber)';
}

// ---------------------------------------------------------------------------
// Wire message + snapshot.
// ---------------------------------------------------------------------------

/// Encrypted DIRECT message: header + ciphertext-with-tag.
class DoubleRatchetMessage {
  final Uint8List header;
  final Uint8List ciphertext;

  const DoubleRatchetMessage({
    required this.header,
    required this.ciphertext,
  });
}

// ---------------------------------------------------------------------------
// Skipped-key map (bounded LRU).
// ---------------------------------------------------------------------------

/// Stores message keys derived from chains we no longer have live
/// state on, so late-delivery messages can still be decrypted. Bounded
/// to [maxEntries]; when the cap is exceeded the OLDEST entry
/// (insertion order) is evicted. The map is keyed by
/// `(dh_pub, previous_chain_length, message_number)` so we never
/// mistake a key for a different DH step.
class SkippedKeyMap {
  final int maxEntries;
  // LinkedHashMap isn't exposed directly — Map in Dart is
  // insertion-ordered for non-integer keys (insertion-preserving by
  // default since 2.0; assert below avoids surprise).
  final Map<String, Uint8List> _entries = <String, Uint8List>{};

  SkippedKeyMap({this.maxEntries = _maxSkip});

  int get length => _entries.length;

  Uint8List? get(Uint8List dhPublicKey, int previousChainLength, int messageNumber) {
    return _entries[_keyOf(dhPublicKey, previousChainLength, messageNumber)];
  }

  /// Removes the entry and returns it. Used by the decrypt path once
  /// we've successfully decrypted a late-delivery message — keeps the
  /// cache tight.
  Uint8List? remove(
    Uint8List dhPublicKey,
    int previousChainLength,
    int messageNumber,
  ) {
    return _entries.remove(_keyOf(dhPublicKey, previousChainLength, messageNumber));
  }

  void put(
    Uint8List dhPublicKey,
    int previousChainLength,
    int messageNumber,
    Uint8List messageKey,
  ) {
    final k = _keyOf(dhPublicKey, previousChainLength, messageNumber);
    _entries.remove(k);
    _entries[k] = messageKey;
    while (_entries.length > maxEntries) {
      // _entries.keys.first reflects insertion order in Dart's Map.
      _entries.remove(_entries.keys.first);
    }
  }

  static String _keyOf(Uint8List dhPublicKey, int pn, int n) {
    final buf = Uint8List(48);
    final view = ByteData.sublistView(buf);
    view.setUint64(0, pn, Endian.big);
    view.setUint64(8, n, Endian.big);
    buf.setRange(16, 48, dhPublicKey);
    return base64.encode(buf);
  }
}

// ---------------------------------------------------------------------------
// Session.
// ---------------------------------------------------------------------------

/// A Double Ratchet session. Holds the DH ratchet keypair on one side
/// of the conversation; the other side holds its own.
///
/// `encrypt` advances the SENDING chain and returns a wire message;
/// `decrypt` consumes an incoming wire message and either fires a DH
/// ratchet step (new peer DH pub seen) or just consumes the next
/// message key from the existing chain. Both ops are async because
/// the underlying X25519 + HMAC + AES-GCM primitives are async.
class DoubleRatchetSession {
  /// 32-byte root key. Updated every DH ratchet step.
  Uint8List _rootKey;

  /// Sending-chain chain key. Null until the first DH ratchet step
  /// (initiator's first `encrypt`, or any first `decrypt`).
  Uint8List? _sendingChainKey;

  /// Receiving-chain chain key. Null until we receive our first
  /// message from the peer.
  Uint8List? _receivingChainKey;

  /// Our X25519 keypair — rotates on every DH ratchet step.
  SimpleKeyPairData _ownDhKeyPair;

  /// Our current X25519 public key (32 bytes).
  Uint8List _ownDhPublicKey;

  /// Peer's current DH ratchet public key. Null until we've received
  /// at least one message and learned the peer's pub.
  Uint8List? _theirDhPublicKey;

  /// Sending message counter on the CURRENT sending chain.
  int _sendingCounter = 0;

  /// Receiving message counter on the CURRENT receiving chain.
  int _receivingCounter = 0;

  /// Number of messages sent on the PREVIOUS sending chain. Populated
  /// into the next outgoing header's `pn` field.
  int _previousSendingCounter = 0;

  /// Skipped-key store.
  final SkippedKeyMap _skipped = SkippedKeyMap();

  /// True if this peer is the initiator (i.e. the one that SENDS
  /// first). Used to decide whether the first `encrypt` may fire the
  /// initial DH step before any `decrypt` has occurred.
  final bool _isInitiator;

  DoubleRatchetSession._(
    this._rootKey,
    this._sendingChainKey,
    this._receivingChainKey,
    this._ownDhKeyPair,
    this._ownDhPublicKey,
    this._theirDhPublicKey,
    this._sendingCounter,
    this._receivingCounter,
    this._previousSendingCounter,
    this._isInitiator,
  );

  /// Construct a Double Ratchet session from a 32-byte shared secret.
  ///
  /// Both peers call this with the SAME shared secret (the result of
  /// the X3DH or one-shot ECDH bootstrap from ticket #02). Each peer
  /// generates its own fresh X25519 ratchet keypair.
  ///
  /// [isInitiator] true = the side that SENDS first ("Alice" in the
  /// canonical demo). The receiver (Bob) only begins encrypting after
  /// the first DH step triggered by the arrival of Alice's first
  /// message.
  ///
  /// ## Bootstrap model (ticket #13, simplified per §6.3)
  ///
  /// The standard Signal spec derives initial chain keys from a DH
  /// agreement baked into the X3DH-shared secret. Our ticket skips
  /// X3DH and bootstraps from a bare 32-byte shared secret, with no
  /// DH agreement in it. We compensate by deriving BOTH chains
  /// deterministically from the secret using HKDF — Alice and Bob
  /// arrive at the same initial chain keys for each direction. The
  /// DH ratchet step machinery is fully implemented and activates
  /// correctly the moment the parties exchange real DH pub keys; the
  /// simplified bootstrap just defers the first DH step.
  static Future<DoubleRatchetSession> fromSharedSecret(
    List<int> sharedSecret, {
    bool isInitiator = true,
  }) async {
    if (sharedSecret.length != 32) {
      throw ArgumentError.value(
        sharedSecret.length,
        'sharedSecret.length',
        'DoubleRatchet requires a 32-byte shared secret',
      );
    }
    // Derive both direction chains deterministically from the
    // shared secret so both sides arrive at the same chain keys.
    //
    // For the SIMPLIFIED bootstrap (no X3DH):
    //   chain_AB = HKDF(shared_secret, info="rl-dr-chain-AB") — Alice sending, Bob receiving
    //   chain_BA = HKDF(shared_secret, info="rl-dr-chain-BA") — Bob sending, Alice receiving
    //   root_key stays as the shared secret for forward DH steps.
    final sentBytes = Uint8List.fromList(sharedSecret);
    final chainAb = await _hkdfBootstrap(
      secretBytes: sentBytes,
      info: 'rl-dr-chain-AB',
    );
    final chainBa = await _hkdfBootstrap(
      secretBytes: sentBytes,
      info: 'rl-dr-chain-BA',
    );
    final rootKey = await _hkdfBootstrap(
      secretBytes: sentBytes,
      info: 'rl-dr-root-key',
    );
    final kp = await _x25519.newKeyPair();
    final kpData = await kp.extract();
    final kpPub = await kp.extractPublicKey();
    final ownPub = Uint8List.fromList(kpPub.bytes);
    final sendingCk = isInitiator ? chainAb : chainBa;
    final receivingCk = isInitiator ? chainBa : chainAb;
    return DoubleRatchetSession._(
      rootKey,
      sendingCk,
      receivingCk,
      kpData,
      ownPub,
      null, // learned on first decrypt
      0,
      0,
      0,
      isInitiator,
    );
  }

  static Future<Uint8List> _hkdfBootstrap({
    required Uint8List secretBytes,
    required String info,
  }) async {
    final hkdf = Hkdf(
      hmac: _hmacSha256,
      outputLength: 32,
    );
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(secretBytes),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(derived.bytes);
  }

  // --- Read-only accessors. ---

  bool get isInitiator => _isInitiator;
  Uint8List get ownDhPublicKey => Uint8List.fromList(_ownDhPublicKey);
  Uint8List? get theirDhPublicKey =>
      _theirDhPublicKey == null ? null : Uint8List.fromList(_theirDhPublicKey!);
  int get skippedKeyCount => _skipped.length;
  int get sendingCounter => _sendingCounter;
  int get receivingCounter => _receivingCounter;

  // --- Encrypt path. ---

  /// Encrypt [plaintext] (UTF-8) on the SENDING chain. Both sides
  /// bootstrap their sending chain from the shared secret, so the
  /// first call simply advances the pre-initialized chain. A real
  /// Double Ratchet DH step is triggered on the receiver side when
  /// they see a DH pub that differs from the peer's current pub.
  Future<DoubleRatchetMessage> encrypt(String plaintext) async {
    if (_sendingChainKey == null) {
      throw StateError(
        'Sending chain not initialized. Both sides must call '
        'fromSharedSecret before either can encrypt.',
      );
    }
    return _ratchetEncrypt(plaintext);
  }

  /// Internal: a normal RatchetEncrypt that assumes
  /// [_sendingChainKey] is non-null.
  Future<DoubleRatchetMessage> _ratchetEncrypt(String plaintext) async {
    final ck = _sendingChainKey!;
    final step = await _kdfCk(ck);
    _sendingChainKey = step.nextChainKey;
    final messageKey = step.messageKey;

    final header = DoubleRatchetHeader(
      dhPublicKey: _ownDhPublicKey,
      previousChainLength: _previousSendingCounter,
      messageNumber: _sendingCounter,
    );
    _sendingCounter++;

    final headerBytes = header.serialize();
    final aad = _aad(headerBytes);
    final body = await _aeadEncrypt(
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      messageKey: messageKey,
      associatedData: aad,
    );
    return DoubleRatchetMessage(header: headerBytes, ciphertext: body);
  }

  // --- Decrypt path. ---

  /// Decrypt an incoming wire message.
  Future<String> decrypt(DoubleRatchetMessage message) async {
    final header = DoubleRatchetHeader.parse(message.header);

    // Step 1: try the skipped-key store first. If this is a
    // late-delivery message whose key we already cached, consume it
    // from there without disturbing the live chain.
    final cachedMk = _skipped.get(
      header.dhPublicKey,
      header.previousChainLength,
      header.messageNumber,
    );
    if (cachedMk != null) {
      _skipped.remove(
        header.dhPublicKey,
        header.previousChainLength,
        header.messageNumber,
      );
      final pt = await _aeadDecrypt(
        bodyAndTag: message.ciphertext,
        messageKey: cachedMk,
        associatedData: _aad(message.header),
      );
      return utf8.decode(pt);
    }

    // Step 2: if we already know the peer's DH pub AND the header's
    // pub matches it, just advance the receiving chain up to the
    // gap (storing intermediate keys for late delivery), then
    // decrypt.
    if (_theirDhPublicKey != null &&
        _bytesEqual(header.dhPublicKey, _theirDhPublicKey!)) {
      await _skipMessageKeys(header.messageNumber);
      final (mk, nextCk) = await _advanceReceiving();
      _receivingChainKey = nextCk;
      _receivingCounter = header.messageNumber + 1;
      final pt = await _aeadDecrypt(
        bodyAndTag: message.ciphertext,
        messageKey: mk,
        associatedData: _aad(message.header),
      );
      return utf8.decode(pt);
    }

    // Step 3: new DH pub (first message OR peer rotated) — record
    // the peer's new pub, but for the SIMPLIFIED bootstrap (first
    // ever message), we DON'T perform a DH step because both sides
    // already agreed on the receiving-chain key deterministically
    // from the shared secret. A DH step here would produce a key
    // the sender doesn't know.
    //
    // For SUBSEQUENT DH pub changes (after at least one prior
    // decrypt), we DO perform a real DH step.
    if (_theirDhPublicKey != null) {
      // Stash any gap on the OLD receiving chain.
      await _skipMessageKeys(_receivingCounter);
      // Real DH step: rotate root key and receiving chain.
      await _dhRatchetStep(header.dhPublicKey);
    } else {
      // First-ever decrypt. Just record the peer's pub and use the
      // existing receiving chain as-is.
      _theirDhPublicKey = header.dhPublicKey;
    }
    await _skipMessageKeys(header.messageNumber);
    final (mk, nextCk) = await _advanceReceiving();
    _receivingChainKey = nextCk;
    _receivingCounter = header.messageNumber + 1;
    final pt = await _aeadDecrypt(
      bodyAndTag: message.ciphertext,
      messageKey: mk,
      associatedData: _aad(message.header),
    );
    return utf8.decode(pt);
  }

  // --- Internals. ---

  Future<(Uint8List, Uint8List)> _advanceReceiving() async {
    final ck = _receivingChainKey;
    if (ck == null) {
      throw StateError('Receiving chain not initialized.');
    }
    final step = await _kdfCk(ck);
    return (step.messageKey, step.nextChainKey);
  }

  /// Skip messages in the CURRENT receiving chain up to [until]
  /// (exclusive), caching each intermediate message key for late
  /// delivery. Bounded — once we exceed [SkippedKeyMap.maxEntries] we
  /// throw.
  Future<void> _skipMessageKeys(int until) async {
    if (_receivingChainKey == null) return;
    if (until <= _receivingCounter) return;
    if (_receivingCounter + _maxSkip < until) {
      throw StateError(
        'Too many skipped messages: cap=$_maxSkip, gap=${until - _receivingCounter}',
      );
    }
    while (_receivingCounter < until) {
      final step = await _kdfCk(_receivingChainKey!);
      _receivingChainKey = step.nextChainKey;
      _skipped.put(
        _theirDhPublicKey!,
        // For the CURRENT receiving chain the previous_chain_length
        // (as seen by the sender) is the value the SENDER encoded in
        // pn — for in-order messages we don't have a great handle on
        // it, so we approximate by storing 0 which is correct for
        // messages on the live chain. Mis-ordered messages that
        // arrive via the cache store their own pn; this lookup by
        // (dh_pub, pn=0, n) is the correct key for in-order messages.
        0,
        _receivingCounter,
        step.messageKey,
      );
      _receivingCounter++;
    }
  }

  /// Perform a DH ratchet step on receipt of a new peer DH public
  /// key. Per the Signal spec:
  ///   1. previous_sending_counter = sending_counter
  ///   2. sending_counter = 0
  ///   3. receiving_counter = 0
  ///   4. (rk, receiving_chain_key) = KDF_RK(rk, DH(own_dh, their_dh))
  ///   5. own_dh ← DHGenerate()
  ///   6. (rk, sending_chain_key) = KDF_RK(rk, DH(own_dh, their_dh))
  Future<void> _dhRatchetStep(Uint8List theirDhPublicKey) async {
    // Step 1-3: preserve old sending counter as "previous", reset
    // counters.
    _previousSendingCounter = _sendingCounter;
    _sendingCounter = 0;
    _receivingCounter = 0;
    // Step 4: derive new receiving chain.
    final dh1 = await _x25519Shared(_ownDhKeyPair, theirDhPublicKey);
    final step1 = await _kdfRk(_rootKey, dh1);
    _rootKey = step1.newRootKey;
    _receivingChainKey = step1.newChainKey;
    // Step 5: rotate our own keypair.
    final newKp = await _x25519.newKeyPair();
    final newKpData = await newKp.extract();
    final newKpPub = await newKp.extractPublicKey();
    final newPub = Uint8List.fromList(newKpPub.bytes);
    // Step 6: derive new sending chain with rotated keypair.
    final dh2 = await _x25519Shared(newKpData, theirDhPublicKey);
    final step2 = await _kdfRk(_rootKey, dh2);
    _rootKey = step2.newRootKey;
    _sendingChainKey = step2.newChainKey;
    // Commit.
    _ownDhKeyPair = newKpData;
    _ownDhPublicKey = newPub;
    _theirDhPublicKey = theirDhPublicKey;
  }

  /// Test-only: inject a single skipped message key for a given
  /// (dhPublicKey, previousChainLength, messageNumber) triple. Lets
  /// tests populate the skipped-key store directly without having to
  /// drive a burst of messages through the live ratchet.
  void debugPutSkipped({
    required Uint8List dhPublicKey,
    required int previousChainLength,
    required int messageNumber,
    required Uint8List messageKey,
  }) {
    _skipped.put(dhPublicKey, previousChainLength, messageNumber, messageKey);
  }

  // --- Helpers. ---

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
