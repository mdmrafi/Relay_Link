// RelayLink — Ticket #34 "Save as evidence" from chat (long-press affordance).
//
// Bridges the chat layer and the Ticket #31 Evidence Vault: takes the
// already-decrypted plaintext body of a chat [Message] and persists it
// to the encrypted vault with provenance metadata that points back to
// the original chat message id.
//
// Design constraints (per the ticket):
//   * Do NOT touch `lib/vault/store.dart`. We layer on top of the
//     public [VaultStore] API; the encryption / persistence guarantees
//     of the vault are owned by that module.
//   * Pass the message body to the vault *directly*. We never round-trip
//     the text through `Clipboard.setData` or any other out-of-band
//     channel — that would let other apps sniff clipboard contents and
//     would also break the audit trail.
//   * Record provenance: each vault row saved from chat carries the
//     original message id in an `origin_message_id` column. The column
//     itself is added lazily by [_ensureOriginColumn] the first time
//     this module runs against a database — keeping the change
//     additive and idempotent without modifying `local_db.dart`.
//
// The chat-list row uses this service in two places:
//   * Long-press handler — builds an Android-style context menu with a
//     "Save as evidence" item that invokes [SaveMessageAsEvidence.save].
//   * Confirmation surface — the long-press handler emits a transient
//     toast "Saved to Evidence Vault" once the save succeeds; the
//     service itself never touches UI so it stays testable in isolation.

import 'dart:async';

import '../models/message.dart';
import '../storage/local_db.dart';
import 'store.dart';

/// Result of saving a single chat message into the Evidence Vault.
///
/// Carries both the encrypted [VaultRecord] (so the UI can navigate to
/// the vault list with the new row highlighted) and the original chat
/// message id (so callers can correlate the toast / undo with the source
/// row even after the message scrolls out of view).
class SavedEvidence {
  /// The encrypted vault row that was just persisted.
  final VaultRecord record;

  /// The chat message id the row was captured from. Always equals
  /// `message.id` at the time of the capture — preserved here for
  /// callers that pass [Message] through several layers.
  final String originMessageId;

  const SavedEvidence({required this.record, required this.originMessageId});

  @override
  String toString() =>
      'SavedEvidence(originMessageId=$originMessageId, recordId=${record.id})';
}

/// Service that wires a chat long-press handler to the encrypted
/// Evidence Vault.
///
/// One instance is cheap to keep around for the life of the app; the
/// constructor is synchronous and holds two collaborators: the
/// [VaultStore] for encryption and persistence, and the [LocalDb] for
/// the small `origin_message_id` provenance column we add lazily on
/// top of the existing `vault_records` schema.
class SaveMessageAsEvidence {
  /// Underlying vault store that owns the encryption + persistence.
  final VaultStore store;

  /// The shared [LocalDb] the vault store writes through. We need a
  /// direct handle here so we can `ALTER TABLE` (to add the
  /// `origin_message_id` column) and `UPDATE` (to stamp provenance on
  /// each saved row) without changing `lib/vault/store.dart`.
  final LocalDb db;

  /// Construct a saver for use in tests or production. The caller is
  /// responsible for sharing a single [VaultStore] across all savers
  /// so the at-rest encryption key is reused.
  const SaveMessageAsEvidence({required this.store, required this.db});

  /// Persist [plaintext] (the already-decrypted chat body) into the
  /// vault and stamp the resulting row with [message].id as
  /// `origin_message_id`.
  ///
  /// Returns a [SavedEvidence] whose [SavedEvidence.record] is the new
  /// encrypted vault row. The flow is:
  ///   1. Ensure the `origin_message_id` column exists on the
  ///      `vault_records` table (idempotent — first call adds it,
  ///      subsequent calls are a no-op).
  ///   2. Encrypt + insert the plaintext via [VaultStore.capture].
  ///   3. Update the inserted row to record [message].id as the
  ///      `origin_message_id` provenance.
  ///
  /// Step 3 happens *after* encryption so the plaintext never touches
  /// a SQLite column until AES-GCM has sealed it — the provenance
  /// column carries only the originating message id (not the body).
  ///
  /// [plaintext] is passed in (not derived from `message.payload` here)
  /// because chat messages are E2E-encrypted on the wire; the chat
  /// screen decrypts the payload with the appropriate ratchet /
  /// broadcast session, then hands the readable text to this method.
  /// Doing the decryption inside this module would force a dependency
  /// on the chat screen's ratchet state and prevent tests from feeding
  /// arbitrary fixtures.
  Future<SavedEvidence> save({
    required Message message,
    required String plaintext,
  }) async {
    if (plaintext.isEmpty) {
      throw ArgumentError.value(
        plaintext,
        'plaintext',
        'saveEvidenceFromChat: refusing to capture empty text',
      );
    }

    await _ensureOriginColumn();

    final record = await store.capture(plaintext);
    await _setOriginMessageId(record.id, message.id);

    return SavedEvidence(
      record: record,
      originMessageId: message.id,
    );
  }

