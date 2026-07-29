// RelayLink — Ticket #31 vault encrypt-at-rest + storage.
//
// Provides `VaultRecord` (the at-rest shape) and `VaultStore` (the
// capture/list/get/decrypt API) for the text-only Evidence Vault.
//
// Encryption chain (per capture):
//
//   text
//     └─ AES-256-GCM(perRecordKey, nonce_text, aad)──► ciphertext
//                                                           (cipherText || mac)
//   perRecordKey (32 random bytes)
//     └─ AES-256-GCM(vaultWrappingKey, nonce_wk, aad)──► perRecordKeyWrapped
//                                                           (nonce || cipherText || mac)
//   vaultWrappingKey (32 random bytes, generated once per device)
//     └─ AES-256-GCM(identityKey, nonce_id, aad="vault-wrap-v1")──► vaultKeyWrapped
//     └─ stored in flutter_secure_storage under VaultStoreKeys.vaultWrappingKey
//
// Decryption unwraps in reverse order. Every AES step uses AES-GCM
// authenticated encryption via the `cryptography` package — there is no
// hand-rolled crypto in this file.
//
// Threat model:
//   * sqflite stores only ciphertext + wrapped keys. A reader of the DB
//     file alone cannot recover plaintext.
//   * flutter_secure_storage holds the wrapped vault-wrapping key (VWK).
//     A reader of secure storage alone still needs the device identity
//     to derive the wrap key and unwrap the VWK. So an attacker needs
//     both stores to break confidentiality.
//   * AES-GCM authentication tags mean any byte flip in ciphertext,
//     nonce, AAD, or wrapped keys is detected and decrypt throws —
//     no plaintext is ever partially leaked.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:uuid/uuid.dart';

import '../crypto/identity.dart';
import '../storage/local_db.dart';

/// AES-256-GCM primitive reused across the three encryption layers.
final AesGcm _aesGcm = AesGcm.with256bits();

/// HKDF info-domain for the VWK wrapping key derivation. Domain
/// separation prevents the derived key from accidentally being usable
/// as any other secret.
final Uint8List _vaultWrapInfo = Uint8List.fromList(
  utf8.encode('vault-wrap-v1'),
);

/// Secure-storage keys used by [VaultStore].
class VaultStoreKeys {
  VaultStoreKeys._();

  /// Wrapped vault-wrapping-key blob (`nonce(12) || ciphertext(32) ||
  /// mac(16)`, total 60 bytes), base64-encoded for storage.
  static const String vaultWrappingKey = 'vault_wrap_key_v1';
}

/// AES-GCM nonce length (12 bytes per RFC 5116).
const int _nonceLen = 12;

/// AES-GCM authentication tag length (16 bytes).
const int _macLen = 16;

/// Wire/storage shape of one encrypted Evidence Vault record.
///
/// All byte fields are stored as `BLOB` in sqflite. The MAC for each
/// AES-GCM layer is concatenated onto the ciphertext to keep the
/// schema compact (nonce lives in its own column).
class VaultRecord {
  /// UUIDv4 identifying this record. Matches the upload id once the row
  /// is pushed to Firebase Storage by the gateway path.
  final String id;

  /// AES-256-GCM ciphertext of the plaintext text evidence, with the
  /// 16-byte GCM tag appended (so it is `cipherText || mac` — 16 bytes
  /// longer than the plaintext).
  final Uint8List ciphertext;

  /// Per-record 32-byte AES key, encrypted under the vault-wrapping key
  /// (AES-256-GCM). Stored as `nonce(12) || cipherText(32) || mac(16)`.
  final Uint8List perRecordKeyWrapped;

  /// AES-GCM nonce for the text ciphertext (12 bytes).
  final Uint8List nonce;

  /// AES-GCM AAD bound into the text ciphertext. UTF-8 of `recipientId`
  /// when present, otherwise the literal ASCII `"self"`. Binds the
  /// ciphertext to its intended audience so a captured blob cannot be
  /// silently redirected.
  final Uint8List aad;

  /// UTC creation timestamp, milliseconds since epoch.
  final int createdAt;

  /// Intended recipient (device id or verified-org id). `null` for
  /// self-encrypted captures.
  final String? recipientId;

  const VaultRecord({
    required this.id,
    required this.ciphertext,
    required this.perRecordKeyWrapped,
    required this.nonce,
    required this.aad,
    required this.createdAt,
    required this.recipientId,
  });

