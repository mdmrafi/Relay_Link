// RelayLink — Ticket #15 channel key generation + storage.
//
// `ChannelKeyStore` owns the symmetric AES-256 keys for every channel the
// local device has joined. Each channel's 32-byte key is persisted in
// `flutter_secure_storage` under a stable key of the form `channel_<id>`,
// base64-encoded so the storage layer (which only takes UTF-8 strings) can
// round-trip the raw bytes verbatim.
//
// Threat model / design notes:
//   * The default `public` channel key is *embedded in source* (see
//     `lib/crypto/broadcast.dart`). It is auto-registered on first init so
//     every install can decrypt public traffic out of the box.
//   * Custom channels are generated with `Random.secure()` (cryptographically
//     secure) — `dart:math` plain `Random()` is explicitly avoided because
//     it is unsuitable for key material.
//   * Keys are NEVER written to sqflite. sqflite is for message history;
//     crypto material stays in the platform keychain (EncryptedSharedPreferences
//     on Android, Keychain on iOS/macOS).
//   * There is intentionally no `removeChannel` here yet — joining a channel
//     is a sticky operation in the protocol. If #16/#17 need a "leave" flow,
//     add it then with an explicit migration story.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/broadcast.dart';

/// Number of bytes in an AES-256 key. We validate this on add/get so a
/// caller cannot accidentally persist a truncated or padded key.
const int _kAesKeyBytes = 32;

/// Stable secure-storage key for the set of joined channel ids.
///
/// Persisted as a comma-separated string. The format is an implementation
/// detail; callers must always go through [listChannels].
const String _kChannelIndexKey = 'channels_index';

/// Prefix for per-channel key blobs. Combined with a channelId to form the
/// actual secure-storage key (`channel_<channelId>`). Kept distinct from the
/// identity key prefixes used in `DeviceIdentityKeys` so an audit can verify
/// there is no collision between identity storage and channel storage.
const String _kChannelKeyPrefix = 'channel_';

/// Owns per-channel AES-256 keys, backed by `flutter_secure_storage`.
///
/// Wire `ChannelKeyStore.instance()` from `main()` (after
/// `WidgetsFlutterBinding.ensureInitialized()`) to obtain a process-wide
/// singleton. Tests should construct their own with
/// `ChannelKeyStore.withStorage(...)` against a `FlutterSecureStorage` that
/// has had `FlutterSecureStorage.setMockInitialValues({...})` called.
class ChannelKeyStore {
  final FlutterSecureStorage _storage;

  /// Construct a [ChannelKeyStore] over a caller-provided [FlutterSecureStorage].
  /// Tests inject a mock storage; production code uses [ChannelKeyStore.instance].
  ChannelKeyStore.withStorage(this._storage);

  /// Singleton accessor for app code — uses the same default options as
  /// [SecretsStore.instance] so both stores hit the same keychain profile.
  static ChannelKeyStore? _singleton;

