// RelayLink — Ticket #05 local SQLite helper.
//
// A thin sqflite wrapper exposing three concerns:
//   * `messages`     — every local envelope ever seen, so we can render
//                      conversation history offline and prune when needed
//                      (Tickets #08 send/receive, #40 search).
//   * `seen_cache`   — message-id dedup used by the mesh relay layer
//                      (Ticket #09) so we never re-broadcast the same id.
//   * `vault_records`— encrypted text-only evidence vault rows that have
//                      not yet been uploaded to a verified recipient
//                      (Ticket #31).
//
// JSON is stored as TEXT (utf-8) so a single `messages.id` row can be
// dumped to disk and replayed across schema bumps without re-encoding byte
// fields twice.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../contacts/contacts_lookup.dart';
import '../models/message.dart';
import 'vault_record.dart';

/// Local SQLite database wrapper (sqflite).
///
/// Application code should use the singleton form:
///
/// ```dart
/// final db = await LocalDb.instance();
/// await db.insertMessage(msg);
/// ```
///
/// Tests inject a pre-opened [Database] (typically an in-memory
/// `sqflite_common_ffi` database) via [LocalDb.withDatabase] so they don't
/// touch the real on-device SQLite file.
class LocalDb {
  /// Bumped whenever a migration is added. Migrations are additive; never
  /// rewrite an existing onCreate block.
  ///
  /// Version history:
  ///   * v1 — initial schema (messages, seen_cache, vault_records with a
  ///     single ciphertext column, no encryption envelope).
  ///   * v2 — Ticket #31: vault_records gains `per_record_key_wrapped`,
  ///     `nonce`, and `aad` columns for the AES-256-GCM envelope.
  ///   * v3 — Pairing: `contacts` table added for the DIRECT-crypto
  ///     bootstrap flow (this plan). Stores device-id, display name, phone
  ///     number, X25519 public key, and the pairing timestamp.
  static const int schemaVersion = 3;

  /// Default on-device database name. Lives under the platform's
  /// `getDatabasesPath()` (sqflite handles iOS/Android/desktop paths).
  static const String defaultDbName = 'relaylink.db';

  /// SQL executed on first-launch and on every schema upgrade to `version`
  /// when no row for that version exists in `user_version`.
  ///
  /// Uses `IF NOT EXISTS` so the statements are idempotent — that lets
  /// tests call [migrate] twice (once from `onCreate`, once from
  /// [LocalDb.withDatabase]) without exploding.
/// Public re-export of [_createV1] for migration tests. Tests use this
  /// to spin up a strict v1 database so they can verify the v1 → v2
  /// migration logic.
  static String get createV1Sql => _createV1;

  static const String _createV1 = '''
    CREATE TABLE IF NOT EXISTS messages (
      id          TEXT PRIMARY KEY,
      json        TEXT NOT NULL,
      received_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS messages_received_at_idx
      ON messages(received_at);

    CREATE TABLE IF NOT EXISTS seen_cache (
      id            TEXT PRIMARY KEY,
      first_seen_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS vault_records (
      id           TEXT PRIMARY KEY,
      ciphertext   BLOB    NOT NULL,
      created_at   INTEGER NOT NULL,
      recipient_id TEXT    NOT NULL DEFAULT '',
      status       TEXT    NOT NULL
    );
    CREATE INDEX IF NOT EXISTS vault_records_created_at_idx
      ON vault_records(created_at);
  ''';

  /// v3 schema for new installs. Adds the `contacts` table for paired
  /// device-id → (display name, phone, X25519 pub key, paired-at).
  /// Includes the v1 + v2 message/vault tables so this is the single
  /// source of truth for fresh installs.
  static const String _createV3 = '''
    CREATE TABLE IF NOT EXISTS messages (
      id          TEXT PRIMARY KEY,
      json        TEXT NOT NULL,
      received_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS messages_received_at_idx
      ON messages(received_at);

    CREATE TABLE IF NOT EXISTS seen_cache (
      id            TEXT PRIMARY KEY,
      first_seen_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS vault_records (
      id                     TEXT    PRIMARY KEY,
      ciphertext             BLOB,
      per_record_key_wrapped BLOB,
      nonce                  BLOB,
      aad                    BLOB,
      created_at             INTEGER NOT NULL,
      recipient_id           TEXT    NOT NULL DEFAULT '',
      status                 TEXT    NOT NULL DEFAULT 'pending'
    );
    CREATE INDEX IF NOT EXISTS vault_records_created_at_idx
      ON vault_records(created_at);

    CREATE TABLE IF NOT EXISTS contacts (
      device_id          TEXT    PRIMARY KEY,
      display_name       TEXT    NOT NULL DEFAULT '',
      phone_number       TEXT,
      x25519_public_key  BLOB,
      paired_at          INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS contacts_paired_at_idx
      ON contacts(paired_at);
  ''';

