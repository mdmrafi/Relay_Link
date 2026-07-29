// RelayLink — Ticket #02 device identity.
//
// Persisted on-device Ed25519 (signing) and X25519 (DH) keypairs. Private keys
// are stored in platform secure storage (Android Keystore via
// flutter_secure_storage). Public keys are also stored for fast load without
// re-derivation, but they're public so this is just a convenience.
//
// Design notes:
// * Keys are generated lazily on first launch (`generate()`) and re-loaded on
//   subsequent launches (`load()`). `loadOrGenerate()` is the entry point used
//   by the rest of the app.
// * Raw key bytes live in memory as `SimpleKeyPairData`. The Dart wrapper type
//   does not need to be persisted — only the 32-byte seeds/private keys are.
// * `SenderId` is the first 16 hex chars of the Ed25519 public key. It is
//   short, deterministic, and pseudonymous — sufficient for routing and
//   deduplication without revealing the full public key on-air.
// * Storage layout: each of the four key blobs is a base64-encoded
//   UTF-8 string under a distinct secure-storage key. The ed25519 private key
//   is the canonical anchor for "identity exists" — if it's missing we
//   generate fresh keys.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure-storage keys. Public so test code and other modules can audit the
/// layout.
class DeviceIdentityKeys {
  DeviceIdentityKeys._();

  static const String ed25519Private = 'identity_ed25519_priv';
  static const String ed25519Public = 'identity_ed25519_pub';
  static const String x25519Private = 'identity_x25519_priv';
  static const String x25519Public = 'identity_x25519_pub';
}

/// Per-device long-term identity: an Ed25519 signing keypair and an X25519 DH
/// keypair. Created via [DeviceIdentity.generate] (first launch) or
/// [DeviceIdentity.load] (subsequent launches); the [DeviceIdentity.loadOrGenerate]
/// factory is the entry point the rest of the app should use.
class DeviceIdentity {
  /// Ed25519 signing keypair. Holds both the private key seed (32 bytes) and
  /// the derived public key.
  final SimpleKeyPairData _signingKey;

  /// X25519 DH keypair. Holds both the private key seed (32 bytes) and the
  /// derived public key.
  final SimpleKeyPairData _dhKey;

  DeviceIdentity._(this._signingKey, this._dhKey);

  /// 16-hex-character pseudonym derived from the Ed25519 public key.
  ///
  /// Short, deterministic, and resharing-safe (peers can de-duplicate a sender
  /// without learning the full public key on-air). 64 bits of entropy is
  /// plenty for "which local sender ID routed this message".
  String get senderId {
    final pubBytes = _signingKey.publicKey.bytes; // 32 bytes
    final hexStr = _bytesToHexLower(pubBytes); // 64 lowercase hex chars
    return hexStr.substring(0, 16);
  }

  /// Raw 32-byte Ed25519 public key (X25519 shares no curve with Ed25519
  /// here, so don't confuse the two).
  Uint8List get ed25519PublicKeyBytes =>
      Uint8List.fromList(_signingKey.publicKey.bytes);

  /// Raw 32-byte X25519 public key.
  Uint8List get x25519PublicKeyBytes =>
      Uint8List.fromList(_dhKey.publicKey.bytes);

  /// Generate a brand-new identity. Does NOT persist — call [save] or use
  /// [generate] to create-and-persist in one step.
  static Future<DeviceIdentity> generate() async {
    final ed = Ed25519();
    final x = X25519();
    final signing = await ed.newKeyPair();
    final dh = await x.newKeyPair();
    // The factory returns SimpleKeyPair (interface) — we always get back
    // SimpleKeyPairData for Ed25519/X25519, and we need its bytes to seed.
    final signingData = await signing.extract();
    final dhData = await dh.extract();
    final signingPub = await signing.extractPublicKey();
    final dhPub = await dh.extractPublicKey();
    return DeviceIdentity._(
      SimpleKeyPairData(
        signingData.bytes,
        publicKey: signingPub,
        type: KeyPairType.ed25519,
      ),
      SimpleKeyPairData(
        dhData.bytes,
        publicKey: dhPub,
        type: KeyPairType.x25519,
      ),
    );
  }

