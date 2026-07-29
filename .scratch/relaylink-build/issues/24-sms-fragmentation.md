# 24 — SMS fragmentation (RL:msgid:idx/total: header)

**What to build:** `lib/sms/framing.dart` exposing `fragment(messageId, ciphertext, maxSegmentLen)` returning a list of segment strings, each formatted as `RL:<8-char-msgid>:<idx>/<total>:<base64-chunk>`. `maxSegmentLen` defaults to 140 chars to leave room for carrier overhead.

**Blocked by:** #01

**Status:** ready-for-agent

- [ ] Header is exactly `RL:` + 8 hex chars + `:` + 1-2 digit idx + `/` + 1-3 digit total + `:`
- [ ] Base64 chunks fit within remaining segment length
- [ ] Round-trip: fragment 1KB ciphertext into ~7 segments, reassemble to original bytes
- [ ] Total segment count is encoded correctly for messages of any size
- [ ] Tests: edge cases (1-byte payload = 1 segment, 1KB = ~7 segments, 10KB = ~70 segments)