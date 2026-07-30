// RelayLink — Ticket #33 vault send-on-connect.
//
// When any transport (mesh, internet, SMS) becomes available, the vault
// must attempt to deliver any `EvidenceRecord`s that have been queued
// for a specific recipient while offline. This is the §18 #6 success
// criterion.
//
// Design notes:
//
//   * `VaultSendOnConnect.onChannelAvailable()` is the single entry
//     point. The caller (e.g. a transport-availability observer) hands
//     us the `Transport` that just came up; we do not poll.
//
//   * We depend on a small abstract `VaultSendSource`, not the concrete
//     `VaultStore`, so tests can drive every branch with an in-memory
//     fake and production code wires it to the real `LocalDb` via
//     `LocalDbVaultSendSource`. The `VaultStore` itself is read-only
//     from this file — we don't modify it.
//
//   * Encryption is hidden behind another small abstract
//     `DirectMessageEncryptor`. Production wires it to the HKDF-chain
//     DIRECT path (Ticket #13); tests inject a recognisable fake so
//     they can assert against the exact bytes the envelope carried.
//
//   * A single failed record must NOT abort the rest of the queue. We
//     catch per-record errors (decrypt, encrypt, send) and continue.
//     Status is only flipped to 'sent' when the transport actually
//     accepted the bytes; failure leaves the row in 'pending' for the
//     next attempt.
//
//   * `Transport.isAvailable() == false` is a short-circuit: we do not
//     even list records. This matches the §18 requirement that we only
//     attempt delivery when a channel is actually open.

import 'dart:typed_data';

import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';

/// Read-side projection of a queued vault record: just the fields the
/// deliverer needs. Production sources build this from the real
/// `vault_records` table; tests build it from a fake.
///
/// The full `VaultRecord` (with ciphertext + AES-GCM envelope) stays
/// inside the source — the deliverer never holds raw ciphertext.
class PendingVaultRecord {
  /// UUIDv4 of the underlying row in `vault_records`.
  final String id;

  /// Intended recipient (device id or verified-org id). Never empty —
  /// records without a recipient are self-captures and never reach the
  /// deliverer.
  final String recipientId;

  const PendingVaultRecord({
    required this.id,
    required this.recipientId,
  });
}

/// What the deliverer needs from the vault store. Production wires this
/// to `LocalDbVaultSendSource`; tests inject `FakeVaultSource`.
///
/// Implementations MUST:
///
///   * Filter out self-captures (`recipientId == null || ''`).
///   * Filter out already-sent records (`status == 'sent'`).
///   * Preserve ordering (newest-first or oldest-first — the deliverer
///     does not depend on it, but tests assert on stable output).
abstract class VaultSendSource {
  /// All records currently awaiting delivery. Order is implementation
  /// defined; the deliverer processes every entry.
  Future<List<PendingVaultRecord>> listPendingForDelivery();

  /// Decrypt [record] back to its raw plaintext bytes. Throws when the
  /// AES-GCM auth fails (tampering, key mismatch) — the deliverer
  /// catches and skips so one corrupt row does not block the queue.
  Future<Uint8List> decrypt(PendingVaultRecord record);

  /// Mark [id] as delivered (`status = 'sent'`). Called only after the
  /// transport has accepted the bytes. Failed transports leave the row
  /// untouched for the next attempt.
  Future<void> markSent(String id);
}

/// Result of encrypting plaintext for a DIRECT recipient.
///
/// `ciphertext` is the AES-GCM sealed body that goes into the envelope's
/// `payload`. `ratchetHeader` is the per-message Double-Ratchet header
/// (Ticket #13) that lets the recipient advance its chain.
class DirectEncryptedPayload {
  const DirectEncryptedPayload({
    required this.ciphertext,
    required this.ratchetHeader,
  });

  final Uint8List ciphertext;
  final Uint8List ratchetHeader;
}