  /// Load an existing identity from secure storage. Throws [StateError] if no
  /// identity exists yet.
  static Future<DeviceIdentity> load({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    final edPrivB64 = await storage.read(key: DeviceIdentityKeys.ed25519Private);
    final xPrivB64 = await storage.read(key: DeviceIdentityKeys.x25519Private);
    if (edPrivB64 == null || xPrivB64 == null) {
      throw StateError(
        'No device identity found in secure storage. Call generate() first.',
      );
    }
    return _fromPrivateBytes(
      edPrivBytes: Uint8List.fromList(base64.decode(edPrivB64)),
      xPrivBytes: Uint8List.fromList(base64.decode(xPrivB64)),
    );
  }

  /// Load if present, otherwise generate + persist. Convenience entry point.
  static Future<DeviceIdentity> loadOrGenerate({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    final ed = await storage.read(key: DeviceIdentityKeys.ed25519Private);
    if (ed != null) {
      return load(storage: storage);
    }
    final fresh = await generate();
    await fresh.save(storage: storage);
    return fresh;
  }

  /// Persist this identity's private (and cached public) bytes to secure
  /// storage. Public keys are also written so the rest of the app can avoid
  /// re-deriving them, but they're not secrets.
  Future<void> save({FlutterSecureStorage storage = const FlutterSecureStorage()}) async {
    final edPriv = await _signingKey.extractPrivateKeyBytes();
    final xPriv = await _dhKey.extractPrivateKeyBytes();
    await storage.write(
      key: DeviceIdentityKeys.ed25519Private,
      value: base64.encode(edPriv),
    );
    await storage.write(
      key: DeviceIdentityKeys.x25519Private,
      value: base64.encode(xPriv),
    );
    await storage.write(
      key: DeviceIdentityKeys.ed25519Public,
      value: base64.encode(ed25519PublicKeyBytes),
    );
    await storage.write(
      key: DeviceIdentityKeys.x25519Public,
      value: base64.encode(x25519PublicKeyBytes),
    );
  }

  /// Sign [message] with the Ed25519 signing key. Returns 64 raw bytes.
  Future<Uint8List> sign(List<int> message) async {
    final ed = Ed25519();
    final sig = await ed.sign(message, keyPair: _signingKey);
    return Uint8List.fromList(sig.bytes);
  }

  /// Verify a signature. [signature] is the raw 64-byte Ed25519 signature.
  /// [publicKey] is the raw 32-byte Ed25519 public key (NOT base64).
  /// Returns false on any error (e.g. malformed signature); never throws.
  static Future<bool> verify(
    List<int> message, {
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    try {
      final ed = Ed25519();
      final pk = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
      final sig = Signature(signature, publicKey: pk);
      return await ed.verify(message, signature: sig);
    } catch (_) {
      return false;
    }
  }

  /// Compute a 32-byte X25519 shared secret with [theirPublicKey].
  /// [theirPublicKey] is the raw 32-byte X25519 public key of the peer.
  Future<Uint8List> ecdh(List<int> theirPublicKey) async {
    final x = X25519();
    final pk = SimplePublicKey(theirPublicKey, type: KeyPairType.x25519);
    final shared = await x.sharedSecretKey(
      keyPair: _dhKey,
      remotePublicKey: pk,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }

  /// Reconstruct keypairs from raw 32-byte private keys.
  static Future<DeviceIdentity> _fromPrivateBytes({
    required Uint8List edPrivBytes,
    required Uint8List xPrivBytes,
  }) async {
    final ed = Ed25519();
    final x = X25519();
    final signingK = await ed.newKeyPairFromSeed(edPrivBytes);
    final dhK = await x.newKeyPairFromSeed(xPrivBytes);
    final signingData = await signingK.extract();
    final dhData = await dhK.extract();
    return DeviceIdentity._(signingData, dhData);
  }
}

/// Lowercase hex encoder for short fixed-size byte buffers (32-byte public
/// keys). Pure-Dart, no external dependency.
String _bytesToHexLower(List<int> bytes) {
  const hexChars = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(hexChars[(b >> 4) & 0x0F]);
    out.write(hexChars[b & 0x0F]);
  }
  return out.toString();
}
