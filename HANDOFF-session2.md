# HANDOFF.md — Session 2 → Session 3

**Date:** 2026-07-30
**Branch:** `main`
**Deadline:** 30 July 2026 23:59 BST (~21 hours remaining as of session 2 end)

---

## What's done in this session

12 tickets landed on `main` (all pushed):

| # | Ticket | Commit | Notes |
|---|---|---|---|
| #01 | Flutter scaffold | `4a412ef` | APK builds, app runs on emulator |
| #02 | Device identity | `2cf2396` | Ed25519 + X25519, senderId derivation |
| #03 | BROADCAST crypto | `6721705` | AES-256-GCM, channel-id AAD binding |
| #04 | Message schema | `bf69932` | All 16 fields, JSON round-trip |
| #05 | Local storage | `91f12e2` | sqflite + secure storage, schema v1 |
| #10 | Bloom filter | `04671e5` | FPR 1.40% measured, no new deps |
| #12 | D5 verdict | `b4c227d` | **NOT USABLE** — HKDF-chain fallback binding for #13 |
| #18 | Firestore stub | `d5ed9b7`+`b4c227d` | Local-only mode on init failure |
| #21 | Gateway toggle UI | `0f909e1` | Verbatim safety warning |
| #23 | SMS platform channel | `a30901f` | Android+iOS paths, APK builds clean |
| #29 | Capability detection | `10a4c05` | 9 features with reasons |
| #35 | Verified orgs allowlist | `abf7b92` | 3 demo orgs seeded |

**Public API surface:** documented in each ticket's subagent report. No coordination issues, all code on `origin/main`.

---

## Critical decision-gate outcome

**#12 D5 verdict: NOT USABLE.** `libsignal_protocol_dart` fails req 2 (no public API to bootstrap from external ECDH secret without X3DH). Full evaluation in `VERDICT.md` at repo root.

**Binding consequence for #13:** ship HKDF-chain-only — per-message `key_n = HKDF(key_{n-1}, "rl-msg-v1")`, message key discarded after use, no skipped-key storage. The ~30-line path is sketched in `VERDICT.md`. README will disclose this under "What this demo does and doesn't prove."

---

## Next session's work — frontier tickets (no blockers, can start immediately)

### Wave 3 priority 1 (all have blockers done):
- **#06** Transport interface + TransportManager + LoopbackTransport (blocks #07, #20)
- **#13** DIRECT crypto (HKDF-chain fallback) — binding per D5 verdict
- **#15** Channel key generation + storage (blocks #16, #17)
- **#19** Firestore security rules (blocks #20)
- **#30** Capability disclosure UI (uses #29)
- **#31** Vault encrypt-at-rest + storage (uses #03, #02, #05)
- **#36** Allowlist sync + cache (uses #35, #18)

### Wave 3 priority 2 (depend on Wave 3 priority 1):
- **#07** Mesh discovery (needs #06)
- **#14** Forward-secrecy demo (needs #13)
- **#16** Channel QR (needs #15)
- **#20** Direct internet messaging (needs #06, #18, #19, #03, #13)

### Wave 3 priority 3 (depend on Wave 3 priority 2):
- **#08** Mesh send/receive (needs #07)
- **#17** Channel routing (needs #09, #15 — #09 still pending)
- **#37** ALERT badge (needs #36, #39)

### Wave 3 priority 4 (depend on Wave 3 priority 3):
- **#09** Mesh relay with TTL + seen-cache (needs #08, #05)
- **#11** Bloom-filter peer-sync on connect (needs #09, #10)

### Outstanding tickets not yet planned:
- **#22** Gateway relay code (needs #21; per STRESS-TEST hour-18 fallback if unstable)
- **#24–#28** SMS machinery (fragmentation, reassembly, reinjection, BROADCAST fan-out, DIRECT-over-SMS)
- **#32–#34** Vault UI + send-on-connect + chat-to-vault
- **#38–#42** UI screens (home, chat, contacts, channels, settings)
- **#43–#46** Polish + submit (README, ARCHITECTURE, integration test, submission)

These are the "floor" beyond the foundation. Realistic per STRESS-TEST: ~46-65 hours of work, ~21 hours left. Something gives. Document fallbacks honestly in the README.

---

## Environment notes for next session

- All env verified: Flutter 3.44.8, Android SDK 36, KVM, JDK 21, AVD `relaylink_avd` (Pixel 6, Android 36 Google APIs x86_64)
- `source ~/.bashrc` to get `flutter`, `adb`, `sdkmanager`, `avdmanager` on PATH
- AVD emulator was confirmed running #01's "RelayLink" text. Reuse for verification.
- pubspec.yaml pinned: cryptography ^2.9.0, flutter_riverpod ^2.6.1, sqflite ^2.4.3, flutter_secure_storage ^10.3.1, uuid ^4.6.0, qr_flutter ^4.1.0, mobile_scanner ^7.4.0, shared_preferences ^2.5.5, firebase_core ^4.12.1, cloud_firestore ^6.7.1, firebase_storage ^13.4.5, sqflite_common_ffi ^2.3.0 (dev)
- `lib/crypto/identity.dart`, `lib/crypto/broadcast.dart`, `lib/models/message.dart`, `lib/storage/`, `lib/mesh/bloom.dart`, `lib/features/gateway/toggle.dart`, `lib/capabilities/detect.dart`, `lib/allowlist/verified_orgs.dart`, `lib/backend/firebase.dart`, `lib/sms/platform_channel.dart` all exist and are tested — reuse them.

---

## Coordination notes from parallel-agent runs

- Some commits absorbed unrelated edits from concurrent in-flight files (pubspec.yaml mods, etc.). Cross-repo flutter analyze is now clean (verified by #35's run). If a follow-up cleanup is needed, scope is small.
- The `flutter build apk --debug` failure that #18 reported was caused by #23's unfinished SmsPlugin.kt at the time; resolved by #23's final commit.
- Subagent deviations (e.g., #04 used `dart:convert` not `package:convert`; #05 used `VaultRecord` in its own file) are documented in their ticket commit messages and don't conflict.

---

## Files to read first thing in next session

1. `CONTEXT.md` — project rules, decision gates, honesty requirements
2. `SPEC.md` — what we're building
3. `STRESS-TEST.md` — cut list, decision gates, decision log
4. `.working-memory.md` — decisions D1-D8
5. `VERDICT.md` — D5 verdict on Double Ratchet (NOT USABLE → HKDF-chain)
6. This file (`HANDOFF-session2.md`)
7. `.scratch/relaylink-build/issues/` — pick ticket files for the next wave

---

## Don't

- Don't rewrite the spec, stress-test, or working memory
- Don't add libsignal_protocol_dart to dependencies (D5 says NOT USABLE)
- Don't publish to main without verifying acceptance criteria
- Don't push commits that don't reference a ticket number
- Don't break the local-is-source-of-truth contract

---

## Quick decision reminder if user asks "what's next?"

Per STRESS-TEST §5 (hours 6-14, parallel agents):
1. Mesh layers (#06 transport interface, #07 discovery, #08 send/receive, #09 relay, #11 bloom-sync)
2. Internet (#18 stub ✅, #19 rules, #20 direct messaging)
3. Crypto follow-ups (#13 HKDF-chain, #14 FS demo)
4. Vault (#31 encrypt/store, #32 UI, #33 send-on-connect, #34 chat-to-vault)
5. UI polish (#38-#42)
6. Submit (#43-#46)

`/implement` to launch next wave in parallel.