  /// Read the chat message id stored on a vault record, or `null` if
  /// the record was captured from a non-chat source (or before this
  /// feature shipped).
  ///
  /// Exposed so callers (vault list, audit log) can link a vault row
  /// back to the original chat message for "view in chat" navigation.
  /// Returns `null` for rows that predate the column addition rather
  /// than throwing — pre-#34 rows remain valid vault records, just
  /// without a chat-link.
  Future<String?> originMessageIdFor(String vaultRecordId) async {
    if (!await _hasOriginColumn()) return null;
    final rows = await db.database.query(
      'vault_records',
      columns: <String>['origin_message_id'],
      where: 'id = ?',
      whereArgs: <Object?>[vaultRecordId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['origin_message_id'];
    if (raw == null) return null;
    final id = raw as String;
    return id.isEmpty ? null : id;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Add the `origin_message_id` column to `vault_records` if it
  /// doesn't already exist. SQLite's `ALTER TABLE ADD COLUMN` is
  /// idempotent at the *intent* level only; we check `PRAGMA
  /// table_info` first so a second call from a different code path
  /// can't fail with "duplicate column".
  ///
  /// A future ticket may fold this column into the formal schema
  /// (Ticket #31 v2 → v3); that future bump can then drop this call
  /// from `_ensureOriginColumn` and treat the column as part of v3.
  Future<void> _ensureOriginColumn() async {
    if (await _hasOriginColumn()) return;
    // SQLite does not allow parameterised ALTER TABLE — interpolate.
    await db.database.rawQuery(
      'ALTER TABLE vault_records ADD COLUMN origin_message_id TEXT;',
    );
  }

  /// Probe whether `vault_records` already has the `origin_message_id`
  /// column. Cheaper than [_ensureOriginColumn] because it never
  /// mutates — used by read paths so a pre-#34 install doesn't throw
  /// when the vault list asks for provenance.
  Future<bool> _hasOriginColumn() async {
    final cols = await db.database.rawQuery(
      'PRAGMA table_info(vault_records);',
    );
    return cols.any((row) => row['name'] == 'origin_message_id');
  }

  /// Stamp [originMessageId] on the vault row just inserted by
  /// [VaultStore.capture].
  ///
  /// We use an `UPDATE` instead of a re-`INSERT` because the row was
  /// already created with all the AES-GCM envelope columns populated
  /// by the store — touching those would invalidate the MAC.
  ///
  /// If the row is somehow missing (e.g. another process deleted it
  /// between capture and update) we silently no-op: the vault row is
  /// still encrypted and readable on its own; only the chat-link
  /// provenance is lost.
  Future<void> _setOriginMessageId(
    String vaultRecordId,
    String originMessageId,
  ) async {
    // _ensureOriginColumn runs first (above), so the column is
    // guaranteed to exist here — but we keep a defensive guard so a
    // future schema migration that drops the column can't NPE on us.
    if (!await _hasOriginColumn()) {
      throw StateError(
        'vault_records.origin_message_id is missing; call save() '
        'before stamping provenance',
      );
    }
    await db.database.rawUpdate(
      'UPDATE vault_records SET origin_message_id = ? WHERE id = ?;',
      <Object?>[originMessageId, vaultRecordId],
    );
  }
}

// ---------------------------------------------------------------------------
// UI-side helpers
// ---------------------------------------------------------------------------

/// One row of the long-press context menu surfaced by the chat screen.
///
/// Kept as a tiny value type so the chat widget can render the list
/// without importing the save service directly — the widget binds
/// `Save as evidence` to the [SaveMessageAsEvidence.save] callback
/// and emits the confirmation toast.
class ChatMessageAction {
  /// Stable id used by the Flutter `PopupMenuButton` / `showMenu`.
  final String id;

  /// Human-readable label rendered as the menu row.
  final String label;

  const ChatMessageAction({required this.id, required this.label});

  /// The "Save as evidence" menu item required by Ticket #34.
  static const ChatMessageAction saveAsEvidence = ChatMessageAction(
    id: 'save_as_evidence',
    label: 'Save as evidence',
  );
}
