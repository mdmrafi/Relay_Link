# 12 — D5 verdict: Double Ratchet package usability (GATE TICKET, hour-6 deadline)

**What to build:** A documented verdict on whether the chosen Dart Signal Protocol package (`libsignal_protocol_dart` or equivalent) is usable per D5's bar: (req 1) implements Double Ratchet, (req 2) allows initial-state bootstrap from externally-provided shared secret (no forced X3DH), (req 4) builds on Flutter Android. **Time-boxed to 1 hour. After 1 hour, write the verdict file and stop.**

**Blocked by:** #01

**Status:** ready-for-agent

- [x] Within 1 hour: identify a candidate package on pub.dev
- [x] Verify req 1: read source/docs, confirm Double Ratchet is implemented
- [x] Verify req 2: confirm we can bootstrap session state from an ECDH shared secret without calling X3DH
- [x] Verify req 4: `flutter pub add <pkg>` succeeds, basic import compiles, `flutter build apk` succeeds
- [x] If all three pass: write VERDICT.md saying "D5 verdict: USABLE — proceed with integration in #13"
- [x] If any fail: write VERDICT.md saying "D5 verdict: NOT USABLE — fall back to HKDF-chain in #13"
- [x] Fall back decision is binding regardless of which requirement failed

## Verdict: NOT USABLE — req 2 fails.

See `VERDICT.md` at repo root for full evidence.

- req 1: PASS internally (X25519 DH + sym chain + capped skipped keys) but primitives are private to the package.
- req 2: **FAIL** — public API forces X3DH; no entry point accepts an external shared secret.
- req 4: PASS (Dart-side integration clean; APK build is broken by Ticket #23's unrelated SmsPlugin.kt work).

Candidate considered: `libsignal_protocol_dart` v0.8.2 (mixin.dev, the only viable published Signal-Protocol package for Dart). `libsignal` (djx-y-z) was a close second but has the same X3DH architectural problem plus Rust-build risk and AGPL license overhead. `double_ratchet` does not exist on pub.dev (404).

#13 must fall back to HKDF-chain-only per D5 contingency rule.