  /// Lazily create (or return) the singleton. Safe to call multiple times.
  static Future<ChannelKeyStore> instance() async {
    final s = _singleton;
    if (s != null) return s;
    // Open a fresh FlutterSecureStorage with the same default options as
    // `SecretsStore.instance()` (iOS first_unlock accessibility etc.). We
    // don't share SecretsStore's underlying instance because each
    // flutter_secure_storage instance has its own in-memory cache, and
    // coupling the two stores would make future refactors harder.
    final created = ChannelKeyStore.withStorage(
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
  // Bootstrap
  // ---------------------------------------------------------------------------

  /// Ensure the `public` channel key is registered.
  ///
  /// Idempotent: if `public` is already present (e.g. on a subsequent launch),
  /// this is a no-op. If a different `public` key has been written by a buggy
  /// older build, we overwrite it with the embedded default — the
  /// `networkKey` is the source of truth for the public channel.
  Future<void> init() async {
    final existing = await _storage.read(key: _publicStorageKey());
    if (existing == null) {
      await _storage.write(
        key: _publicStorageKey(),
        value: base64.encode(networkKey),
      );
    }
    // Make sure the index knows about public even if the index was somehow
    // cleared underneath us (e.g. a partial migration in a future build).
    final index = await _readIndex();
    if (!index.contains(kPublicChannelId)) {
      index.add(kPublicChannelId);
      await _writeIndex(index);
    }
  }

  // ---------------------------------------------------------------------------
  // Key generation
  // ---------------------------------------------------------------------------

  /// Return a fresh random 32-byte AES-256 key, suitable for handing to
  /// [addChannel] or sharing via a channel invite (#16).
  ///
  /// Backed by [math.Random.secure], which on every supported platform
  /// (Android, iOS, Linux, macOS, Windows) draws from the OS CSPRNG. We do
  /// NOT use plain `dart:math` `Random()` because it is a non-cryptographic
  /// PRNG and is unsafe for key material.
  List<int> generateKey() {
    final rng = math.Random.secure();
    final bytes = Uint8List(_kAesKeyBytes);
    for (var i = 0; i < _kAesKeyBytes; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  // ---------------------------------------------------------------------------
  // Channel registry
  // ---------------------------------------------------------------------------

  /// Persist [key] as the symmetric key for [channelId].
  ///
  /// [channelId] must be non-empty. [key] MUST be exactly 32 bytes — we fail
  /// loud rather than silently truncating or padding, because either bug
  /// would silently downgrade crypto strength.
  ///
  /// Replaces any existing key for [channelId].
  Future<void> addChannel(String channelId, List<int> key) async {
    if (channelId.isEmpty) {
      throw ArgumentError.value(channelId, 'channelId', 'must be non-empty');
    }
    if (channelId.contains('\n') || channelId.contains('\r')) {
      throw ArgumentError.value(
        channelId,
        'channelId',
        'must not contain newline characters (would corrupt the index)',
      );
    }
    if (key.length != _kAesKeyBytes) {
      throw ArgumentError.value(
        key,
        'key',
        'AES-256-GCM requires a 32-byte key, got ${key.length} bytes',
      );
    }
    await _storage.write(
      key: _storageKeyFor(channelId),
      value: base64.encode(key),
    );
    final index = await _readIndex();
    if (!index.contains(channelId)) {
      index.add(channelId);
      await _writeIndex(index);
    }
  }

  /// Return the 32-byte AES key for [channelId], or `null` if we have not
  /// joined that channel.
  ///
  /// Never throws on a missing channel — that's a recoverable condition
  /// (e.g. we just received an invite for a channel we don't know yet).
  /// Throws only on actual data corruption (wrong-length key).
  Future<List<int>?> getChannelKey(String channelId) async {
    final raw = await _storage.read(key: _storageKeyFor(channelId));
    if (raw == null || raw.isEmpty) return null;
    final decoded = base64.decode(raw);
    if (decoded.length != _kAesKeyBytes) {
      throw FormatException(
        'Persisted key for channel "$channelId" has wrong length: '
        '${decoded.length} bytes (expected $_kAesKeyBytes)',
      );
    }
    return Uint8List.fromList(decoded);
  }

  /// All channel ids the local device has joined, in insertion order.
  ///
  /// Always includes `public` once [init] has been called.
  Future<List<String>> listChannels() async => _readIndex();

  // ---------------------------------------------------------------------------
  // Index helpers
  // ---------------------------------------------------------------------------

  Future<List<String>> _readIndex() async {
    final raw = await _storage.read(key: _kChannelIndexKey);
    if (raw == null || raw.isEmpty) return <String>[];
    // Must be growable — callers ([addChannel], [init]) append to it.
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _writeIndex(List<String> ids) async {
    // Comma-joined; channelIds are validated by [addChannel] to not contain
    // newlines, so a comma split is unambiguous.
    await _storage.write(
      key: _kChannelIndexKey,
      value: ids.join(','),
    );
  }

  String _storageKeyFor(String channelId) => '$_kChannelKeyPrefix$channelId';

  String _publicStorageKey() => _storageKeyFor(kPublicChannelId);
}
