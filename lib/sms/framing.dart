// RelayLink — SMS segmentation (Ticket #24).
//
// Splits an outgoing ciphertext payload into a sequence of SMS-sized
// segments and reassembles inbound segments back into the original bytes.
// Used by the SMS transport leg of the broadcast fan-out and direct
// message paths (SPEC.md §9).
//
// ---------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------
//
//   segment := "RL:" messageId ":" index "/" total ":" base64Chunk
//
//   - "RL:" — 3-byte app prefix (RelayLink).
//   - messageId — exactly 8 hex characters. Maps to the first 8 hex chars of
//     the underlying Message.id (a UUIDv4). This is the only piece of
//     routing metadata carried in-fragment; longer ID prefixes are unsafe
//     across multi-segment headers.
//   - index / total — 1-based; `index` in [1, total]; `total` in [1, 999].
//   - base64Chunk — chunk of the FULLY base64-encoded payload. Each segment
//     carries a whole, contiguous base64 substring. This is the
//     "iterative whole-payload Base64 fragmentation" approach: the entire
//     payload is base64-encoded once, then the resulting string is split
//     into chunks that fit within the segment length budget. Reassembly
//     is a simple split-join-decode — no per-segment padding arithmetic.
//
// ---------------------------------------------------------------------------
// Segment length math (GSM-7 vs UCS-2)
// ---------------------------------------------------------------------------
//
// SMS segment-length limits depend on the alphabet the carrier uses:
//   * GSM-7  (default 7-bit alphabet) — 160 chars per segment
//   * UCS-2  (any non-GSM-7 character, e.g. emoji) — 70 chars per segment
//
// `SmsFraming.gsm7MaxChars` and `SmsFraming.ucs2MaxChars` pin those two
// well-known limits. We never carry arbitrary user text in the header, so
// the header itself is pure ASCII and the relevant limit is GSM-7 (160).
// Real carriers also concatenate multi-part SMS with a 6-byte UDH that
// reduces the per-segment payload by ~7 chars, leaving ~153 usable chars;
// some carriers add further overhead for routing/high-water marks.
//
// To avoid surprises across carriers, `defaultSegmentLength` is 140 —
// 20 chars below the GSM-7 limit — leaving comfortable headroom for any
// per-carrier UDH or routing overhead. The whole point is that the
// *application* shouldn't have to know about carrier variance.
//
// This default is configurable via `segmentLength` on `fragment()` and
// via `detectSegmentLimit(segmentLimit: ...)`. Callers that have measured
// real carrier behavior may pass a tighter limit if they want to maximize
// per-segment payload; callers that don't know should leave the default.

import 'dart:convert';
import 'dart:typed_data';

import 'package:relaylink/sms/exceptions.dart';

/// One parsed SMS fragment.
class SmsFragment {
  /// 8-hex-char message ID parsed from the segment header.
  final String messageId;

  /// 1-based segment index.
  final int index;

  /// Total segment count for this message ID.
  final int total;

  /// Full segment body, including the `RL:...` header. This is what the
  /// transport hands to `SmsPlatformChannel.sendSms`.
  final String body;

  const SmsFragment({
    required this.messageId,
    required this.index,
    required this.total,
    required this.body,
  });
}

/// Top-level wrapper around [SmsFraming.detectSegmentLimit] for callers
/// that prefer a function form.
int detectSegmentLimit({int? segmentLimit}) =>
    SmsFraming.detectSegmentLimit(segmentLimit: segmentLimit);

/// SMS segment sizing constants and the fragmenter/assembler surface.
class SmsFraming {
  // Prevent instantiation — this is a namespace, not a stateful object.
  const SmsFraming._();

  // ---------------------------------------------------------------------------
  // Segment-length constants
  // ---------------------------------------------------------------------------

  /// GSM-7 (single-segment) maximum body length, in characters.
  ///
  /// 160 is the well-known default for the GSM 7-bit default alphabet
  /// when no UDH is present. Some carriers' multi-part UDH steals 7 chars,
  /// effectively making the per-segment payload 153.
  static const int gsm7MaxChars = 160;

  /// UCS-2 (single-segment) maximum body length, in characters.
  ///
  /// 70 because any character outside the GSM-7 alphabet (e.g. emoji, many
  /// non-Latin scripts) swaps the encoding to UCS-2 and halves the cap.
  static const int ucs2MaxChars = 70;

  /// Safe default segment length for `fragment()`.
  ///
  /// 140 chars — 20 below the GSM-7 limit — leaves headroom for any
  /// carrier-side UDH or routing overhead without the application needing
  /// to know carrier-specific details.
  static const int defaultSegmentLength = 140;

  /// Maximum total-segment count (`total` field) we accept.
  ///
  /// 999 keeps the header well within the documented 1-3 digit range and
  /// rejects impossible / malicious claims that would force oversized
  /// pre-allocations.
  static const int maxTotalSegments = 999;