  /// Convert to a SQLite-friendly map. Byte fields are stored as `BLOB`.
  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'ciphertext': ciphertext,
        'per_record_key_wrapped': perRecordKeyWrapped,
        'nonce': nonce,
        'aad': aad,
        'created_at': createdAt,
        'recipient_id': recipientId,
        'status': 'pending',
      };

  /// Decode from a SQLite row. Mirrors [toRow].
  static VaultRecord fromRow(Map<String, Object?> row) {
    Uint8List bytes(String col) {
      final v = row[col];
      if (v is Uint8List) return v;
      if (v is List<int>) return Uint8List.fromList(v);
      throw FormatException(
        'vault_records.$col must be a Uint8List (got ${v.runtimeType})',
      );
    }

    final recipient = row['recipient_id'] as String?;
    return VaultRecord(
      id: row['id']! as String,
      ciphertext: bytes('ciphertext'),
      perRecordKeyWrapped: bytes('per_record_key_wrapped'),
      nonce: bytes('nonce'),
      aad: bytes('aad'),
      createdAt: (row['created_at']! as num).toInt(),
      recipientId: (recipient == null || recipient.isEmpty) ? null : recipient,
    );
  }

  @override
  String toString() =>
      'VaultRecord(id=$id, recipient=${recipientId ?? 'self'}, '
      'ct=${ciphertext.length}B, createdAt=$createdAt)';
}

/// Evidence Vault persistent store.
///
/// Use [VaultStore.create] in production code (it loads/generates the
/// device identity and the vault-wrapping key on demand). Tests inject
/// a pre-built [DeviceIdentity] and [LocalDb] so they don't need the
/// real platform keychain or a real on-device SQLite file.
class VaultStore {
  final DeviceIdentity _identity;
  final LocalDb _db;
  final FlutterSecureStorage _storage;

  /// Cached vault-wrapping key (32 bytes). Cleared on [close].
  Uint8List? _vwk;

  VaultStore._(this._identity, this._db, this._storage);

