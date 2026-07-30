// RelayLink — Ticket #28: DIRECT-over-SMS adapter.
//
// When the user sends a DIRECT message and the device has no mesh
// peer or internet, but DOES have a phone number on file for the
// recipient (Ticket #40), we fall back to dispatching the message
// over SMS: encrypted (already, by the time it reaches us — see [Message.ratchetHeader]
// + [Message.payload]) before being fragmented and pushed through the
// platform SMS channel.
//
// **Important:** This adapter does NOT encrypt. Encryption is the job of
// the DirectSession (Ticket #13) that the caller has already used. The
// adapter's contract is:
//
//   1. The incoming Message must be `mode == DIRECT` (else skipped).
//   2. The Message must have a `recipientId` and the contacts store
//      must have a phone number for that recipient (else skipped).
//   3. The radio must be available (Android + permission; not iOS —
//      else skipped).
//   4. The Message's `payload` (already ciphertext+tag from DirectSession)
//      is what goes on the wire.
//   5. The Message's `ratchet_header` is sent alongside as a separate
//      piece (or encoded into the framing envelope — see #24/#25 which
//      will refine this).
//
// **Status / scope notes (DO NOT LOSE):**
//   * Ticket #28 only owns the "send" path for DIRECT-over-SMS.
//     Reassembly is Ticket #25 (not yet built in this branch) — when it
//     lands, the receive path is `SmsTransport.incoming`, which will
//     call DirectSession.open() on the reassembled bytes using the
//     recipient's session state.
//   * The framing helper used here is the test-only one in
//     `test/test_helpers/framing_helper.dart`. When #24 lands, swap
//     it for the production `fragment(messageId, ciphertext, maxLen)`.
//   * The message-id used for fragmentation is the Message.id (already
//     a UUIDv4); we take its first 8 chars as the SMS msgid per #24.
//
// **Future coordination:** when #27 (BROADCAST fan-out) lands, it can
// share the same `SmsDispatchSink` — i.e., we extract the "look up
// phone → fragment → call sendSms" sequence into a private function so
// both adapters can reuse it.

import 'dart:typed_data';

import '../contacts/contacts_lookup.dart';
import '../models/message.dart';
import '../sms/framing.dart';
import '../sms/platform_channel.dart';

/// Outcome of a single `dispatch` call. Models the four ways this
/// adapter can fail a DIRECT-over-SMS send, plus the success case.
enum DirectDispatchOutcome {
  /// Message was successfully fragmented + sent via the SMS radio.
  sent,

  /// The Message was not a DIRECT message — wrong adapter. Fan-out
  /// logic in `TransportManager` should never call us for a BROADCAST.
  /// This is an assert-level error: log and skip.
  skippedWrongMode,

  /// The recipient's device-id is not in the contacts store.
  /// Caller should keep the message in its outbox for a later
  /// transport (mesh / internet).
  skippedUnknownRecipient,

  /// The recipient is in the contacts store but no phone number has
  /// been set yet. Caller should keep the message in its outbox.
  skippedNoPhone,

  /// The SMS radio reported unavailable (no SIM, iOS, permission
  /// denied, no carrier coverage, etc.). Caller should keep the
  /// message in its outbox.
  skippedRadioUnavailable,

  /// Fragmentation + dispatch threw an unexpected error. Caller
  /// should retry on the next transport tick.
  failed,
}

/// Result of `dispatch`. Includes a human-readable reason string for
/// logging; tests assert on [outcome].
class DirectDispatchResult {
  final DirectDispatchOutcome outcome;
  final String reason;
  final int fragmentCount;

  const DirectDispatchResult({
    required this.outcome,
    required this.reason,
    required this.fragmentCount,
  });

  @override
  String toString() =>
      'DirectDispatchResult(outcome=$outcome, reason="$reason", '
      'fragmentCount=$fragmentCount)';
}

/// Abstract hook for invoking the platform SMS channel.
///
/// Tests pass a recording fake. Production callers instantiate the
/// adapter with a closure that delegates to [SmsPlatformChannel] (or
/// to whatever the future Ticket #26 — the SMS transport — exposes).
typedef SmsDispatchFn = Future<bool> Function(String phoneNumber, String body);

/// Check that returns `true` when the SMS radio is available
/// (carrier coverage + permission on Android; always `false` on iOS).
/// Injected so the adapter is testable without a platform channel.
typedef IsRadioAvailableFn = bool Function();

/// Adapter that routes a DIRECT [Message] over SMS to a recipient whose
/// phone number is on file in the [ContactsLookup].
///
/// The adapter is deliberately narrow: one `dispatch` call covers one
/// outbound message. Future #26 (SMS transport) is expected to invoke
/// this from `send()` when the message is DIRECT and the recipient
/// has a phone number; the BROADCAST fan-out (#27) is a separate path
/// with its own dispatch loop.
class DirectSmsAdapter {
  final SmsDispatchFn _sendSms;
  final ContactsLookup _contacts;
  final IsRadioAvailableFn _isRadioAvailable;

  /// Construct the adapter against explicit dependencies. Tests use a
  /// recording `_sendSms` and an [InMemoryContactsStore]. Production
  /// code wires the real [SmsPlatformChannel] in #26.
  DirectSmsAdapter({
    required SmsDispatchFn smsChannel,
    required this._contacts,
    required this._isRadioAvailable,
  }) : _sendSms = smsChannel;

