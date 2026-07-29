# 25 — SMS reassembly (buffer by msgid, 10-min timeout, dedup)

**What to build:** `lib/sms/reassembler.dart` exposing `Reassembler` that ingests one segment string at a time, tracks per-msgid received/total, completes when all segments arrive, emits the reassembled ciphertext via Stream, drops incomplete sets after 10-minute timeout.

**Blocked by:** #24

**Status:** ready-for-agent

- [x] Single-segment "messages" complete immediately on arrival
- [x] Multi-segment messages buffer correctly, emit when total reached
- [x] Duplicate segments (same msgid+idx) are deduped silently
- [x] After 10 minutes of inactivity on a msgid, the buffer entry is discarded with a log line
- [x] Test: feed 5 segments with one duplicate, one out-of-order, confirm correct reassembly
- [x] Test: feed 3 of 7 segments, wait 11 minutes, confirm buffer is cleaned and no output emitted