/// Sealed-by-recipient encryptor. Production wires this to the DIRECT
/// crypto path (Ticket #13); tests inject a fake.
abstract class DirectMessageEncryptor {
  Future<DirectEncryptedPayload> encryptForRecipient({
    required String recipientId,
    required Uint8List plaintext,
  });
}

/// Drains the vault's pending-delivery queue when a channel becomes
/// available.
///
/// Lifecycle: instantiate once at app boot (or lazily when the first
/// transport registers), then call [onChannelAvailable] from the
/// transport-availability observer. The class is stateless beyond its
/// dependencies — calling `onChannelAvailable()` repeatedly is safe;
/// already-sent records are skipped on the next call.
class VaultSendOnConnect {
  /// Source of pending records (list / decrypt / mark-sent).
  final VaultSendSource source;

  /// Transport to dispatch on. We always check [Transport.isAvailable]
  /// before draining, so it's safe to register this with a transport
  /// whose availability flips over time.
  final Transport transport;

  /// Sealed-by-recipient encryptor (Ticket #13 in production).
  final DirectMessageEncryptor encryptor;

  /// Stable pseudonymous id of THIS device. Put into every outgoing
  /// envelope as `senderId` so the recipient knows who delivered the
  /// evidence.
  final String senderId;

  VaultSendOnConnect({
    required this.source,
    required this.transport,
    required this.encryptor,
    required this.senderId,
  });

  /// Drain everything currently queued for [recipientId]. Convenience
  /// overload — useful for "send this specific record NOW" UI actions.
  Future<void> onRecipientAvailable(String recipientId) async {
    await _drain(onlyRecipient: recipientId);
  }

  /// Drain everything queued, period. Called when "any channel" becomes
  /// available (the §18 #6 success criterion).
  Future<void> onChannelAvailable() async {
    await _drain();
  }

  Future<void> _drain({String? onlyRecipient}) async {
    if (!transport.isAvailable()) return;

    final pending = await source.listPendingForDelivery();
    final filtered = onlyRecipient == null
        ? pending
        : pending.where((p) => p.recipientId == onlyRecipient).toList();

    for (final record in filtered) {
      await _deliverOne(record);
    }
  }

  Future<void> _deliverOne(PendingVaultRecord record) async {
    Uint8List plaintext;
    try {
      plaintext = await source.decrypt(record);
    } catch (_) {
      // Auth failure / key mismatch — the record is unreadable. Leave
      // it in 'pending' for a future manual recovery; don't abort the
      // rest of the queue.
      return;
    }

    DirectEncryptedPayload encrypted;
    try {
      encrypted = await encryptor.encryptForRecipient(
        recipientId: record.recipientId,
        plaintext: plaintext,
      );
    } catch (_) {
      // Ratchet state missing for this recipient (e.g. never paired).
      // Skip without touching status; the user will need to re-pair.
      return;
    }

    final msg = Message.create(
      mode: MessageMode.direct,
      type: MessageType.evidenceNotice,
      channelId: '',
      senderId: senderId,
      recipientId: record.recipientId,
      payload: encrypted.ciphertext,
      ratchetHeader: encrypted.ratchetHeader,
    );

    try {
      await transport.send(msg);
    } catch (_) {
      // Transport rejected the send (no coverage, peer lost, etc.).
      // Leave the row in 'pending' — the next `onChannelAvailable()`
      // will retry. Critically, do NOT mark it as sent.
      return;
    }

    // Transport accepted the bytes — flip status to 'sent'. We do this
    // AFTER the send so a crash mid-send leaves the record retryable.
    try {
      await source.markSent(record.id);
    } catch (_) {
      // The transport has the message; the DB update failed. The row
      // will be re-delivered next time, which produces a duplicate
      // envelope — the recipient's seen-cache dedup (Ticket #09) will
      // drop the dup. Acceptable trade-off for at-least-once delivery.
    }
  }
}