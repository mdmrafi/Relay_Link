// RelayLink — Ticket #27: SMS BROADCAST fan-out to contacts.
//
// Fans out an encrypted BROADCAST message to every contact with a phone
// number on file, in parallel, without failing the whole fan-out when a
// single recipient errors.
//
// Design notes:
//   * The payload is BROADCAST-encrypted once (network-key / custom-channel
//     key — see lib/crypto/broadcast.dart) and the same ciphertext is
//     delivered to every recipient. Per-recipient wrapping would defeat
//     the network-key design (SPEC.md §6.2 / ticket #03); recipients
//     share the symmetric key.
//   * Fragmentation is integrated *when available*. When Ticket #24's
//     `lib/sms/framing.dart` is present, callers should pass a
//     [FanoutFragmenter] produced by `Framing.fragments(...)` so long
//     messages can ride multiple SMS segments. When the framing module
//     is not yet present, callers can pass [SingleSegmentFragmenter]
//     (the default) and the payload is delivered as one base64-encoded
//     segment per recipient. This keeps the seam small while letting
//     future work drop in real fragmentation without a refactor.
//   * Per-recipient failures are logged and recorded in
//     [FanoutResult.perRecipient]. The whole fan-out completes regardless.
//   * Contacts with no phone number are silently skipped (they may be
//     reached via mesh or DIRECT crypto — this is the SMS leg only).
//   * Duplicate phone numbers across contacts collapse to one send. This
//     is the user-visible dedup the ticket asks for: if two contacts
//     share "+1555...100", the fan-out sends once, not twice.
//
// Honesty note (per the ticket brief):
//   This module drives the platform `SmsManager` channel via
//   [SmsPlatformChannel]. Whether a real device SMS is actually sent
//   depends on native permissions, the device's telephony subsystem, and
//   the carrier — none of which are exercised in unit tests. Tests cover
//   the fan-out *behavior* (recipient selection, dedup, parallelization,
//   per-recipient error isolation, same-payload invariant); a real
//   "device A fan-outs SOS, three physical devices receive and decrypt"
//   demo requires three Android phones with SIMs and is out of scope
//   here.

import 'dart:async';
import 'dart:convert';

import '../contacts/contact.dart';
import '../models/message.dart';
import 'fanout_types.dart';
import 'platform_channel.dart';

// ---------------------------------------------------------------------------
// Fragmenter seam
// ---------------------------------------------------------------------------

/// Pluggable fragmentation strategy for SMS fan-out.
///
/// Implementations take the full payload bytes and the message id, and
/// return the ordered list of segment strings that should be sent in
/// order to one recipient. The fan-out sends each segment in order, then
/// moves on to the next recipient. Reassembly on the receiver side is the
/// reassembler's job (see Ticket #25); this module only emits segments.
abstract class FanoutFragmenter {
  /// Splits [payload] for [messageId] into SMS segment bodies.
  ///
  /// For multi-segment messages, the first element is the segment sent
  /// first; the reassembler expects them in this order (or tolerates any
  /// order if Ticket #25's reassembler is order-independent).
  Future<List<String>> fragments(String messageId, List<int> payload);
}

/// Default fragmenter used when the caller doesn't supply one.
///
/// Sends the base64 payload in one segment, with no `RL:` header — i.e.
/// it assumes the carrier's single-SMS length budget is enough.
/// Acceptable only for small messages (control messages, ACKs, short
/// statuses). For real BROADCAST fan-out in production, callers should
/// pass a [FanoutFragmenter] backed by Ticket #24's `framing.dart`.
class SingleSegmentFragmenter implements FanoutFragmenter {
  const SingleSegmentFragmenter();

  @override
  Future<List<String>> fragments(String messageId, List<int> payload) async {
    // Base64 (not raw bytes) so the body is safe to ship as a 7-bit GSM
    // SMS. The fan-out itself doesn't know how the receiver will decode;
    // that's the reassembler's contract.
    return <String>[base64.encode(payload)];
  }
}

