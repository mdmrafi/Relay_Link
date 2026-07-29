// RelayLink — Ticket #18 Firestore schema (typed Dart constants).
//
// This file is the single source of truth for Firestore field names. Any
// code that reads or writes a Firestore document under `relay/...`,
// `relay_direct/...`, `verified_orgs/...`, or `evidence/...` MUST refer to
// the constants here rather than to string literals. This keeps renames
// mechanical (one edit) and lets the analyzer catch typos.
//
// The schema mirrors the tables in `docs/firestore-schema.md`. Keep this
// file and the doc in lockstep — drift is the bug here.
//
// All non-doc classes are namespace-only (`abstract final class` with only
// `static const` fields, no constructors). They are not meant to be
// instantiated.

/// Collection path roots. Subcollection paths are built by [FirebaseBackend]
/// (see [FirebaseBackend.relayMessagesPath], [relayDirectMessagesPath],
/// [evidenceRecordsPath]) so the slash layout is centralized.
abstract final class Collections {
  /// BROADCAST-mode messages grouped by channel id.
  /// Path: `relay/{channel_id}/messages/{message_id}`.
  static const String relay = 'relay';

  /// DIRECT-mode messages addressed to a specific recipient by device id.
  /// Path: `relay_direct/{recipient_id}/messages/{message_id}`.
  static const String relayDirect = 'relay_direct';

  /// ALERT allowlist: organizations whose public key signs authentic alerts.
  /// Path: `verified_orgs/{org_id}`.
  static const String verifiedOrgs = 'verified_orgs';

  /// Evidence Vault text records uploaded to a pre-arranged recipient.
  /// Path: `evidence/{recipient_id}/records/{record_id}`.
  static const String evidence = 'evidence';
}

/// Field names for a document in `relay/{channel_id}/messages/` and
/// `relay_direct/{recipient_id}/messages/`.
///
/// Routing metadata (`sender_id`, `ttl`, `hop_count`, `signature`,
/// `created_at`) is intentionally plaintext so that relay nodes (gateways,
/// other phones) can route the message without decrypting the payload. The
/// `payload_b64` field is the only encrypted blob. `ratchet_header` is
/// plaintext for DIRECT messages (needed by the recipient to derive the
/// message key) and `null` for BROADCAST.
///
/// Every message doc MUST set `expires_at` — the server-side Firestore TTL
/// policy reads this field to delete expired messages. The README has the
/// console steps to configure the policy.
abstract final class RelayMessageDoc {
  /// Unique message id (UUIDv4). Same as the Firestore document id; lets
  /// clients index it without an extra read.
  static const String id = 'id';

  /// Public-key fingerprint of the sender's long-term Ed25519 identity key.
  static const String senderId = 'sender_id';

  /// Server timestamp (Firestore `Timestamp`) when the gateway wrote the
  /// document. Used by the UI to sort messages and by the relay to compute
  /// message age.
  static const String createdAt = 'created_at';

  /// Base64-encoded ciphertext. For BROADCAST, encrypted with the channel's
  /// symmetric key. For DIRECT, encrypted with the Double Ratchet session
  /// key derived from `ratchet_header`.
  static const String payloadB64 = 'payload_b64';

  /// Plaintext ratchet header (DIRECT messages only). Needed by the
  /// recipient to derive the message key. `null` for BROADCAST.
  static const String ratchetHeader = 'ratchet_header';

  /// Time-to-live in minutes (int). Per SPEC.md §5: SOS 12, ALERT 10, others
  /// 8. The relay decrements on each hop.
  static const String ttl = 'ttl';

  /// Number of hops this message has traversed (int). Starts at 0 at the
  /// sender, incremented by each relay. Hard cap (TBD) enforced in
  /// security rules.
  static const String hopCount = 'hop_count';

  /// Ed25519 signature over `id|sender_id|created_at|payload_b64|ttl|...`
  /// (the exact canonical form is finalized with the crypto ticket). Lets
  /// receivers authenticate the sender without trusting the relay.
  static const String signature = 'signature';

  /// UTC timestamp when the message should be deleted. The Firestore TTL
  /// policy in the console reads this field and auto-deletes the document
  /// at or after this time. Required on every write — there is no implicit
  /// retention.
  static const String expiresAt = 'expires_at';
}

/// Field names for `verified_orgs/{org_id}` documents.
///
/// The allowlist is a small, manually curated set of organizations whose
/// Ed25519 public key signs authentic ALERT messages. A match in the
/// receiver-side check promotes the alert to "verified" status. There is
/// NO field in the Message schema that a sender can set to claim
/// verification — verification is receiver-side only, by design.
abstract final class VerifiedOrgDoc {
  /// Document id (org id). Human-readable slug, e.g. `demo-red-crescent`.
  static const String id = 'id';

  /// Display name shown in the verified badge, e.g. "Demo Red Crescent".
  static const String displayName = 'display_name';

  /// Base64-encoded Ed25519 public key. Verified ALERT signatures must
  /// match this key.
  static const String publicKeyB64 = 'public_key_b64';

  /// Last time the local cache refreshed this row (server timestamp).
  /// Used so the UI can warn if the allowlist is stale and we're offline.
  static const String lastUpdated = 'last_updated';

  /// Server-side TTL expiry, same convention as [RelayMessageDoc.expiresAt].
  /// Allowlist rows are stable data; this field exists so the same TTL
  /// policy covers the collection.
  static const String expiresAt = 'expires_at';
}

/// Field names for `evidence/{recipient_id}/records/{record_id}` documents.
///
/// Evidence Vault text records are written by the local device, encrypted
/// at rest, and uploaded to the chosen recipient whenever any transport
/// (internet, SMS, mesh) comes back. The local ciphertext is sealed under
/// a per-record key, sealed under a vault-wrapping key, sealed under the
/// device identity key (per SPEC.md §11). The stored blob is the
/// outermmost-sealed ciphertext — the server cannot read it.
abstract final class EvidenceRecordDoc {
  /// Document id (UUIDv4). Same as the message id on the recipient side.
  static const String id = 'id';

  /// Public-key fingerprint of the recipient (the journalist / lawyer /
  /// family member pre-arranged in the recipient's settings).
  static const String recipientId = 'recipient_id';

  /// Public-key fingerprint of the sender (the device that captured the
  /// record). Lets the recipient associate the record with a known
  /// correspondent.
  static const String senderId = 'sender_id';

  /// Server timestamp when the document was created.
  static const String createdAt = 'created_at';

  /// Base64-encoded double-sealed ciphertext (per-record key wraps the
  /// plaintext, then the vault-wrapping key wraps the per-record key).
  static const String payloadB64 = 'payload_b64';

  /// SHA-256 of the plaintext (base64). Lets the recipient verify
  /// decryption succeeded without re-reading the original.
  static const String contentHashB64 = 'content_hash_b64';

  /// Ed25519 signature over `id|sender_id|recipient_id|created_at|content_hash_b64`.
  /// Authenticates the sender of the evidence record.
  static const String signature = 'signature';

  /// Server-side TTL expiry. Evidence is short-lived by default (the vault
  /// is meant for "deliver to my contact", not "store forever").
  static const String expiresAt = 'expires_at';
}
