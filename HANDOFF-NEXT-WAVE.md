# RelayLink — Next-wave handoff

> Snapshot at the end of session 4: `origin/main @ 6c64556` (2026-07-30 03:27 UTC).

## Where we are

**`origin/main` is clean and pushed.**

* `flutter test` → **314 tests pass, 0 failures**
* `flutter analyze` → **0 errors, 0 warnings** (13 `info`-level lint suggestions)
* All Wave-3 tickets landed + #22, #27, #28, #43, #44, #45, #46 cherry-picked in

### Tickets already shipped (refer to `.scratch/relaylink-build/issues/`):

| # | Title | Notes |
|---|---|---|
| 02 | Device identity (Ed25519 + X25519) | lib/crypto/identity.dart |
| 03 | Broadcast crypto (AES-256-GCM) | lib/crypto/broadcast.dart |
| 04 | Message schema | lib/models/message.dart |
| 05 | Local storage helpers | lib/storage/local_db.dart |
| 06 | Transport interface | lib/transport/transport.dart |
| 12 | libsignal verdict (D5) | documentation |
| 13 | DIRECT crypto (HKDF-chain fallback) | lib/crypto/direct.dart |
| 15 | Channel key store | lib/channels/keys.dart |
| 18 | Firestore stub | lib/backend/firebase.dart |
| 19 | Firestore + storage rules | firestore.rules, storage.rules + 27-case suite |
| 21 | Gateway toggle UI | lib/features/gateway/toggle.dart |
| 22 | Gateway relay orchestrator | lib/features/gateway/relay.dart + minimal mesh/internet transports |
| 23 | SMS platform channel | lib/sms/platform_channel.dart |
| 24 | SMS framing (`RL:...`) | lib/sms/framing.dart |
| 25 | SMS reassembly | lib/sms/reassembler.dart (10-min inactivity timeout) |
| 26 | SMS reinjection | lib/sms/transport.dart |
| 27 | SMS BROADCAST fan-out | lib/sms/fanout.dart + fanout_types.dart |
| 28 | SMS DIRECT adapter | lib/sms/direct_adapter.dart |
| 29 | Capability detection | partial in main.dart |
| 30 | Capability disclosure UI | lib/screens/capability_disclosure.dart |
| 31 | Vault encrypt-at-rest | lib/vault/store.dart (v2 schema) |
| 35 | Verified orgs allowlist (local) | lib/alerts/allowlist.dart |
| 36 | Allowlist sync + cache | lib/alerts/allowlist.dart |
| 43 | Bilingual README | README.md (Bangla summary, D5 disclosure) |
| 44 | Architecture doc | ARCHITECTURE.md (upgraded from placeholder) |
| 45 | Two-device integration test | test/integration/two_device_e2e_test.dart |
| 46 | Submission package | LICENSE, AI-TOOLS.md, CODE-OF-CONDUCT.md, SUBMISSION.md |

## Tickets still to ship (next wave)

Drawn from `.scratch/relaylink-build/issues/`:

### Critical-path chain (blocking each other)

```
#07 mesh discovery  ─► #08 mesh send/receive  ─► #09 mesh relay + seen-cache
       (needs: #06 ✅)         (needs: #07)            (needs: #08, #05 ✅)

#20 direct internet messaging  ─► #38 home screen  ─► #39 chat screen
       (needs: #06 ✅, #18 ✅, #19 ✅, #03 ✅, #13 ✅)   (needs: #04 ✅, #08, #20, #26 ✅)
```

### Independent / UI tickets (unblocked now)

* **#10** Bloom filter encoding + size math (needs #01 ✅)
* **#14** Forward-secrecy demo (needs #13 ✅)
* **#32** Vault UI — list, view, delete (needs #31 ✅)
* **#37** ALERT verified badge in UI (needs #36 ✅, #39 not landed yet — implement against current Message envelope)
* **#42** Settings/About screen (needs #30 ✅, #21 ✅)
* **#33** Vault send-on-connect (needs #31 ✅, #20, #08)
* **#34** "Save as evidence" from chat (needs #32, #39)

### Likely deferred (out of scope for the deadline)

* **#11** Bloom-filter peer-sync on connect (needs #09, #10)
* **#16** Channel QR encode + scan (needs #15 ✅)
* **#17** Channel routing (needs #09, #15 ✅)
* **#40** Contacts screen (needs #02 ✅, #16)
* **#41** Channels screen (needs #15 ✅, #16)

## Recommended next-wave plan (parallel-friendly)

### Wave 4 — Unblock critical path (4 worktrees in parallel)

These four have **no inter-dependencies** between them:

| Ticket | Why parallel-safe | Output |
|---|---|---|
| **#10** Bloom filter | Standalone math lib, no Flutter, no IO | lib/mesh/bloom.dart + tests |
| **#14** Forward-secrecy demo | Standalone script against #13 | tools/demo_forward_secrecy.dart |
| **#07** Mesh discovery | Wraps flutter_nearby_connections | lib/mesh/discovery.dart + Android permission flow |
| **#20** Direct internet messaging | Builds on #06 + #18 + #19 | lib/transport/internet.dart (production version, not the minimal stub in #22) |

### Wave 5 — Critical path (sequential after Wave 4)

| Ticket | Why sequential | Output |
|---|---|---|
| **#08** Mesh send/receive | needs #07 | lib/mesh/transport.dart (real BLE-backed Transport, replaces #22's minimal stub) |
| **#09** Mesh relay + seen-cache | needs #08 | mesh relay logic with TTL decrement + seen-cache dedup |
| **#17** Channel routing | needs #09, #15 ✅ | mesh-layer channel_id tag-aware relay |
| **#38** Home screen | needs #29, #08, #20, #26 ✅ | lib/screens/home.dart |
| **#39** Chat screen | needs #04 ✅, #08, #20, #26 ✅ | lib/screens/chat.dart |

### Wave 6 — UI polish (parallel-friendly)

| Ticket | Notes |
|---|---|
| **#32** Vault UI | list/view/delete over #31 |
| **#37** ALERT badge | reads from #36, against any Message display |
| **#42** Settings screen | wires #30 + #21 into a single page |
| **#34** "Save as evidence" | needs #32, so do after #32 |

## Operational notes for next session

* `flutter` binary: `~/flutter/bin/flutter` (PATH not set by default)
* adb: emulator requires `adb start-server` + `adb connect localhost:5554` before any `adb install`
* `pubspec.yaml` deps are pinned and `flutter pub get` is clean
* Existing worktree branches on disk are stale snapshots — they were used to build the cherry-picks; new work should start from fresh worktrees off `main` (commit `6c64556`)
* Style: prefer `info`-level `prefer_initializing_formals` are tolerated; do not chase them in CI
* Tests live in `test/`; integration tests in `test/integration/`

## Recommended commit message style

```
#<ticket> <title>

<bullet: what changed>
<bullet: anything noteworthy>

Co-Authored-By: Opus 4.8 <noreply@puku.sh>
```

## Open low-priority items

* 13 `info`-level `prefer_initializing_formals` lint suggestions (mostly in the worktree-cherry-picked code — not blocking)
* Local worktree branches (worktree-agent-*) can stay; they have no semantic meaning after the cherry-picks
* No backend emulator / no real-device demo recorded yet — judgment on "demo devices" requires physical phones + SIMs (called out in README §3)