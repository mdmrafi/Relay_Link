// RelayLink — Ticket #05 secrets store.
//
// Thin wrapper around `flutter_secure_storage`. We deliberately do NOT
// extend the platform interface itself so tests can call
// `FlutterSecureStorage.setMockInitialValues({...})` and pass a plain
// `FlutterSecureStorage()` here.
//
// Two layers of API:
//   * Typed convenience:   `getIdentity()`, `setIdentity(IdentityBundle)`
//     — wraps the four keys (ed25519 priv/pub, x25519 priv/pub) as a
//     single JSON blob. Used by #02.
//   * Generic kv:          `getSecret(key)`, `setSecret(key, value)`
//     — used by #15 (per-channel symmetric keys), and any future
//     ticket that needs a small non-SQLite secret.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Identity bundle stored in flutter_secure_storage.
///
/// All four fields are base64-encoded raw key bytes — produced by
/// `package:cryptography` (Ed25519 / X25519) and consumed by #13 (DIRECT
/// crypto / ratchet) and #03 (broadcast crypto).
class IdentityBundle {
  final String ed25519PrivateKeyB64;
  final String ed25519PublicKeyB64;
  final String x25519PrivateKeyB64;
  final String x25519PublicKeyB64;

  const IdentityBundle({
    required this.ed25519PrivateKeyB64,
    required this.ed25519PublicKeyB64,
    required this.x25519PrivateKeyB64,
    required this.x25519PublicKeyB64,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ed25519_priv': ed25519PrivateKeyB64,
        'ed25519_pub': ed25519PublicKeyB64,
        'x25519_priv': x25519PrivateKeyB64,
        'x25519_pub': x25519PublicKeyB64,
      };

  static IdentityBundle fromJson(Map<String, dynamic> json) {
    String req(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('IdentityBundle.$key is required');
      }
      return v;
    }

    return IdentityBundle(
      ed25519PrivateKeyB64: req('ed25519_priv'),
      ed25519PublicKeyB64: req('ed25519_pub'),
      x25519PrivateKeyB64: req('x25519_priv'),
      x25519PublicKeyB64: req('x25519_pub'),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is IdentityBundle &&
        other.ed25519PrivateKeyB64 == ed25519PrivateKeyB64 &&
        other.ed25519PublicKeyB64 == ed25519PublicKeyB64 &&
        other.x25519PrivateKeyB64 == x25519PrivateKeyB64 &&
        other.x25519PublicKeyB64 == x25519PublicKeyB64;
  }

  @override
  int get hashCode => Object.hash(
        ed25519PrivateKeyB64,
        ed25519PublicKeyB64,
        x25519PrivateKeyB64,
        x25519PublicKeyB64,
      );

  @override
  String toString() =>
      'IdentityBundle(ed25519_pub=$ed25519PublicKeyB64, '
      'x25519_pub=$x25519PublicKeyB64)';
}

/// Secure secrets backed by the platform keychain (iOS Keychain,
/// Android EncryptedSharedPreferences, macOS Keychain, etc.).
///
/// Injected [storage] allows tests to plug in a `FlutterSecureStorage`
/// with `setMockInitialValues({...})` — see test/storage/secrets_store_test.dart.
class SecretsStore {
  /// Stable key under which the identity bundle is persisted.
  static const String identityBundleKey = 'identity_bundle';

  final FlutterSecureStorage _storage;

  /// Construct a [SecretsStore] over a caller-provided [FlutterSecureStorage].
  /// Tests inject a mock storage; production code uses [SecretsStore.instance]
  /// which builds the platform default.
  SecretsStore.withStorage(this._storage);

  /// Singleton accessor for app code — uses `defaultOptions`.
  static SecretsStore? _singleton;
  static Future<SecretsStore> instance() async {
    final s = _singleton;
    if (s != null) return s;
    final created = SecretsStore.withStorage(
      const FlutterSecureStorage(
        iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
      ),
    );
    _singleton = created;
    return created;
  }

  /// Reset the singleton — only useful in tests.
  static void resetForTesting() {
    _singleton = null;
  }

  // ---------------------------------------------------------------------------
  // Generic kv
  // ---------------------------------------------------------------------------

  /// Read a string-valued secret. Returns `null` if absent.
  Future<String?> getSecret(String key) => _storage.read(key: key);

  /// Write a string-valued secret. Passing `null` deletes the entry.
  Future<void> setSecret(String key, String? value) async {
    if (value == null) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: value);
    }
  }

  /// Delete a secret. No-op if the key isn't present.
  Future<void> deleteSecret(String key) => _storage.delete(key: key);

  // ---------------------------------------------------------------------------
  // Typed: IdentityBundle
  // ---------------------------------------------------------------------------

  /// Read the identity bundle, or `null` if the device has not generated
  /// keys yet.
  Future<IdentityBundle?> getIdentity() async {
    final raw = await getSecret(identityBundleKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Identity bundle must be a JSON object',
      );
    }
    return IdentityBundle.fromJson(decoded);
  }

  /// Persist the identity bundle. Subsequent calls overwrite.
  Future<void> setIdentity(IdentityBundle bundle) async {
    await setSecret(identityBundleKey, jsonEncode(bundle.toJson()));
  }

  /// Erase the identity bundle (used on full sign-out / key rotation).
  Future<void> deleteIdentity() => deleteSecret(identityBundleKey);
}