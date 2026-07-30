// RelayLink — Ticket #28: contacts lookup interface for DIRECT-over-SMS.
//
// This file is intentionally thin: it provides the lookup surface that
// the SMS-DIRECT adapter needs (by recipient device-id → phone number),
// and nothing else. The persistence + UI is Ticket #40 (Contacts screen),
// which is blocked-by the QR-pairing flow that ships #16 first.
//
// The adapter (#28) consumes [ContactsLookup]; #40 will provide the
// production implementation by reading from the `contacts` table that
// #05's local DB will host. Until #40 lands, callers in the app wire a
// stub (or this file's in-memory implementation, useful for tests).

import 'dart:typed_data';

/// One paired contact (Ticket #40 + #16 — surfaced here so the SMS
/// adapter path can resolve a phone number from a recipient device-id).
///
/// `displayName` is a best-effort human label — never used for routing.
/// `phoneNumber` is E.164-formatted (`+CCNNNN...`) if the user has set
/// one; `null` otherwise. `x25519PublicKey` is present for #13 DIRECT
/// crypto (this adapter doesn't use it; only the server-side key
/// bootstrap does).
class ContactRecord {
  /// Stable device-id (16-hex of the peer's Ed25519 public key, per #02).
  final String deviceId;

  /// Best-effort human label.
  final String displayName;

  /// E.164 phone number for SMS transport, or `null` if the user has
  /// not provided one.
  final String? phoneNumber;

  /// Peer's X25519 public key (raw 32 bytes), or `null` if not yet
  /// paired via #16.
  final Uint8List? x25519PublicKey;

  const ContactRecord({
    required this.deviceId,
    required this.displayName,
    required this.x25519PublicKey,
    required this.phoneNumber,
  });

  /// Contact records are equal when their device-id and phone number
  /// match. The display name is intentionally not part of equality
  /// because the user can rename a contact without changing its
  /// identity.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ContactRecord &&
        other.deviceId == deviceId &&
        other.phoneNumber == phoneNumber &&
        other.displayName == displayName &&
        _bytesEqual(other.x25519PublicKey, x25519PublicKey);
  }

  @override
  int get hashCode => Object.hash(
        deviceId,
        displayName,
        phoneNumber,
        Object.hashAll(x25519PublicKey ?? Uint8List(0)),
      );

  @override
  String toString() => 'ContactRecord(deviceId=$deviceId, name=$displayName, '
      'phone=${phoneNumber ?? 'none'})';
}

bool _bytesEqual(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Minimal lookup interface the SMS-DIRECT adapter relies on.
///
/// #40 will provide the production implementation by reading from the
/// `contacts` table. Tests and pre-#40 wiring can use
/// [InMemoryContactsStore] below.
abstract class ContactsLookup {
  /// Look up a contact by [deviceId]. Returns `null` if no such
  /// contact has been paired.
  ContactRecord? lookupByDeviceId(String deviceId);
}

/// Trivial in-memory [ContactsLookup] useful for tests and pre-#40
/// app wiring. Thread-safe enough for the SMS-DIRECT adapter's usage
/// (one caller at a time, no concurrent mutation expected).
class InMemoryContactsStore implements ContactsLookup {
  final Map<String, ContactRecord> _byDeviceId;
  InMemoryContactsStore(Iterable<ContactRecord> records)
      : _byDeviceId = <String, ContactRecord>{
          for (final r in records) r.deviceId: r,
        };

  @override
  ContactRecord? lookupByDeviceId(String deviceId) => _byDeviceId[deviceId];

  /// Add or replace a contact. Returns the previous record (if any).
  ContactRecord? upsert(ContactRecord record) {
    final previous = _byDeviceId[record.deviceId];
    _byDeviceId[record.deviceId] = record;
    return previous;
  }

  /// Number of contacts currently stored.
  int get length => _byDeviceId.length;
}