  /// Minimum segment length required to carry a header + at least one
  /// base64 character of payload.
  static const int minSegmentLength = 24;

  /// Length of the message ID portion of the header (hex chars).
  static const int messageIdLength = 8;

  /// Header prefix length: `RL:` (3) + 8 hex + `:` (1) + idx + `/` + total + `:`.
  ///
  /// Worst case (3-digit idx, 3-digit total): `3 + 8 + 1 + 3 + 1 + 3 + 1 = 20`.
  static const int headerOverheadMin = 20;

  // ---------------------------------------------------------------------------
  // Detection
  // ---------------------------------------------------------------------------

  /// Returns the segment length to use, validating it against the
  /// minimum-allowed length for the protocol.
  ///
  /// `segmentLimit` is the platform-provided or operator-overridden limit
  /// (defaults to [defaultSegmentLength]). The function validates that the
  /// chosen limit can accommodate at least the header overhead plus one
  /// base64 character of payload.
  static int detectSegmentLimit({int? segmentLimit}) {
    final limit = segmentLimit ?? defaultSegmentLength;
    if (limit < minSegmentLength) {
      throw SmsFramingException(
        'segment limit $limit is below the minimum '
        '$minSegmentLength chars required to carry header + payload',
      );
    }
    return limit;
  }

  // ---------------------------------------------------------------------------
  // Fragmenting
  // ---------------------------------------------------------------------------

