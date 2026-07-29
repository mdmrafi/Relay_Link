# 12 — D5 verdict: Double Ratchet package usability (GATE TICKET, hour-6 deadline)

**What to build:** A documented verdict on whether the chosen Dart Signal Protocol package (`libsignal_protocol_dart` or equivalent) is usable per D5's bar: (req 1) implements Double Ratchet, (req 2) allows initial-state bootstrap from externally-provided shared secret (no forced X3DH), (req 4) builds on Flutter Android. **Time-boxed to 1 hour. After 1 hour, write the verdict file and stop.**

**Blocked by:** #01

**Status:** ready-for-agent

- [ ] Within 1 hour: identify a candidate package on pub.dev
- [ ] Verify req 1: read source/docs, confirm Double Ratchet is implemented
- [ ] Verify req 2: confirm we can bootstrap session state from an ECDH shared secret without calling X3DH
- [ ] Verify req 4: `flutter pub add <pkg>` succeeds, basic import compiles, `flutter build apk` succeeds
- [ ] If all three pass: write VERDICT.md saying "D5 verdict: USABLE — proceed with integration in #13"
- [ ] If any fail: write VERDICT.md saying "D5 verdict: NOT USABLE — fall back to HKDF-chain in #13"
- [ ] Fall back decision is binding regardless of which requirement failed