  /// Factory wiring the adapter to a real [SmsPlatformChannel]
  /// (Ticket #23) and the unavailability check that consults the
  /// platform's own `isAvailable` plus an optional permissions table.
  ///
  /// Use this from #26 (`SmsTransport`). For tests use the constructor
  /// directly with fakes.
  factory DirectSmsAdapter.fromPlatformChannel({
    required SmsPlatformChannel channel,
    required ContactsLookup contacts,
  }) {
    return DirectSmsAdapter(
      smsChannel: channel.sendSms,
      contacts: contacts,
      isRadioAvailable: () => channel.isAvailable,
    );
  }

  /// Dispatch one DIRECT [Message] over SMS. Idempotency: re-dispatching
  /// the same message will produce fresh fragments (different SMS
  /// ids) — duplicates are deduped on the receive side by the
  /// seen-cache (#26).
  Future<DirectDispatchResult> dispatch(Message msg) async {
    if (msg.mode != MessageMode.direct) {
      return const DirectDispatchResult(
        outcome: DirectDispatchOutcome.skippedWrongMode,
        reason: 'DIRECT-SMS adapter only handles DIRECT messages',
        fragmentCount: 0,
      );
    }
    if (msg.recipientId == null || msg.recipientId!.isEmpty) {
      return const DirectDispatchResult(
        outcome: DirectDispatchOutcome.skippedUnknownRecipient,
        reason: 'Message has no recipientId',
        fragmentCount: 0,
      );
    }
    if (!_isRadioAvailable()) {
      return const DirectDispatchResult(
        outcome: DirectDispatchOutcome.skippedRadioUnavailable,
        reason: 'SMS radio not available (iOS, no SIM, no permission, no coverage)',
        fragmentCount: 0,
      );
    }

    final contact = _contacts.lookupByDeviceId(msg.recipientId!);
    if (contact == null) {
      return DirectDispatchResult(
        outcome: DirectDispatchOutcome.skippedUnknownRecipient,
        reason: 'No contact paired for recipientId=${msg.recipientId}',
        fragmentCount: 0,
      );
    }
    final phone = contact.phoneNumber;
    if (phone == null || phone.isEmpty) {
      return DirectDispatchResult(
        outcome: DirectDispatchOutcome.skippedNoPhone,
        reason:
            'Contact ${contact.deviceId} (${contact.displayName}) has no phone number',
        fragmentCount: 0,
      );
    }

    // Concatenate the ratchet header + the ciphertext+tag payload into
    // a single byte string. The production `fragment(...)` from #24
    // base64-encodes its input on the way out, so the wire payload is
    // `RL:<msgid>:<idx>/<total>:<base64-of-blob>`. The receiver reverses
    // the base64 once to recover this concatenated blob, then splits
    // off the leading DirectHeader.wireSize bytes to feed DirectSession.open.
    final headerBytes = msg.ratchetHeader;
    final payloadBytes = msg.payload;
    if (headerBytes == null) {
      // DIRECT messages without a ratchet_header are the very first
      // message in a session where we haven't run a header yet — but
      // HKDF-chain requires a header on every message, so this is an
      // error case.
      return const DirectDispatchResult(
        outcome: DirectDispatchOutcome.failed,
        reason: 'DIRECT message has no ratchet_header',
        fragmentCount: 0,
      );
    }

    final blob = Uint8List(headerBytes.length + payloadBytes.length)
      ..setRange(0, headerBytes.length, headerBytes)
      ..setRange(
        headerBytes.length,
        headerBytes.length + payloadBytes.length,
        payloadBytes,
      );

    final fragments = SmsFraming.fragment(
      messageId: _shortMsgid(msg.id),
      payload: blob,
    );

    var sent = 0;
    for (final piece in fragments) {
      try {
        final ok = await _sendSms(phone, piece.body);
        if (!ok) {
          return DirectDispatchResult(
            outcome: DirectDispatchOutcome.failed,
            reason: 'sendSms returned false on fragment $sent/${
                fragments.length
            }',
            fragmentCount: sent,
          );
        }
        sent++;
      } catch (e) {
        return DirectDispatchResult(
          outcome: DirectDispatchOutcome.failed,
          reason: 'sendSms threw on fragment $sent/${fragments.length}: $e',
          fragmentCount: sent,
        );
      }
    }

    return DirectDispatchResult(
      outcome: DirectDispatchOutcome.sent,
      reason: 'Sent ${fragments.length} fragments to $phone',
      fragmentCount: fragments.length,
    );
  }

  // ---------------------------------------------------------------------------
  // In-house framing helper. Mirrors what `test/test_helpers/framing_helper.dart`
  // does for tests. When #24 lands, replace this with the production
  // `fragment(messageId, ciphertext, maxSegmentLen)` call from
  // `lib/sms/framing.dart`. We deliberately don't depend on #24 today
  // because #24 is part of the SMS-Blocker's dependency chain and is
  // not landed in this worktree (per the missing-upstream-dependency
  // note at the top of this file).
  // ---------------------------------------------------------------------------

  static String _shortMsgid(String uuid) {
    // First 8 alphanumerics of the identifier, lowercased. The UUID is
    // 36 chars (with dashes); tests use shorter strings like 'msg-1'
    // which we right-pad with '0' so the header rule is always met.
    final compact = uuid.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toLowerCase();
    if (compact.length >= 8) return compact.substring(0, 8);
    return (compact + '0' * 8).substring(0, 8);
  }
}
