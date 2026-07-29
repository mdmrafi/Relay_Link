# VERDICT — Ticket #12 — D5 Double Ratchet Package Usability

**Verdict:** ❌ **NOT USABLE**

**Date:** 2026-07-30
**Author:** Ticket #12 agent
**Time spent:** ~45 min (within 1-hour cap)
**D5 fallback:** Ticket #13 must fall back to **HKDF-chain-only** (per D5 decision rule: 1, 2, or 4 fail → fall back regardless of which).

---

## Summary

| Requirement | Verdict | Evidence |
|---|---|---|
| **req 1**: Double Ratchet (X25519 DH + symmetric chain + skipped-key storage) | ✅ PASS (internally) | `lib/src/ratchet/root_key.dart` does X25519 ECDH `createChain()`; `chain_key.dart` is the symmetric HMAC chain; `SessionState.maxMessageKeys = 2000` (capped skipped-key storage); `session_state.dart` line 250 has `setMessageKeys` with overflow check. BUT these primitives are NOT part of the public API — they are reached only by going through X3DH. |
| **req 2**: Bootstrap from externally-provided shared secret (no X3DH) | ❌ **FAIL** | `lib/libsignal_protocol_dart.dart` only re-exports `src/session_builder.dart` + `src/session_cipher.dart`. The internal `lib/src/ratchet/*.dart` files (RootKey, ChainKey, MessageKeys, RatchetingSession) are **NOT exported**. The only session-entry API is `SessionBuilder.processPreKeyBundle(PreKeyBundle)`, which calls `RatchetingSession.initializeSessionAlice/Bob` with the X3DH-derived master secret (4 concatenated ECDH agreements: `theirSignedPreKey ‖ ourIdentityKey`, `theirIdentityKey ‖ ourBaseKey`, `theirSignedPreKey ‖ ourBaseKey`, optional `theirOneTimePreKey ‖ ourBaseKey`). There is no public entry point that accepts an externally-provided 32-byte shared secret. |
| **req 4**: Builds on Flutter Android | ⚠️ PARTIAL | `flutter pub add libsignal_protocol_dart` resolves cleanly (8 transitive deps including `x25519`, `pointycastle`, `ed25519_edwards`, `protobuf`). `flutter test test/ratchet_smoke_test.dart` passes (2/2). `flutter analyze` clean. **`flutter build apk --debug` FAILS, but the failure is in `android/app/src/main/kotlin/com/example/relaylink/SmsPlugin.kt:29` (unresolved `BroadcastReceiver` reference) — i.e., Ticket #23's in-progress work, NOT the libsignal package.** Reverting my changes and rebuilding at HEAD also fails identically. So req 4 is effectively PASS for the libsignal package itself; the build failure is in another ticket's broken Kotlin. |

**D5's "usable" bar:** all three of req 1, req 2, req 4 must pass. **req 2 fails** → package is NOT USABLE → #13 falls back to HKDF-chain.

---

## Candidates evaluated

### Candidate 1: `libsignal_protocol_dart` (v0.8.2)