  /// Splits [payload] into a list of segments formatted as
  /// `RL:<msgid>:<idx>/<total>:<base64-chunk>`.
  ///
  /// - `messageId` must be exactly 8 hex characters (the first 8 hex chars
  ///   of `Message.id` are a common source).
  /// - `payload` must be non-empty (callers that have no payload should
  ///   skip SMS entirely).
  /// - `segmentLength` defaults to [defaultSegmentLength] (140). The check
  ///   `segmentLength >= minSegmentLength` is enforced.
  static List<SmsFragment> fragment({
    required String messageId,
    required Uint8List payload,
    int? segmentLength,
  }) {
    _validateMessageId(messageId);
    if (payload.isEmpty) {
      throw const SmsFramingException(
        'cannot fragment an empty payload — skip SMS for empty messages',
      );
    }
    final limit = detectSegmentLimit(segmentLimit: segmentLength);
    final bodyBudget = limit - headerOverheadMin;

    // Iterative whole-payload Base64 fragmentation: encode the whole
    // payload once, then split the base64 string into chunks that fit
    // within the remaining space.
    final encoded = base64.encode(payload);
    final chunks = _splitIntoChunks(encoded, bodyBudget);

    if (chunks.length > maxTotalSegments) {
      throw SmsFramingException(
        'payload splits into $chunks.length segments, exceeding '
        'maxTotalSegments=$maxTotalSegments at segmentLength=$limit',
      );
    }

    final total = chunks.length;
    return [
      for (var i = 0; i < chunks.length; i++)
        SmsFragment(
          messageId: messageId,
          index: i + 1, // 1-based
          total: total,
          body: 'RL:$messageId:${i + 1}/$total:${chunks[i]}',
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  /// Parses a single received segment string into an [SmsFragment].
  ///
  /// Throws [SmsFramingException] if the segment is malformed:
  /// missing `RL:` prefix, bad message ID, non-numeric idx/total,
  /// 0-based index, index > total, body too short, etc.
  static SmsFragment parseSegment(String segment) {
    if (!segment.startsWith('RL:')) {
      throw SmsFramingException('segment missing "RL:" prefix: $segment');
    }
    // Strip the "RL:" prefix.
    final rest = segment.substring(3);
    // Find the messageId colon — appears immediately after the 8 hex chars.
    if (rest.length < messageIdLength) {
      throw SmsFramingException('segment too short to carry messageId: $segment');
    }
    final id = rest.substring(0, messageIdLength);
    _validateMessageId(id);
    final afterId = rest.substring(messageIdLength);
    if (afterId.isEmpty || afterId[0] != ':') {
      throw SmsFramingException('segment missing ":" after messageId: $segment');
    }
    final afterIdColon = afterId.substring(1);
    final slashIdx = afterIdColon.indexOf('/');
    if (slashIdx <= 0) {
      throw SmsFramingException('segment missing "/" between idx and total: $segment');
    }
    final colonIdx = afterIdColon.indexOf(':');
    if (colonIdx < slashIdx || colonIdx == slashIdx + 1) {
      throw SmsFramingException('segment missing ":" before body: $segment');
    }
    final idxStr = afterIdColon.substring(0, slashIdx);
    final totalStr = afterIdColon.substring(slashIdx + 1, colonIdx);
    final body = afterIdColon.substring(colonIdx + 1);

    final index = int.tryParse(idxStr);
    final total = int.tryParse(totalStr);
    if (index == null || total == null) {
      throw SmsFramingException(
        'segment has non-numeric idx/total: idx="$idxStr" total="$totalStr"',
      );
    }
    if (index < 1) {
      throw SmsFramingException('segment index must be 1-based: $index');
    }
    if (total < 1) {
      throw SmsFramingException('segment total must be >= 1: $total');
    }
    if (index > total) {
      throw SmsFramingException(
        'segment index $index exceeds total $total',
      );
    }
    if (total > maxTotalSegments) {
      throw SmsFramingException(
        'segment total $total exceeds maxTotalSegments=$maxTotalSegments',
      );
    }
    if (body.isEmpty) {
      throw SmsFramingException(
        'segment body is empty (or separator missing): $segment',
      );
    }

    return SmsFragment(
      messageId: id,
      index: index,
      total: total,
      body: segment,
    );
  }

  // ---------------------------------------------------------------------------
  // Reassembly
  // ---------------------------------------------------------------------------

  /// Reassembles a list of [SmsFragment]s into the original ciphertext.
  ///
  /// - Segments are accepted in any order; the function sorts by index.
  /// - Duplicates (same `messageId` + `index`) are silently deduped.
  /// - All segments must carry the same `messageId` and `total`.
  /// - Indices `1..total` must all be present.
  /// - The concatenated base64 string must decode cleanly.
  static Uint8List assemble(List<SmsFragment> fragments) {
    if (fragments.isEmpty) {
      throw const SmsFramingException('cannot assemble from empty fragment list');
    }

    // Sort + dedup by (messageId, index), keeping the first occurrence.
    final byIndex = <int, SmsFragment>{};
    String? expectedId;
    int? expectedTotal;
    for (final frag in fragments) {
      if (expectedId == null) {
        expectedId = frag.messageId;
      } else if (frag.messageId != expectedId) {
        throw SmsFramingException(
          'fragment messageId mismatch: expected $expectedId, '
          'got ${frag.messageId}',
        );
      }
      if (expectedTotal == null) {
        expectedTotal = frag.total;
      } else if (frag.total != expectedTotal) {
        throw SmsFramingException(
          'fragment total mismatch for $expectedId: expected '
          '$expectedTotal, got ${frag.total}',
        );
      }
      // First occurrence wins; duplicates are silently deduped.
      byIndex.putIfAbsent(frag.index, () => frag);
    }

    final total = expectedTotal!;
    if (byIndex.length != total) {
      final missing = <int>[];
      for (var i = 1; i <= total; i++) {
        if (!byIndex.containsKey(i)) missing.add(i);
      }
      throw SmsFramingException(
        'missing fragments for $expectedId: $missing',
      );
    }

    // Indices are 1-based; strip the header from each fragment body to
    // get the base64 chunk, then concatenate in order.
    final sorted = [for (var i = 1; i <= total; i++) byIndex[i]!];
    final joined = StringBuffer();
    for (final frag in sorted) {
      // Strip the header: "RL:<id>:<idx>/<total>:" → chunks.
      final body = _bodyChunk(frag);
      joined.write(body);
    }

    try {
      return base64.decode(joined.toString());
    } on FormatException catch (e) {
      throw SmsFramingException(
        'assembled base64 is invalid for $expectedId: ${e.message}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static void _validateMessageId(String id) {
    if (id.length != messageIdLength) {
      throw SmsFramingException(
        'messageId must be exactly $messageIdLength hex chars, '
        'got ${id.length}: $id',
      );
    }
    for (var i = 0; i < messageIdLength; i++) {
      final c = id.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39; // 0-9
      final isLowerHex = c >= 0x61 && c <= 0x66; // a-f
      final isUpperHex = c >= 0x41 && c <= 0x46; // A-F
      if (!isDigit && !isLowerHex && !isUpperHex) {
        throw SmsFramingException(
          'messageId must be 8 hex chars (0-9, a-f, A-F), got: $id',
        );
      }
    }
  }

  static List<String> _splitIntoChunks(String s, int chunkSize) {
    if (chunkSize <= 0) {
      throw const SmsFramingException('chunk size must be positive');
    }
    final chunks = <String>[];
    for (var i = 0; i < s.length; i += chunkSize) {
      final end = i + chunkSize;
      chunks.add(s.substring(i, end > s.length ? s.length : end));
    }
    return chunks;
  }

  static String _bodyChunk(SmsFragment frag) {
    // Format: "RL:<id>:<idx>/<total>:<chunk>". The chunk is whatever comes
    // after the third colon.
    final rest = frag.body.substring(3); // drop "RL:"
    // Skip "id:idx/total:" — find the third colon.
    final idEnd = messageIdLength + 1; // id + first colon
    final restAfterId = rest.substring(idEnd);
    final colonIdx = restAfterId.indexOf(':');
    if (colonIdx < 0) {
      throw SmsFramingException(
        'fragment body missing payload separator: ${frag.body}',
      );
    }
    return restAfterId.substring(colonIdx + 1);
  }
}