  /// Apply the v1 → v2 migration idempotently: add the three new
  /// columns to `vault_records` if they don't already exist. Uses
  /// `PRAGMA table_info` to test for the column first so a partial
  /// migration that already added some columns won't fail.
  static Future<void> _applyV2(Database db) async {
    await _addColumnIfMissing(db, 'vault_records', 'per_record_key_wrapped',
        'BLOB');
    await _addColumnIfMissing(db, 'vault_records', 'nonce', 'BLOB');
    await _addColumnIfMissing(db, 'vault_records', 'aad', 'BLOB');
  }

  /// Apply the v2 → v3 migration idempotently: create the `contacts`
  /// table if it doesn't already exist. SQLite's `CREATE TABLE IF NOT
  /// EXISTS` makes this a no-op on subsequent runs.
  static Future<void> _applyV3(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        device_id          TEXT    PRIMARY KEY,
        display_name       TEXT    NOT NULL DEFAULT '',
        phone_number       TEXT,
        x25519_public_key  BLOB,
        paired_at          INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS contacts_paired_at_idx
        ON contacts(paired_at);
    ''');
  }

  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table);');
    // If the table itself doesn't exist yet, there's nothing to alter —
    // _applyV3 / _createV1 will create the table with all needed columns.
    if (rows.isEmpty) return;
    final exists = rows.any((row) => row['name'] == column);
    if (exists) return;
    // SQLite does not allow parameterized ALTER TABLE — interpolate.
    await db.rawQuery('ALTER TABLE $table ADD COLUMN $column $type;');
  }

  /// Execute a string that may contain multiple semicolon-separated SQL
  /// statements. sqflite's [Database.execute] only runs the first statement
  /// in a multi-statement string, so we split and execute each one
  /// individually. Empty/whitespace-only segments are skipped.
  static Future<void> _execAll(Database db, String sql) async {
    for (final stmt in sql.split(';')) {
      final trimmed = stmt.trim();
      if (trimmed.isEmpty) continue;
      await db.execute('$trimmed;');
    }
  }

  final Database _db;

  LocalDb._(this._db);

  /// Singleton accessor used by app code. Opens (creating if absent) the
  /// default on-device database.
  ///
  /// Safe to call from `main()` after `WidgetsFlutterBinding.ensureInitialized()`.
  static LocalDb? _singleton;

  static Future<LocalDb> instance() async {
    final existing = _singleton;
    if (existing != null) return existing;
    final db = await _openDefault();
    // Idempotently ensure every table exists regardless of the stored
    // user_version. Guards against devices where user_version was stamped
    // as 3 before the contacts table migration was applied (the CREATE
    // TABLE IF NOT EXISTS / ALTER TABLE IF NOT EXISTS statements in
    // migrate() are safe to run multiple times and cost nothing when the
    // schema is already current).
    await migrate(db);
    final wrapper = LocalDb._(db);
    _singleton = wrapper;
    return wrapper;
  }

  /// Reset the singleton — only useful in tests.
  static void resetForTesting() {
    _singleton = null;
  }

  /// Construct a `LocalDb` over a pre-opened [Database]. Used by tests
  /// (in-memory sqflite_common_ffi) and by future tickets that want to open
  /// the database with custom paths (e.g. an encrypted sqlcipher variant).
  ///
  /// The caller is responsible for having already run [_migrate] on [db]
  /// (use [LocalDb.migrate] helper if unsure).
  static Future<LocalDb> withDatabase(Database db) async {
    // The wrapper itself is cheap, but we still want to ensure the schema
    // is current rather than trusting the caller blindly.
    await migrate(db);
    final wrapper = LocalDb._(db);
    _singleton ??= wrapper;
    return wrapper;
  }

  /// Idempotently apply migrations up to [schemaVersion]. Safe to call on
  /// a fresh database (creates tables) or on a partial one (bumps version
  /// and applies upgrade paths).
  static Future<void> migrate(Database db) async {
    // Apply v1 (no-op if already current). Then add v2 columns to
    // vault_records. Then create the v3 contacts table. A fresh install
    // goes through all three; an existing install picks up only what's
    // missing thanks to the idempotent CREATE/ALTER statements.
    //
    // IMPORTANT: use _execAll, not db.execute, for multi-statement SQL.
    // sqflite's execute() silently stops after the first statement when
    // the string contains multiple semicolon-separated statements.
    await _execAll(db, _createV1);
    await _applyV2(db);
    await _applyV3(db);
    await _ensureUserVersion(db, schemaVersion);
  }

  static Future<void> _ensureUserVersion(Database db, int version) async {
    final rows = await db.rawQuery('PRAGMA user_version;');
    final current = (rows.first.values.first as int?) ?? 0;
    if (current < version) {
      // sqflite/dart_sqlite do not support parameterized PRAGMAs; use raw.
      await db.rawQuery('PRAGMA user_version = $version;');
    }
  }

  static Future<Database> _openDefault() async {
    final dir = await getDatabasesPath();
    final path = dir.endsWith('/')
        ? '$dir$defaultDbName'
        : '$dir/$defaultDbName';
    return openDatabase(
      path,
      version: schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onConfigure(Database db) async {
    // Foreign-key support is off by default in SQLite. We don't have FKs
    // in v1 but enabling it now means a future schema bump just gets to
    // add the constraints without a behavior change.
    await db.execute('PRAGMA foreign_keys = ON;');
  }

  static Future<void> _onCreate(Database db, int version) async {
    // New databases receive the current schema directly.
    // Use _execAll — not db.execute — because _createV3 is a multi-statement
    // string and sqflite only runs the first statement per execute() call.
    await _execAll(db, _createV3);
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Each branch is a monotonic upgrade. When the next schema bump is
    // added, add `if (oldVersion < 4) { ... }` etc. — DO NOT edit the
    // v1 path above.
    if (oldVersion < 1) {
      await _execAll(db, _createV1);
    }
    if (oldVersion < 2) {
      // v1 → v2: Ticket #31 vault at-rest encryption envelope. Existing
      // v1 rows get NULL for the new BLOB columns; the new [VaultStore]
      // only reads rows it created itself, so legacy rows are preserved
      // but ignored.
      await _applyV2(db);
    }
    if (oldVersion < 3) {
      // v2 → v3: paired-contacts table for DIRECT-crypto bootstrap.
      await _applyV3(db);
    }
  }

  // ---------------------------------------------------------------------------
  // Accessors
  // ---------------------------------------------------------------------------

  /// Underlying [Database]. Exposed for advanced use (transactions joining
  /// multiple helpers). Prefer the typed methods below.
  Database get database => _db;

  Future<void> close() async {
    await _db.close();
    if (identical(_singleton, this)) _singleton = null;
  }

  // ---------------------------------------------------------------------------
  // messages
  // ---------------------------------------------------------------------------

  /// Insert (or upsert) a [Message]. The message is JSON-encoded and
  /// stored as TEXT alongside the local `received_at` (millis since epoch,
  /// UTC) used for ordering and pruning.
  Future<void> insertMessage(Message msg) async {
    await _db.insert(
      'messages',
      <String, Object?>{
        'id': msg.id,
        'json': jsonEncode(msg.toJson()),
        'received_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Load a single message by id, or `null` if unknown.
  ///
  /// Decodes the JSON through [Message.fromJson]; bad rows throw a
  /// [FormatException] so a corrupt envelope doesn't get silently
  /// re-rendered.
  Future<Message?> getMessage(String id) async {
    final rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['json'] as String?;
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('messages.json must be a JSON object');
    }
    return Message.fromJson(decoded);
  }

  /// Recent messages, newest first. Pass `offset` to page through history.
  Future<List<Message>> listMessages({
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _db.query(
      'messages',
      orderBy: 'received_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((row) {
          final raw = row['json'] as String?;
          if (raw == null) return null;
          try {
            final decoded = jsonDecode(raw);
            if (decoded is! Map<String, dynamic>) return null;
            return Message.fromJson(decoded);
          } catch (e, st) {
            debugPrint('listMessages: failed to decode message row: $e\n$st');
            rethrow;
          }
        })
        .whereType<Message>()
        .toList(growable: false);
  }

  /// Delete messages whose local `received_at` is older than [timestampMs].
  /// Returns the number of rows removed.
  Future<int> pruneOlderThan(int timestampMs) async {
    return _db.delete(
      'messages',
      where: 'received_at < ?',
      whereArgs: <Object?>[timestampMs],
    );
  }

  // ---------------------------------------------------------------------------
  // seen_cache
  // ---------------------------------------------------------------------------

  /// Mark a message id as seen. Idempotent — re-marking updates
  /// `first_seen_at` only when this is the first sighting (preserves the
  /// original timestamp).
  Future<void> markSeen(String id) async {
    await _db.rawInsert(
      'INSERT OR IGNORE INTO seen_cache (id, first_seen_at) VALUES (?, ?);',
      <Object?>[id, DateTime.now().toUtc().millisecondsSinceEpoch],
    );
  }

  /// Has this id been marked seen yet?
  Future<bool> isSeen(String id) async {
    final rows = await _db.query(
      'seen_cache',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// All currently-cached seen message ids. Used by the mesh relay layer
  /// (Ticket #09) to build a peer's bloom filter on connect.
  Future<List<String>> listSeenIds() async {
    final rows = await _db.query('seen_cache', columns: <String>['id']);
    return rows
        .map((row) => row['id'] as String)
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // vault_records
  // ---------------------------------------------------------------------------

  /// Insert (or upsert) a vault record.
  Future<void> insertVaultRecord(VaultRecord rec) async {
    await _db.insert(
      'vault_records',
      rec.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// All vault records, newest first.
  Future<List<VaultRecord>> listVaultRecords() async {
    final rows = await _db.query(
      'vault_records',
      orderBy: 'created_at DESC',
    );
    return rows
        .map(VaultRecord.fromRow)
        .toList(growable: false);
  }

  /// Delete the vault record with the given id. Returns rows affected
  /// (0 if it was already gone).
  Future<int> deleteVaultRecord(String id) async {
    return _db.delete(
      'vault_records',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  // ---------------------------------------------------------------------------
  // contacts (v3)
  // ---------------------------------------------------------------------------

  /// Insert (or upsert) a [ContactRecord]. Stores the X25519 public key as
  /// a BLOB when present; null otherwise. The `paired_at` column is set to
  /// `DateTime.now().toUtc().millisecondsSinceEpoch` so callers can list
  /// contacts by recency.
  Future<void> insertContact(ContactRecord record) async {
    await _db.insert(
      'contacts',
      <String, Object?>{
        'device_id': record.deviceId,
        'display_name': record.displayName,
        'phone_number': record.phoneNumber,
        'x25519_public_key': record.x25519PublicKey == null
            ? null
            : Uint8List.fromList(record.x25519PublicKey!),
        'paired_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Look up a single contact by [deviceId]. Returns `null` if no contact
  /// with that id is paired.
  Future<ContactRecord?> getContact(String deviceId) async {
    final rows = await _db.query(
      'contacts',
      where: 'device_id = ?',
      whereArgs: <Object?>[deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _contactFromRow(rows.first);
  }

  /// All paired contacts, newest first.
  Future<List<ContactRecord>> listContacts() async {
    final rows = await _db.query('contacts', orderBy: 'paired_at DESC');
    return rows.map(_contactFromRow).toList(growable: false);
  }

  /// Delete a paired contact by id. Returns rows affected (0 if it was
  /// already gone).
  Future<int> deleteContact(String deviceId) async {
    return _db.delete(
      'contacts',
      where: 'device_id = ?',
      whereArgs: <Object?>[deviceId],
    );
  }

  ContactRecord _contactFromRow(Map<String, Object?> row) {
    final pk = row['x25519_public_key'];
    Uint8List? x25519;
    if (pk is Uint8List) {
      x25519 = pk;
    } else if (pk is List<int>) {
      x25519 = Uint8List.fromList(pk);
    }
    return ContactRecord(
      deviceId: row['device_id']! as String,
      displayName: (row['display_name'] as String?) ?? '',
      phoneNumber: row['phone_number'] as String?,
      x25519PublicKey: x25519,
    );
  }
}