- **Source:** `pub.dev/packages/libsignal_protocol_dart` (mixin.dev, GitHub: `MixinNetwork/libsignal_protocol_dart`)
- **Maintenance:** Last published 2026-06-20 (~5 weeks ago); actively maintained; 66 likes; 6.25k monthly downloads; 150/160 pub health score.
- **Description:** Pure-Dart port of Signal Protocol (NOT an FFI binding). Mature, used by Mixin Messenger in production for years.
- **Algorithm coverage:** Full Double Ratchet + X3DH + Sender Keys (group) + XEdDSA. Internally implements all primitives correctly.
- **D5 req 1:** ✅ (X25519 DH + symmetric chain + capped skipped keys; all inside the ratchet/ directory).
- **D5 req 2:** ❌ The public API surface (re-exported in `lib/libsignal_protocol_dart.dart`) deliberately hides the ratchet primitives — only `SessionBuilder` and `SessionCipher` are exposed. The X3DH derivation is hardcoded inside `RatchetingSession.initializeSessionAlice/Bob` with no override hook. Any caller who wanted to skip X3DH would have to fork the package and patch `RatchetingSession.calculateDerivedKeys` to accept an external master secret, OR re-implement the Double Ratchet on top of `cryptography` (the existing pubspec dep) or `pointycastle` (already a transitive dep).
- **D5 req 4:** ✅ Package builds and tests pass. APK build is currently broken for unrelated reasons (Ticket #23 in progress).

### Candidate 2: `libsignal` (v6.1.1)

- **Source:** `pub.dev/packages/libsignal` (djx-y-z, GitHub: `djx-y-z/libsignal_dart`)
- **Maintenance:** Last published 2026-07-25 (4 days ago); new project (created 2025-12-31); only 3 likes; 775 monthly downloads; 150/160 pub health score.
- **Description:** Dart wrapper around Signal's official Rust library via `flutter_rust_bridge`. License: AGPL-3.0 (with app-store exception).
- **Algorithm coverage:** Tracks upstream `libsignal` closely.
- **D5 req 1:** ✅ (it IS the official Signal Protocol).
- **D5 req 2:** ❌ Same architectural problem — X3DH is mandatory in upstream libsignal's `SessionBuilder`. No documented "external shared secret bootstrap" API.
- **D5 req 4:** Risky. Requires native compilation via `flutter_rust_bridge` (Rust toolchain on the build machine, code_assets, hooks). On a hackathon timeline with Android-only targeting, a native Rust dependency adds non-trivial build risk.
- **Other concerns:** AGPL-3.0 is a viral copyleft license — if RelayLink is open-source it could be fine, but a hackathon submission being evaluated by judges may want to avoid license-clarification overhead. New package, low download count → maintenance risk in 27h.
- **Verdict for this candidate:** Not evaluated in depth because req 2 fails on architecture grounds and req 4 carries Rust-build risk. Would be the next-best fallback for the team if they later decide to revisit D3 and accept "we'll do the full Signal stack even if X3DH is mandatory."

### Candidate 3: `double_ratchet` (non-existent)

- `pub.dev/packages/double_ratchet` returns **404**. The package does not exist on pub.dev. (The name may exist in someone's GitHub fork, but it's not published and not reachable via the standard package manager.)

### Other candidates searched

`pub.dev/api/search?q=signal+protocol` returned: `libsignal`, `libsignal_protocol_dart`, `lattice_crypto`, `azproto`, `lattice_server_supabase`, `lattice_server_serverpod`, `lattice_server_firebase`, `lattice_client`, `libsignal_protocol_hive_store`, `lattice_server`. None of the non-libsignal ones implement Double Ratchet — they are unrelated lattice-crypto packages.

`pub.dev/api/search?q=double+ratchet` returned: empty (only the (non-existent) `double_ratchet` and unrelated things).

**No third viable candidate.**

---

## Why this matters

The spec (§6.3) calls for DIRECT-message end-to-end encryption using a Double Ratchet, but **explicitly skips X3DH** — the two parties are assumed to have done an out-of-band X25519 ECDH exchange (e.g., via QR code per §6.1) and the 32-byte shared secret from that exchange is the input to the ratchet.

Every published Dart Signal Protocol package treats X3DH as inseparable from the Double Ratchet because that's how the reference Signal stack is structured. To get a "ratchet with externally-provided initial secret," the team has two options:

1. **Fork one of these packages** and patch `RatchetingSession.initializeSession*` to accept an external master secret. (~4–8 h of careful work, requires understanding the X3DH derivation well enough to substitute it.)
2. **Fall back to HKDF-chain-only** (D5's contingency). Implement a single symmetric chain (HMAC-based, like the symmetric half of the Double Ratchet) seeded with the QR-derived shared secret. This gives **forward secrecy across the chain** (every message key is derived from the previous chain key, so compromise of one key doesn't expose earlier keys) but **NO post-compromise security** (a leaked current chain key exposes all future keys until the chain is re-seeded). For the hackathon demo this is fine; for production §6.3 compliance it would not be.

The D5 fallback decision was already made: if 1, 2, or 4 fail, fall back to HKDF-chain regardless. **req 2 fails. Fall back. #13 should proceed with HKDF-chain.**

---

## What #13 should do

Per D5 and per this verdict, #13 (DIRECT crypto) should implement a **symmetric HKDF chain**:

- Seed: 32-byte shared secret from QR exchange (§6.1).
- Per-message key derivation: `chain_key = HMAC-SHA256(prev_chain_key, "next")`; `message_key = HKDF(chain_key, "msg" || idx)`.
- Skip-list (optional): keep up to 1000 message keys by `(sender_id, idx)` for out-of-order decryption; reject further (matches the original §6.3 skipped-key cap).
- Direction flag: prepend a 1-byte sender tag to the `info` parameter of HKDF so Alice→Bob and Bob→Alice get independent chains from the same seed.

This is exactly what the symmetric half of `ChainKey.getNextChainKey()` + `getMessageKeys()` does in `libsignal_protocol_dart`'s `lib/src/ratchet/chain_key.dart` (see `WhisperMessageKeys` info string and the 0x01/0x02 seed bytes) — so the team can read that file for the exact constants and reuse them. ~30 lines of Dart code, no new dependencies needed.

---

## Evidence trail

- Pub.dev page: https://pub.dev/packages/libsignal_protocol_dart
- `lib/libsignal_protocol_dart.dart` (top-level export): https://github.com/MixinNetwork/libsignal_protocol_dart/blob/master/lib/libsignal_protocol_dart.dart — note `lib/src/ratchet/*.dart` is NOT in the export list.
- `lib/src/ratchet/root_key.dart` (X25519 DH ratchet step): https://github.com/MixinNetwork/libsignal_protocol_dart/blob/master/lib/src/ratchet/root_key.dart
- `lib/src/ratchet/ratcheting_session.dart` (initialization with hardcoded X3DH): https://github.com/MixinNetwork/libsignal_protocol_dart/blob/master/lib/src/ratchet/ratcheting_session.dart — `initializeSessionAlice` and `initializeSessionBob` both feed 4 ECDH results into `calculateDerivedKeys`. No external-secret entry point.
- `lib/src/session_builder.dart`: https://github.com/MixinNetwork/libsignal_protocol_dart/blob/master/lib/src/session_builder.dart — only public entry is `processPreKeyBundle(PreKeyBundle)` which forces X3DH.
- `lib/src/state/session_state.dart` line 34: `static const int maxMessageKeys = 2000;` (skipped-key cap).
- `pubspec.yaml`: now includes `libsignal_protocol_dart: ^0.8.2` in dev_dependencies (so the integration smoke test runs).
- `test/ratchet_smoke_test.dart`: 2 tests, both pass — verifies (a) package imports and key types are present, (b) the ratchet/ primitives are NOT in the public API.
- `flutter pub add libsignal_protocol_dart --dev`: resolves successfully, 8 transitive deps added.
- `flutter test test/ratchet_smoke_test.dart`: ✅ All tests passed.
- `flutter analyze test/ratchet_smoke_test.dart`: ✅ No issues found.
- `flutter build apk --debug`: ❌ FAIL — but the failure is in `android/app/src/main/kotlin/com/example/relaylink/SmsPlugin.kt:29` (`Unresolved reference 'BroadcastReceiver'`), which is Ticket #23's work-in-progress, NOT this package. Reproduced at HEAD without my changes.

---

## Files changed in this ticket

- `pubspec.yaml` (added `libsignal_protocol_dart: ^0.8.2` in `dev_dependencies`)
- `pubspec.lock` (regenerated, +8 transitive deps)
- `test/ratchet_smoke_test.dart` (new)
- `VERDICT.md` (this file)

These changes are committed and pushed as part of this ticket. The pubspec change can be reverted by #13 if the team prefers to keep the dev-deps list clean — the package will still be in pubspec.lock for reproducibility but unused.
