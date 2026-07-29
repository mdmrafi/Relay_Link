// RelayLink — Ticket #05 vault record schema.
//
// A row in the local `vault_records` table. The local DB stores only
// ciphertext and metadata; the actual evidence is uploaded later (when
// connectivity is available) via the gateway relay path (Tickets #31–#34).
//
// `status` is intentionally an open string so future tickets (delivered,
// uploaded, expired, …) can extend without a schema change.

import 'dart:typed_data';

/// Local Evidence Vault record.
///
/// Holds the encrypted text blob (AES-256-GCM ciphertext, see SPEC.md §8),
/// the recipient this evidence was destined for, and lifecycle state.
class VaultRecord {
  /// Stable identifier (UUIDv4). Matches the evidence-vault upload id once
  /// the record is pushed to Firebase Storage.
  final String id;

  /// AES-256-GCM ciphertext of the text evidence. Stored raw in the
  /// SQLite row (sqflite binds `Uint8List` to a `BLOB`).
  final Uint8List ciphertext;

  /// UTC creation timestamp, milliseconds since epoch.
  final int createdAtMillis;

  /// Intended recipient (device id or verified-org id). May be empty when
  /// the user hasn't picked a recipient yet (draft mode).
  final String recipientId;

  /// Lifecycle status. Free-form; known values:
  ///   * `draft`      — captured, not yet addressed
  ///   * `pending`    — ready to upload on next connectivity window
  ///   * `delivered`  — recipient device acknowledged receipt
  ///   * `failed`     — upload retried out of attempts; user-visible
  final String status;

  const VaultRecord({
    required this.id,
    required this.ciphertext,
    required this.createdAtMillis,
    required this.recipientId,
    required this.status,
  });

  /// Convert to a SQLite-friendly map. Byte fields are stored as `BLOB`.
  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'ciphertext': ciphertext,
        'created_at': createdAtMillis,
        'recipient_id': recipientId,
        'status': status,
      };

  /// Decode from a SQLite row. Mirrors [toRow].
  static VaultRecord fromRow(Map<String, Object?> row) {
    final ciphertext = row['ciphertext'];
    if (ciphertext is! Uint8List) {
      // sqflite may hand us a `List<int>` on some platforms — normalize.
      if (ciphertext is List<int>) {
        return VaultRecord(
          id: row['id']! as String,
          ciphertext: Uint8List.fromList(ciphertext),
          createdAtMillis: (row['created_at']! as num).toInt(),
          recipientId: (row['recipient_id'] as String?) ?? '',
          status: row['status']! as String,
        );
      }
      throw FormatException(
        'vault_records.ciphertext must be a Uint8List (got '
        '${ciphertext.runtimeType})',
      );
    }
    return VaultRecord(
      id: row['id']! as String,
      ciphertext: ciphertext,
      createdAtMillis: (row['created_at']! as num).toInt(),
      recipientId: (row['recipient_id'] as String?) ?? '',
      status: row['status']! as String,
    );
  }

  VaultRecord copyWith({
    String? id,
    Uint8List? ciphertext,
    int? createdAtMillis,
    String? recipientId,
    String? status,
  }) {
    return VaultRecord(
      id: id ?? this.id,
      ciphertext: ciphertext ?? this.ciphertext,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      recipientId: recipientId ?? this.recipientId,
      status: status ?? this.status,
    );
  }

  @override
  String toString() =>
      'VaultRecord(id=$id, recipient=$recipientId, status=$status, '
      'len=${ciphertext.length}B, createdAt=$createdAtMillis)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is VaultRecord &&
        other.id == id &&
        _bytesEqual(other.ciphertext, ciphertext) &&
        other.createdAtMillis == createdAtMillis &&
        other.recipientId == recipientId &&
        other.status == status;
  }

  @override
  int get hashCode => Object.hash(
        id,
        Object.hashAll(ciphertext),
        createdAtMillis,
        recipientId,
        status,
      );
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}