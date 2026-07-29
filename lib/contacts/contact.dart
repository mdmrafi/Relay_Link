// RelayLink — Minimal Contact model (Ticket #40 + #27 support).
//
// This file defines the shape of a paired contact needed by the SMS fan-out
// path (#27) and the SMS re-injection transport (#26). The full Contacts
// screen, QR pairing flow, sqflite persistence, and edits live in Ticket
// #40, which is the owner of the production lifecycle. This minimal class
// is intentionally narrow so #27 can ship its seam without forcing #40's
// UI work onto its critical path.
//
// A contact carries:
//   * [id]            — stable identifier (currently the public-key hex).
//   * [displayName]   — human-readable name (may be empty).
//   * [publicKey]     — base64 device identity public key (paired via QR).
//   * [phoneNumber]   — optional E.164-ish number; null/empty when missing.
//
// Fan-out only cares about contacts with a non-empty [phoneNumber]; entries
// missing one are skipped (they can still be reached over mesh, DIRECT
// crypto, etc., just not via this particular leg).

/// Minimal paired-contact record used by SMS fan-out (#27), SMS re-injection
/// (#26), and the future Contacts screen (#40).
class Contact {
  /// Stable identifier. Conventionally the hex form of [publicKey], but
  /// this class does not enforce that — callers may use any unique string.
  final String id;

  /// Human-readable display name. May be empty (the user hasn't set one).
  final String displayName;

  /// Base64-encoded device identity public key (paired via QR).
  final String publicKey;

  /// Optional phone number in any string form the SMS backend accepts.
  /// `null` or empty string means "no SMS address on file" — fan-out skips
  /// the contact in that case.
  final String? phoneNumber;

  const Contact({
    required this.id,
    required this.displayName,
    required this.publicKey,
    required this.phoneNumber,
  });

  /// Whether this contact has a usable phone number for SMS fan-out.
  bool get hasPhone =>
      phoneNumber != null && phoneNumber!.trim().isNotEmpty;

  /// Returns a copy with the supplied fields replaced.
  Contact copyWith({
    String? id,
    String? displayName,
    String? publicKey,
    String? phoneNumber,
  }) {
    return Contact(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      publicKey: publicKey ?? this.publicKey,
      phoneNumber: phoneNumber ?? this.phoneNumber,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Contact &&
          other.id == id &&
          other.displayName == displayName &&
          other.publicKey == publicKey &&
          other.phoneNumber == phoneNumber);

  @override
  int get hashCode =>
      Object.hash(id, displayName, publicKey, phoneNumber);

  @override
  String toString() =>
      'Contact(id=$id, name="$displayName", phone=${phoneNumber ?? '—'})';
}