  /// Build a [VaultStore] from the production dependencies.
  ///
  /// Loads (or generates) the device identity, opens the default local
  /// DB, and reads the wrapped vault-wrapping key from secure storage.
  static Future<VaultStore> instance({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    final identity = await DeviceIdentity.loadOrGenerate(storage: storage);
    final db = await LocalDb.instance();
    final store = VaultStore._(identity, db, storage);
    await store._loadOrCreateVwk();
    return store;
  }

  /// Build a [VaultStore] with explicit dependencies (used by tests).
  static Future<VaultStore> create({
    required DeviceIdentity identity,
    required LocalDb db,
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) async {
    final store = VaultStore._(identity, db, storage);
    await store._loadOrCreateVwk();
    return store;
  }

  /// Encrypt [text] for optional [recipientId] and persist it.
  ///
  /// If [recipientId] is `null` or empty, the capture is self-encrypted
  /// — the device can decrypt it at any time without the recipient's
  /// cooperation.
  Future<VaultRecord> capture(
    String text, [
    String? recipientId,
  ]) async {
    final rec = await _buildEncryptedRecord(
      utf8.encode(text),
      recipientId: recipientId,
    );
    await _db.database.insert(
      'vault_records',
      rec.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return rec;
  }

  /// Decrypt [record] back to its raw plaintext bytes.
  ///
  /// Throws [SecretBoxAuthenticationError] (from `cryptography`) when
  /// any byte in ciphertext, wrapped key, nonce, AAD, or the wrapped
  /// VWK has been tampered with — no plaintext is ever partially leaked.
  Future<Uint8List> decrypt(VaultRecord record) async {
    final vwk = await _loadOrCreateVwk();

    // 1. Unwrap per-record key using VWK + record AAD.
    final perRecordKey = await _unwrapPerRecordKey(
      vwk: vwk,
      wrapped: record.perRecordKeyWrapped,
      aad: record.aad,
    );

    // 2. Decrypt text ciphertext using per-record key + record nonce/AAD.
    //    The ciphertext BLOB is `cipherText || mac`; split it back.
    final ct = record.ciphertext;
    if (ct.length < _macLen) {
      throw const FormatException(
        'vault_records.ciphertext is too short to contain a GCM tag',
      );
    }
    final cipherText = ct.sublist(0, ct.length - _macLen);
    final mac = ct.sublist(ct.length - _macLen);
    final box = SecretBox(cipherText, nonce: record.nonce, mac: Mac(mac));
    final pt = await _aesGcm.decrypt(box, secretKey: perRecordKey, aad: record.aad);
    return Uint8List.fromList(pt);
  }

  /// All stored records, newest first.
  Future<List<VaultRecord>> list() async {
    final rows = await _db.database.query(
      'vault_records',
      orderBy: 'created_at DESC',
    );
    return rows.map(VaultRecord.fromRow).toList(growable: false);
  }

  /// Fetch a single record by id, or `null` if absent.
  Future<VaultRecord?> get(String id) async {
    final rows = await _db.database.query(
      'vault_records',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return VaultRecord.fromRow(rows.first);
  }

  /// Release cached material. Safe to call multiple times.
  void close() {
    _vwk = null;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Load the wrapped VWK from secure storage, unwrap it with the
  /// identity-derived wrap key, and cache the result. If no VWK exists
  /// yet, generate one and persist it.
  Future<Uint8List> _loadOrCreateVwk() async {
    final cached = _vwk;
    if (cached != null) return cached;

    final wrapKey = await _identity.deriveKeyMaterial(
      info: 'vault-wrap-v1',
      length: 32,
    );

    final existing = await _storage.read(key: VaultStoreKeys.vaultWrappingKey);
    final vwk = await _resolveVwk(existing: existing, wrapKey: wrapKey);
    _vwk = vwk;
    return vwk;
  }

  Future<Uint8List> _resolveVwk({
    required String? existing,
    required Uint8List wrapKey,
  }) async {
    if (existing != null && existing.isNotEmpty) {
      final blob = base64.decode(existing);
      final vwk = await _decryptBlob(blob, wrapKey, _vaultWrapInfo);
      return Uint8List.fromList(vwk);
    }
    // Generate a fresh VWK and persist it wrapped under the wrap key.
    final vwk = _randomBytes(32);
    final blob = await _encryptBlob(vwk, wrapKey, _vaultWrapInfo);
    await _storage.write(
      key: VaultStoreKeys.vaultWrappingKey,
      value: base64.encode(blob),
    );
    return vwk;
  }

  /// Build an encrypted [VaultRecord] for [plaintext] but do NOT persist.
  Future<VaultRecord> _buildEncryptedRecord(
    List<int> plaintext, {
    String? recipientId,
  }) async {
    final vwk = await _loadOrCreateVwk();

    final hasRecipient = recipientId != null && recipientId.isNotEmpty;
    final aad = Uint8List.fromList(
      utf8.encode(hasRecipient ? recipientId : 'self'),
    );

    // Per-record key (32 random bytes).
    final perRecordKey = SecretKey(_randomBytes(32));

    // Encrypt plaintext under per-record key.
    final textBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: perRecordKey,
      aad: aad,
    );
    final ciphertext = Uint8List.fromList(<int>[
      ...textBox.cipherText,
      ...textBox.mac.bytes,
    ]);

    // Wrap per-record key under VWK, with the same AAD so a wrapped
    // blob can never be silently rebound to a different audience.
    final perKeyBytes = Uint8List.fromList(await perRecordKey.extractBytes());
    final perRecordKeyWrapped = await _encryptBlob(
      perKeyBytes,
      vwk,
      aad,
    );

    return VaultRecord(
      id: const Uuid().v4(),
      ciphertext: ciphertext,
      perRecordKeyWrapped: perRecordKeyWrapped,
      nonce: Uint8List.fromList(textBox.nonce),
      aad: aad,
      createdAt: DateTime.now().toUtc().millisecondsSinceEpoch,
      recipientId: hasRecipient ? recipientId : null,
    );
  }

  /// Unwrap the per-record AES key from [wrapped] using [vwk] + [aad].
  Future<SecretKey> _unwrapPerRecordKey({
    required Uint8List vwk,
    required Uint8List wrapped,
    required Uint8List aad,
  }) async {
    final raw = await _decryptBlob(wrapped, vwk, aad);
    return SecretKey(raw);
  }

  /// Helper: encrypt [plaintext] under [key] with [aad] and return a
  /// `nonce(12) || cipherText || mac(16)` blob.
  Future<Uint8List> _encryptBlob(
    List<int> plaintext,
    List<int> key,
    List<int> aad,
  ) async {
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(<int>[
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Helper: decrypt a `nonce(12) || cipherText || mac(16)` blob.
  Future<Uint8List> _decryptBlob(
    List<int> blob,
    List<int> key,
    List<int> aad,
  ) async {
    if (blob.length < _nonceLen + _macLen) {
      throw const FormatException(
        'encrypted blob is too short to be a valid AES-GCM envelope',
      );
    }
    final nonce = blob.sublist(0, _nonceLen);
    final mac = blob.sublist(blob.length - _macLen);
    final ct = blob.sublist(_nonceLen, blob.length - _macLen);
    final box = SecretBox(ct, nonce: nonce, mac: Mac(mac));
    return Uint8List.fromList(
      await _aesGcm.decrypt(box, secretKey: SecretKey(key), aad: aad),
    );
  }
}

/// Cryptographically secure RNG bytes. Uses [Random.secure] which is
/// backed by the platform CSPRNG (e.g. /dev/urandom on Linux, BCryptGenRandom
/// on Windows).
Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}
