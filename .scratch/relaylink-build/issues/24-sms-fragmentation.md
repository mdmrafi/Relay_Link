# 24 — SMS fragmentation (RL:msgid:idx/total: header)

**What to build:** `lib/sms/framing.dart` exposing `fragment(messageId, ciphertext, maxSegmentLen)` returning a list of segment strings, each formatted as `RL:<8-char-msgid>:<idx>/<total>:<base64-chunk>`. `maxSegmentLen` defaults to 140 chars to leave room for carrier overhead.

**Blocked by:** #01

**Status:** implemented

- [x] Header is exactly `RL:` + 8 hex chars + `:` + 1-2 digit idx + `/` + 1-3 digit total + `:`
- [x] Base64 chunks fit within remaining segment length
- [x] Round-trip: fragment 1KB ciphertext into ~7 segments, reassemble to original bytes
- [x] Total segment count is encoded correctly for messages of any size
- [x] Tests: edge cases (1-byte payload = 1 segment, 1KB = ~7 segments, 10KB = ~70 segments)

**Implementation notes:**
- `lib/sms/framing.dart` exposes `SmsFraming.fragment()`, `SmsFraming.parseSegment()`, `SmsFraming.assemble()`, `SmsFraming.detectSegmentLimit()`, and the `SmsFragment` value type.
- `lib/sms/exceptions.dart` introduces `SmsFramingException` for malformed-segment errors so callers can recover by discarding the offending entry.
- Constants: `gsm7MaxChars = 160`, `ucs2MaxChars = 70`, `defaultSegmentLength = 140` (20 chars headroom for carrier UDH), `maxTotalSegments = 999`, `minSegmentLength = 24`, `messageIdLength = 8`, `headerOverheadMin = 20`.
- Iterative whole-payload Base64 fragmentation: encode the payload once, then split the resulting base64 string into chunks that fit within `segmentLength - headerOverheadMin`. Each segment carries a contiguous base64 substring; reassembly is split-join-decode.
- Strict 8-hex-char message-ID validation (digits + a-f + A-F), 1-based indexes, max total 999.
- Duplicates of the same (msgid, idx) are silently deduped on assemble.
- `detectSegmentLimit()` raises `SmsFramingException` if the requested limit is below `minSegmentLength` (24) so callers can't accidentally produce segments that can't even carry the header + 1 base64 char.
- Empty payloads rejected explicitly (callers that have no payload should skip SMS, not send a 1-byte empty fragment that would still cost a carrier round-trip).