/// Fragmenter adapter for Ticket #24's `lib/sms/framing.dart`.
///
/// The constructor takes the framing module's `fragment(...)` function
/// directly so this module does not have a hard `import` on `framing.dart`
/// (which may not yet be landed in every worktree). Callers wire the
/// adapter like:
///
/// ```dart
/// final framing = await import('package:relaylink/sms/framing.dart');
/// final fanout = RealFramingFragmenter(framing.fragment);
/// ```
///
/// If `framing.dart` is not present at runtime, callers should leave
/// [fragmenter] null and accept [SingleSegmentFragmenter].
class RealFramingFragmenter implements FanoutFragmenter {
  /// Function with the same signature as `Framing.fragment(messageId,
  /// ciphertext, {maxSegmentLen})` from Ticket #24. We type it as a plain
  /// function so the binding site doesn't need to import the framing
  /// module statically.
  final Future<List<String>> Function(
    String messageId,
    List<int> payload, {
    int? maxSegmentLen,
  }) _impl;

  RealFramingFragmenter(this._impl);

  @override
  Future<List<String>> fragments(String messageId, List<int> payload) =>
      _impl(messageId, payload);
}

// ---------------------------------------------------------------------------
// Fan-out
// ---------------------------------------------------------------------------

/// Fans out [msg] (a BROADCAST message whose `payload` is the
/// channel-encrypted ciphertext — see Ticket #03) to every contact with a
/// phone number on file.
///
/// [contacts] is filtered to entries with [Contact.hasPhone] == true,
/// then deduplicated by phone number so a single number shared by two
/// contacts only fires one send. The dispatch is parallelized via
/// [Future.wait] so wall-clock time is bounded by the slowest recipient.
///
/// Per-recipient failures are caught, logged, and recorded in
/// [FanoutResult.perRecipient] but do not abort the fan-out. Returns a
/// [FanoutResult] summarising attempted/anySuccess/perRecipient/elapsed.
///
/// [transport] is the SMS dispatch backend (typically a wrapper around
/// [SmsPlatformChannel]). [fragmenter] defaults to
/// [SingleSegmentFragmenter]; pass a [RealFramingFragmenter] backed by
/// Ticket #24 when the framing module is available. [logger] defaults to
/// a console-print sink — pass a no-op (`(_) {}`) in tests to keep output
/// clean. [now] is a clock injection used by tests; production code lets
/// it default to `DateTime.now`.
///
/// Pre-conditions:
///   * [msg.mode] == [MessageMode.broadcast]. Direct messages must use
///     per-recipient Double Ratchet (#13) and a different fan-out path;
///     this function asserts.
Future<FanoutResult> fanOutBroadcast(
  Message msg,
  List<Contact> contacts, {
  required SmsFanoutTransport transport,
  FanoutFragmenter? fragmenter,
  FanoutLogger? logger,
  DateTime Function()? now,
}) async {
  final log = logger ?? defaultFanoutLogger;
  final clock = now ?? DateTime.now;
  final frag = fragmenter ?? const SingleSegmentFragmenter();

  // Sanity: this function is for BROADCAST only.
  if (msg.mode != MessageMode.broadcast) {
    throw ArgumentError(
      'fanOutBroadcast called with mode=${msg.mode.toJson()}; '
      'expected BROADCAST. Direct messages use per-recipient ratchet.',
    );
  }

  // Transport gate: if SMS is unavailable, skip cleanly.
  if (!transport.isAvailable) {
    log('transport unavailable; fan-out skipped (msg.id=${msg.id})');
    return FanoutResult(
      anySuccess: false,
      attempted: 0,
      perRecipient: const <FanoutRecipientResult>[],
      elapsed: Duration.zero,
    );
  }

  // Recipient selection: filter to phone-bearing contacts.
  final withPhone = contacts.where((c) => c.hasPhone).toList(growable: false);

  // Dedup by phone number, preserving first occurrence.
  // Two contacts sharing a phone is a real scenario: a single person
  // listed twice (different display names) or a household that maps to
  // the same line. We send once per number.
  final deduped = <String, _Recipient>{};
  for (final c in withPhone) {
    final phone = c.phoneNumber!.trim();
    deduped.putIfAbsent(phone, () => _Recipient(c, phone));
  }

  if (deduped.isEmpty) {
    log(
      'no phone-bearing contacts; fan-out is a no-op '
      '(contacts=${contacts.length}, msg.id=${msg.id})',
    );
    return FanoutResult(
      anySuccess: false,
      attempted: 0,
      perRecipient: const <FanoutRecipientResult>[],
      elapsed: Duration.zero,
    );
  }

  // Fragment the payload once. BROADCAST fan-out reuses the same
  // ciphertext for every recipient (network-key design — see header),
  // so we encode fragments exactly once and ship the same set to
  // every recipient. Per-recipient re-encoding would be wasted work
  // and would risk accidental divergence across recipients.
  final t0 = clock();
  final List<String> segments;
  try {
    segments = await frag.fragments(msg.id, msg.payload);
  } catch (e, st) {
    log('fragmentation failed; fan-out aborted: $e\n$st');
    return FanoutResult(
      anySuccess: false,
      attempted: deduped.length,
      perRecipient: deduped.values
          .map((r) => FanoutRecipientResult.failed(r.phone, e))
          .toList(growable: false),
      elapsed: clock().difference(t0),
    );
  }

  log(
    'fanning out msg.id=${msg.id} to ${deduped.length} recipient(s), '
    '${segments.length} segment(s) each',
  );

  // Parallel dispatch.
  final futures = deduped.values.map((r) async {
    try {
      // Per-segment dispatch in order. If any segment throws we stop
      // and surface the error — partial sends are acceptable (the
      // reassembler discards incomplete sets after 10 minutes, per #25).
      for (final seg in segments) {
        await transport.sendFragment(r.phone, seg);
      }
      return FanoutRecipientResult.ok(r.phone);
    } catch (e) {
      log('recipient ${r.phone} (${r.contact.displayName}) failed: $e');
      return FanoutRecipientResult.failed(r.phone, e);
    }
  }).toList(growable: false);

  final results = await Future.wait(futures);
  final elapsed = clock().difference(t0);
  final anySuccess = results.any((r) => r.success);

  log(
    'fan-out done: attempted=${results.length} anySuccess=$anySuccess '
    'elapsed=${elapsed.inMilliseconds}ms',
  );

  return FanoutResult(
    anySuccess: anySuccess,
    attempted: results.length,
    perRecipient: results,
    elapsed: elapsed,
  );
}

/// Internal: a contact paired with its normalized phone number.
class _Recipient {
  final Contact contact;
  final String phone;
  const _Recipient(this.contact, this.phone);
}

/// Adapter that lets a [SmsPlatformChannel] satisfy the
/// [SmsFanoutTransport] interface.
///
/// Calls the platform channel's `sendSms` for each fragment. Throws on
/// iOS (the platform channel does), on missing permission, or on a
/// carrier-side `send_failed` result (surfaced as a StateError).
class SmsPlatformChannelTransport implements SmsFanoutTransport {
  final SmsPlatformChannel _channel;

  SmsPlatformChannelTransport({SmsPlatformChannel? channel})
      : _channel = channel ?? SmsPlatformChannel();

  @override
  bool get isAvailable => _channel.isAvailable;

  @override
  Future<void> sendFragment(String phoneNumber, String body) async {
    final ok = await _channel.sendSms(phoneNumber, body);
    if (!ok) {
      throw StateError(
        'SmsManager returned false for $phoneNumber '
        '(body length=${body.length})',
      );
    }
  }
}
