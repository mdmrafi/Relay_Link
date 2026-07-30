// RelayLink — Persistent store for `DirectSession` instances.
//
// `DirectSession` (Ticket #13, HKDF-chain fallback) is the symmetric
// per-peer crypto state that feeds the DIRECT message path. Once a
// session is established (via `ContactInvite` bootstrap), the chain
// keys must persist across app restarts — otherwise the user would
// silently lose all DIRECT message history (and any future messages
// the peer sends would fail to decrypt).
//
// Backing store: `flutter_secure_storage` (Android Keystore / iOS
// Keychain) so the chain keys are encrypted at rest. The local SQLite
// database is plaintext and explicitly NOT used for crypto material.
//
// Key namespace: `relaylink.direct_sessions.<deviceId_hex>`. The device
// id is the same 16-hex `senderId` used everywhere else in the app.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'direct.dart';

/// Secure-storage key prefix for persisted DIRECT sessions.
const String kDirectSessionStorePrefix = 'relaylink.direct_sessions.';

/// Persistent store for `DirectSession` instances, keyed by the remote
/// device's 16-hex `senderId`. Backed by `flutter_secure_storage` so the
/// chain keys are encrypted at rest.
class DirectSessionStore {
  /// Construct over a caller-provided [storage]. Tests use the default
  /// `FlutterSecureStorage()` after calling `setMockInitialValues`;
  /// production code uses [DirectSessionStore.instance].
  DirectSessionStore(this._storage);

  final FlutterSecureStorage _storage;

  static DirectSessionStore? _singleton;

  /// Singleton used by app code. Lazy — first call wins.
  static DirectSessionStore instance() {
    final s = _singleton;
    if (s != null) return s;
    final created = DirectSessionStore(const FlutterSecureStorage(
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    ));
    _singleton = created;
    return created;
  }

  /// Reset the singleton — only useful in tests.
  static void resetForTesting() {
    _singleton = null;
  }

  String _storageKey(String deviceId) =>
      '$kDirectSessionStorePrefix$deviceId';

  /// Read the persisted session for [deviceId], or `null` if no pair
  /// exists. Returns `null` for an empty/blank deviceId (the caller
  /// almost certainly forgot to wire it).
  Future<DirectSession?> get(String deviceId) async {
    if (deviceId.isEmpty) return null;
    final raw = await _storage.read(key: _storageKey(deviceId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'DirectSessionStore: persisted value is not a JSON object',
        );
      }
      return DirectSession.fromJson(decoded);
    } on FormatException {
      // Re-throw so a corrupt entry is not silently dropped.
      rethrow;
    }
  }

  /// Persist [session] for [deviceId]. The session is JSON-encoded and
  /// written to secure storage. Overwrites any existing entry.
  Future<void> put(String deviceId, DirectSession session) async {
    if (deviceId.isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must be non-empty');
    }
    await _storage.write(
      key: _storageKey(deviceId),
      value: jsonEncode(session.toJson()),
    );
    _notify(deviceId);
  }

  /// Remove the persisted session for [deviceId]. Returns `true` if an
  /// entry was removed, `false` otherwise.
  Future<bool> delete(String deviceId) async {
    if (deviceId.isEmpty) return false;
    final existing = await _storage.read(key: _storageKey(deviceId));
    if (existing == null) return false;
    await _storage.delete(key: _storageKey(deviceId));
    _notify(deviceId);
    return true;
  }

  /// All device ids that currently have a persisted session. Walked
  /// lazily — used by the Settings screen to render "Active direct chats".
  Future<List<String>> listDeviceIds() async {
    final all = await _storage.readAll();
    final prefix = kDirectSessionStorePrefix;
    return all.keys
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Stream of put/delete notifications
  // ---------------------------------------------------------------------------

  final StreamController<String> _controller =
      StreamController<String>.broadcast();

  /// Broadcasts the deviceId of any session that was just put or deleted.
  /// Useful for UI consumers that want to react to pairing changes.
  Stream<String> get deviceIds => _controller.stream;

  void _notify(String deviceId) {
    if (!_controller.isClosed) _controller.add(deviceId);
  }

  /// Close the underlying broadcast stream. Mostly for tests.
  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}
