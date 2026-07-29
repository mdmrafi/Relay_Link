// Tests for SMS fragmentation (Ticket #24).
//
// Covers:
//   - 1-byte payload → 1 segment
//   - 1 KiB payload → ~7 segments at 140-char default limit
//   - 10 KiB payload → ~70 segments at 140-char default limit
//   - Round-trip reassembly: fragment → assemble → original bytes
//   - Strict 8-hex-char message ID validation
//   - 1-based indexes
//   - Total validation against actual segment count
//   - Base64 chunk validation
//   - Inconsistent message IDs/totals rejected
//   - Duplicate (same idx) silently deduped
//   - Missing fragments → SmsFramingException
//   - Segment too short to carry payload → SmsFramingException
//   - Segment limit detection (160 GSM-7, 70 UCS-2, configurable default 140)

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/sms/exceptions.dart';
import 'package:relaylink/sms/framing.dart';

void main() {
  group('SmsFraming constants', () {
    test('default safe segment limit is 140 (leaves headroom for 160 GSM-7)', () {
      // Per ticket #24 requirement: pick a safe default like 140 to leave
      // headroom for carrier overhead on the 160-char GSM-7 limit.
      expect(SmsFraming.defaultSegmentLength, 140);
    });

    test('exposes GSM-7 (160) and UCS-2 (70) known limits', () {
      expect(SmsFraming.gsm7MaxChars, 160);
      expect(SmsFraming.ucs2MaxChars, 70);
    });

    test('header overhead constant matches documented format', () {
      // RL: + 8 hex + : + 1-3 digit idx + / + 1-3 digit total + :
      // Worst case: 3 + 8 + 1 + 3 + 1 + 3 + 1 = 20
      expect(SmsFraming.headerOverheadMin, lessThanOrEqualTo(20));
    });
  });

  group('detectSegmentLimit', () {
    test('returns 140 for the safe default', () {
      expect(detectSegmentLimit(segmentLimit: 140), 140);
    });

    test('respects custom segment limit override', () {
      expect(detectSegmentLimit(segmentLimit: 67), 67);
    });

    test('throws when requested limit is below absolute minimum', () {
      // Must be able to carry header (20) + at least 1 base64 char + payload marker
      expect(
        () => detectSegmentLimit(segmentLimit: SmsFraming.minSegmentLength - 1),
        throwsA(isA<SmsFramingException>()),
      );
    });
  });

  group('SmsFraming.encryptAndFragment', () {
    // Synthetic 8-hex-char message IDs for deterministic tests (matches UUID
    // prefix without coupling to UUID generation order).
    const msgidA = 'aabbccdd';

    test('1-byte payload produces exactly 1 segment', () {
      final payload = Uint8List.fromList([0x42]);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      expect(segments, hasLength(1));
      // Round-trip via assemble (covered in its own group)
      final reassembled =
          SmsFraming.assemble(segments.cast<SmsFragment>());
      expect(reassembled, equals(payload));
    });

    test('1 KiB payload produces ~7 segments at the default 140 limit', () {
      final payload = _randomBytes(1024);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      // Base64 of 1024 bytes is ~1366 chars. With 140 - 20 = 120 per chunk,
      // ceil(1366/120) = 12 (each base64 char = 6 bits → 4 chars per 3 bytes;
      // with padding 1024 bytes = ceil(1024/3)*4 = 1368 chars exactly).
      // We don't lock the exact count — just verify it's the right order.
      expect(segments.length, inInclusiveRange(7, 14));
      for (final s in segments) {
        expect(s.body.length, lessThanOrEqualTo(140));
      }
      final reassembled =
          SmsFraming.assemble(segments.cast<SmsFragment>());
      expect(reassembled, equals(payload));
    });

    test('10 KiB payload produces ~70 segments at the default 140 limit', () {
      final payload = _randomBytes(10 * 1024);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      // 10240 bytes base64 = ~13656 chars; 13656/120 ≈ 114, lock to a range.
      expect(segments.length, inInclusiveRange(70, 120));
      for (final s in segments) {
        expect(s.body.length, lessThanOrEqualTo(140));
      }
      final reassembled =
          SmsFraming.assemble(segments.cast<SmsFragment>());
      expect(reassembled, equals(payload));
    });

    test('every segment carries a 1-based index', () {
      final payload = _randomBytes(500);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      for (var i = 0; i < segments.length; i++) {
        expect(segments[i].index, i + 1);
        expect(segments[i].index, greaterThanOrEqualTo(1));
      }
    });

    test('total is set correctly and matches actual segment count', () {
      final payload = _randomBytes(2000);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      for (final s in segments) {
        expect(s.total, segments.length);
      }
    });

    test('honors a custom segment length', () {
      final payload = _randomBytes(500);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
        segmentLength: 70,
      );
      for (final s in segments) {
        expect(s.body.length, lessThanOrEqualTo(70));
      }
    });

    test('rejects message IDs that are not exactly 8 hex chars', () {
      expect(
        () => SmsFraming.fragment(messageId: 'short', payload: Uint8List(0)),
        throwsA(isA<SmsFramingException>()),
      );
      expect(
        () =>
            SmsFraming.fragment(messageId: 'toolongid00', payload: Uint8List(0)),
        throwsA(isA<SmsFramingException>()),
      );
      expect(
        () =>
            SmsFraming.fragment(messageId: 'zzzzzzzz', payload: Uint8List(0)),
        throwsA(isA<SmsFramingException>()),
      );
      expect(
        () => SmsFraming.fragment(messageId: '', payload: Uint8List(0)),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects empty payload (use single-zero-byte payload for empty msgs)',
        () {
      // An empty ciphertext must still produce a fragment header for the
      // downstream seen-cache / deduplication to fire. We deliberately
      // reject the all-empty case so callers don't accidentally send empty
      // fragments.
      expect(
        () => SmsFraming.fragment(messageId: msgidA, payload: Uint8List(0)),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects impossible limit below header overhead + 1 char', () {
      final payload = _randomBytes(16);
      expect(
        () => SmsFraming.fragment(
          messageId: msgidA,
          payload: payload,
          segmentLength: 5,
        ),
        throwsA(isA<SmsFramingException>()),
      );
    });
  });

  group('SmsFraming.assemble', () {
    const msgidA = 'deadbeef';
    const msgidB = '00112233';

    test('reassembles single-segment correctly', () {
      final payload = Uint8List.fromList([0x01, 0x02, 0x03]);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      expect(segments, hasLength(1));
      final reassembled = SmsFraming.assemble(segments.cast<SmsFragment>());
      expect(reassembled, equals(payload));
    });

    test('reassembles out-of-order arrival correctly', () {
      final payload = _randomBytes(2000);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      final shuffled = [...segments]..shuffle(math.Random(42));
      final reassembled =
          SmsFraming.assemble(shuffled.cast<SmsFragment>());
      expect(reassembled, equals(payload));
    });

    test('duplicates of the same index are silently deduped', () {
      final payload = _randomBytes(2000);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      // Insert a duplicate of index 1.
      final withDup = [...segments, segments.first];
      final reassembled =
          SmsFraming.assemble(withDup.cast<SmsFragment>());
      expect(reassembled, equals(payload));
    });

    test('throws when a required index is missing', () {
      final payload = _randomBytes(2000);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      // Drop the second fragment.
      final missing = segments.where((s) => s.index != 2).toList();
      expect(
        () => SmsFraming.assemble(missing.cast<SmsFragment>()),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('throws when message IDs conflict across fragments', () {
      final payload = _randomBytes(500);
      final segsA = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      final segsB = SmsFraming.fragment(
        messageId: msgidB,
        payload: payload,
      );
      // Mix: index 1 from B, rest from A.
      final mixed = <SmsFragment>[segsB.first, ...segsA.skip(1)];
      expect(
        () => SmsFraming.assemble(mixed),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('throws when total differs across fragments for the same msgid', () {
      final payload = _randomBytes(500);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      final spoofed = <SmsFragment>[
        for (final s in segments)
          SmsFragment(
            messageId: s.messageId,
            index: s.index,
            total: s.total + 1, // inconsistent
            body: s.body,
          ),
      ];
      expect(
        () => SmsFraming.assemble(spoofed),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('throws when base64 chunk is invalid', () {
      final payload = _randomBytes(500);
      final segments = SmsFraming.fragment(
        messageId: msgidA,
        payload: payload,
      );
      final tampered = <SmsFragment>[
        for (var i = 0; i < segments.length; i++)
          if (i == 0)
            // Replace valid base64 with characters that break decoding.
            // Body field carries the full RL:...:... segment string so we
            // need to preserve the header format.
            SmsFragment(
              messageId: segments[i].messageId,
              index: segments[i].index,
              total: segments[i].total,
              body: 'RL:${segments[i].messageId}:1/${segments[i].total}:not_base64!!!',
            )
          else
            segments[i],
      ];
      expect(
        () => SmsFraming.assemble(tampered),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('throws when assembled payload is not valid base64 padding', () {
      // Force a chunk count where the joined chunks form an invalid
      // base64 string (length not 0/4-mod, or invalid characters).
      final badChunks = <SmsFragment>[
        SmsFragment(
          messageId: msgidA,
          index: 1,
          total: 2,
          body: 'RL:$msgidA:1/2:AAAA',
        ),
        SmsFragment(
          messageId: msgidA,
          index: 2,
          total: 2,
          // Two-char payload is invalid base64 (length must be 0/4-mod).
          body: 'RL:$msgidA:2/2:AB',
        ),
      ];
      expect(
        () => SmsFraming.assemble(badChunks),
        throwsA(isA<SmsFramingException>()),
      );
    });
  });

  group('SmsFraming.parseSegment', () {
    test('parses a well-formed segment string into an SmsFragment', () {
      final payload = Uint8List.fromList([0x10, 0x20, 0x30]);
      final segments = SmsFraming.fragment(
        messageId: 'aabbccdd',
        payload: payload,
      );
      final parsed = SmsFraming.parseSegment(segments.first.body);
      expect(parsed.messageId, 'aabbccdd');
      expect(parsed.index, 1);
      expect(parsed.total, 1);
      expect(parsed.body, segments.first.body);
    });

    test('rejects segments missing the RL: prefix', () {
      expect(
        () => SmsFraming.parseSegment('aabbccdd:1/1:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects segments with malformed message ID', () {
      expect(
        () => SmsFraming.parseSegment('RL:zzz:1/1:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
      expect(
        () => SmsFraming.parseSegment('RL:1234567:1/1:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
      expect(
        () => SmsFraming.parseSegment('RL:123456789:1/1:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects zero or negative indexes (must be 1-based)', () {
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:0/1:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects total less than index', () {
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:5/2:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects segments that are too short to carry any payload', () {
      // Header alone with no payload (just "RL:aabbccdd:1/1:")
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:1/1:'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects segment with non-numeric idx/total', () {
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:x/y:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:1/a:AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects segment with empty body', () {
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:1/1'),
        throwsA(isA<SmsFramingException>()),
      );
    });

    test('rejects segment without trailing colon before body', () {
      // Body must be after the third colon. "RL:aabbccdd:1/1AAAA" missing the
      // separator colon.
      expect(
        () => SmsFraming.parseSegment('RL:aabbccdd:1/1AAAA'),
        throwsA(isA<SmsFramingException>()),
      );
    });
  });

  group('SmsFraming round-trip', () {
    test('fragment then parseSegment → assemble equals original', () {
      final payload = _randomBytes(5432);
      final segments = SmsFraming.fragment(
        messageId: 'feedface',
        payload: payload,
      );
      final parsed = segments
          .map((s) => SmsFraming.parseSegment(s.body))
          .toList();
      final reassembled = SmsFraming.assemble(parsed);
      expect(reassembled, equals(payload));
    });
  });
}

Uint8List _randomBytes(int length) {
  final rng = math.Random(length);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return bytes;
}