# RelayLink v3 Spec Stress-Test (rev. 4 — decomposition complete)

**Date:** 2026-07-30 (~25 hours to 30 July 23:59 BST)
**Mode:** B (coordinator). A (build agent) lens applied throughout.
**Method:** /grill-with-docs — every pushback cites the spec section.
**Status:** Design phase complete. Decomposition complete. Ready for execution.

---

## 0. Top-line read

After four rounds of decisions, **the user has chosen spec-fidelity-over-safety on every trade-off.** Pattern:

| Decision | Chosen | Rejected alternative |
|---|---|---|
| D3 (crypto) | Full Double Ratchet | HKDF-chain simplification |
| D4/D5 (impl) | Wrap existing Dart package, fallback to HKDF if unusable | From-scratch or FFI-bind |
| D6 (vault) | Text-only vault ships (separate screen + chat long-press shortcut); photo/video/audio deferred | Cut entirely |
| D7 (DTN) | Full Bloom filter at 2000-ID/24h window | Bounded last-200-IDs |
| D8 (gateway) | Full toggle + relay-others' code | Stub toggle |

The spec, as now scoped, is **~50-65 hours of work for one agent. We have ~25 hours.** This is no longer solvable by smart sequencing. **Something must be cut that we haven't yet cut.** This document is that conversation.

---

## 1. Hard reality check

Hours available: ~25 (assuming start now, deadline 30 July 23:59 BST, minus sleep/buffer).

Hours required at single-agent pace, by feature:

| Feature | Estimated hours | Status |
|---|---|---|
| Flutter scaffold + Android/iOS project shells | 1-2 | MUST |
| §5 Message data model | 1-2 | MUST |
| §6.1 Device identity (Ed25519 + X25519 keypairs) | 1-2 | MUST |
| §6.2 BROADCAST crypto + custom channel key gen/QR | 2-3 | MUST |
| §7 Mesh send/receive/relay — basic | 4-6 | MUST |
| §7 Full Bloom filter peer-sync (D7) | 4-6 | MUST per D7 |
| §6.3 Full Double Ratchet via Dart package (D3/D5) | 6-8 | MUST per D3, contingent on D5 verdict at hour 6 |
| §4 Tier-1 connectivity (mesh + internet) | 1-2 | MUST |
| §10 Direct internet messaging + Firestore stub | 2-3 | MUST |
| §10 Firestore `.rules` (security) | 2-3 | MUST |
| §10 Gateway mode for others + toggle + safety (D8) | 3-4 | MUST per D8 |
| §9 SMS machinery (fragment/reassemble/dedupe) | 4-6 | SHOULD (gates §18 #4 and #8) |
| §9 BROADCAST-over-SMS fan-out | 1-2 | SHOULD |
| §9 DIRECT-over-SMS | 1-2 | SHOULD |
| §11 Text-only vault + chat long-press shortcut | 3-4 | SHOULD per D6 |
| §12 ALERT verified badge + allowlist | 1-2 | SHOULD |
| §3.1 Capability disclosure on first launch | 1-2 | MUST |
| ARCHITECTURE.md, README, demo script | 2-3 | MUST |
| Buffer / integration / debugging | 4-6 | MUST |

**Minimum total: ~46-65 hours.** Maximum realistic in 25h: ~25-30 hours of focused work for one agent.

**Conclusion:** with multiple parallel agents (which the spec was framed for and which I haven't seen evidence of in the repo), some of this is doable. With one agent, even heroic pace, **at least 20 hours of work must be cut or deferred.**

---

## 2. What MUST ship (the non-negotiable floor)

Minimum demoable RelayLink that proves the concept:

1. **Mesh send/receive** with at least two physical devices — proves the offline baseline works
2. **BROADCAST crypto** with default public channel — proves encryption isn't theatre
3. **DIRECT crypto** — at minimum a working key exchange and message decryption between two paired devices. (D5 fallback: HKDF-chain if the ratchet package fails the hour-6 verdict.)
4. **Capability disclosure on first launch** — proves the project is honest about platform limits
5. **Two-device demoable scenario** — Android A sends SOS, Android B receives and decrypts
6. **README + ARCHITECTURE.md** — hackathon compliance

This is the floor. Everything else is a bonus that adds demo surface.

---

## 3. What SHOULD ship, in priority order (highest demo-signal first)

If you can allocate more time beyond the floor, ship in this order — each item maximizes what judges see:

1. **§9 SMS machinery + BROADCAST fan-out** (§18 #8) — directly demonstrates the §4 connectivity hierarchy fix, which is one of v3's headline corrections. High signal.
2. **§10 Direct internet messaging + Firestore stub** — proves the app extends beyond local mesh.
3. **Custom channel QR flow** (§18 #7) — small surface, immediately demoable.
4. **§11 Text-only vault** (D6) — adds a feature judges can poke at.
5. **§9 DIRECT-over-SMS** (§18 #4) — reuses machinery from #1.
6. **§12 ALERT verified badge** — small, demoable if allowlist is in place.
7. **§10 Gateway-for-others toggle** (D8) — important for the spec's safety narrative, but complex; ship only if #1-#5 are stable.

---

## 4. What MUST be cut or deferred — and why

These items have to come out, given the time budget. They are *not* a criticism of the spec — they're a triage forced by 25 hours.

| Cut item | Reasoning | Where it goes |
|---|---|---|
| **§6.3 Full Double Ratchet** if D5 verdict at hour 6 says no usable package | Per D5 contingency: fall back to HKDF-chain-only, claim forward-secrecy-only in README | README §"What we built" + ROADMAP |
| **§7 Full Bloom filter peer-sync at 2000-window** if integration slips past hour 14 | Per STRESS-TEST §3.4: bounded last-200-IDs fallback, README notes the difference | README + ROADMAP |
| **§11 Photo/video/audio evidence capture** | Per D6: text-only for demo, media deferred | ROADMAP |
| **§15 exclusions** (load testing, localization, accounts, store compliance, third-party SMS gateway) | Per §15 itself — non-time reasons | ROADMAP |
| **Multi-hop mesh demo at >3 devices** | §15 excludes load testing | README acknowledges |
| **§10 Gateway-for-others full relay code** if it's past hour 18 and not stable | Per D8: ship toggle UI + safety warning, stub relay code, README names what's stubbed | README + ROADMAP |
| **§12 ALERT verification** if Firestore allowlist isn't ready by hour 22 | Demo shows the badge logic but allowlist is hardcoded to 2-3 demo entries | README + ROADMAP |
| **iOS app** | §3 + §16: iOS gets mesh + relevant subset, but full feature parity with Android is not realistic in 25h | ROADMAP + README notes iOS scope |
| **§3.1 capability disclosure on iOS specifically** | iOS-specific text (SMS features unavailable — Apple doesn't allow apps to send or read SMS) gets a single line in the Settings/About panel | README |
| **§10 backend hardening beyond demo rate limits** | §15: explicit "no production trust authority" disclosure | README |

---

## 5. Build plan, revised for 25 hours

If you (or your parallel agents) start now:

**Hours 0-6: Foundation (single agent)**
- Flutter scaffold (Flutter create, Android target confirmed builds)
- §5 Message schema (`lib/models/message.dart`)
- §6.1 device identity (`lib/crypto/identity.dart`)
- §6.2 BROADCAST crypto + network key + custom channel key gen
- **Hour-6 gate:** D5 verdict on the Double Ratchet package
  - If usable → integrate, budget 4-6h more for ratchet
  - If not → HKDF-chain-only fallback, document, move on

**Hours 6-14: Mesh + Internet (parallel if multiple agents)**
- §7 mesh layer (basic) — one agent
- §7 full Bloom filter peer-sync — same agent or a second
- §10 Direct internet messaging + Firestore stub — second agent
- §10 Firestore `.rules` — second agent

**Hours 14-20: Connectivity fallbacks (parallel)**
- §9 SMS machinery (fragment, reassemble, dedupe, retry) — one agent
- §11 text-only vault + chat long-press shortcut — another agent
- §6.2 custom channel QR UI — another agent

**Hours 20-24: Polish + integration**
- §3.1 capability disclosure
- §12 ALERT badge if Firestore ready
- §10 Gateway toggle if time permits
- §9 BROADCAST fan-out + DIRECT-over-SMS integration

**Hours 24-25: Buffer + submission**
- ARCHITECTURE.md, README
- Final integration test on two physical Android devices
- Submit

---

## 6. Demo script (what the submission video shows)

Two Android phones. Three minutes. Script:

1. **First launch** — capability disclosure card appears. Narrator reads it.
2. **Pair two devices** — phone A scans QR from phone B, both join "Demo Channel."
3. **Offline SOS** — wifi off, bluetooth off, no SIM. Phone A sends SOS. Phone B receives via mesh, decrypts, displays with location. Narrator: "the floor."
4. **Custom channel isolation** — phone A (joined) decrypts message; phone C (not joined, third device) only relays, cannot read. Narrator explains.
5. **Forward secrecy** (if ratchet ships) — pause video, narrator "compromises" key at message N, shows messages 1..N-1 still decrypt but N+1 fails. (If HKDF fallback: same demo with caveat in README.)
6. **SMS fan-out** — wifi off, bluetooth off, cellular on. Phone A SOSes; phone B (with SIM, no internet) receives via SMS. Narrator: "BROADCAST over SMS proves §4's connectivity hierarchy."
7. **Vault** — phone A captures text evidence; recipient phone D (offline) receives once it comes into mesh range. Narrator: "encrypted at rest, delivered when channel available."
8. **Disclaimer card** — text on screen: "Photo/video/audio capture deferred per ROADMAP. Load testing excluded per §15. ALERT verification uses a manually-curated demo allowlist."

---

## 7. Decisions log (full, current state)

| # | Decision | Status |
|---|---|---|
| D1 | Real submission, ~25h deadline | confirmed |
| D2 | I play both A and B | confirmed |
| D3 | §6.3 full Double Ratchet (no HKDF simplification in isolation) | confirmed |
| D4 | Implementation: wrap existing Dart package, simplify if unusable | confirmed |
| D5 | "Usable" bar = ratchet + X3DH-bypassable + Flutter Android build, patch around missing cap/tests | confirmed |
| D6 | §11 Evidence Vault scope = text-only, separate surface, chat long-press shortcut | confirmed |
| D7 | §7 DTN = full Bloom filter at 2000-ID/24h | confirmed |
| D8 | §10 Gateway mode = full toggle + safety + relay code | confirmed |

**All open design decisions resolved. The remaining ~25 hours are execution.**

---

## 9. Decomposition: spec → tickets (2026-07-30)

User requested `/to-spec` then `/to-tickets` with constraint that tickets fit in ~150k-token context windows and are parallelizable. Skills were model-invocation-disabled, so I executed the workflow manually:

- **Spec** written to `SPEC.md` at repo root, following `/to-spec` template (Problem Statement, Solution, User Stories, Implementation Decisions, Testing Decisions, Out of Scope, Further Notes).
- **46 tickets** written under `.scratch/relaylink-build/issues/NN-<slug>.md`, in dependency order, with explicit "Blocked by" references per `/to-tickets` template.
- **GitHub mirror** of all 46 tickets published in a single wave to `github.com/Azm1ne/July-2026-hackathon`, each tagged `ready-for-agent`. Local files remain source of truth; GH issues carry ticket-number references for blockers.
- **Publish script** at `.scratch/relaylink-build/publish.sh` for re-running if needed.

**Ticket groups** (per `.working-memory.md` "Decomposition"):
- Foundation: #01-#05
- Transport + Mesh: #06-#11
- Direct crypto + Channels: #12-#17
- Internet: #18-#22
- SMS: #23-#28
- Capabilities + Vault: #29-#34
- ALERT: #35-#37
- UI screens: #38-#42
- Polish + submit: #43-#46

**Frontier order** (no blockers, can start immediately): #01 (scaffold), #02 (identity), #03 (BROADCAST crypto), #04 (message schema), #05 (storage), #10 (Bloom filter), #12 (ratchet verdict), #18 (Firestore stub), #21 (Gateway toggle UI), #23 (SMS platform channel), #24 (SMS fragmentation), #29 (capability detection), #35 (verified orgs allowlist).

**Decision gates during execution** (these are tickets with verdicts, not code):
- #12 (D5 verdict on Double Ratchet package) — hour-6 deadline per D5
- #14 (Forward-secrecy demo) — depends on D5 verdict outcome
- Fallback tickets (HKDF-chain ratchet, bounded last-200-IDs sync) are baked into #13 and #11 respectively as conditional paths

**Done.** Awaiting execution.

---

## 8. The one question I want to flag before exiting design phase

Auto mode says "execute." I will. But before I do, I want to ask one thing — not a decision question, but a calibration question.

You have, on every trade-off so far, chosen the harder / fuller / more spec-faithful option. The spec was written for multiple parallel agents and a longer timeline. With ~25 hours and no evidence of parallel agents actually building in the repo, **the realistic outcome is that some of D3 / D7 / D8 will not ship, regardless of how hard we work.** That's not a failure of the team — it's arithmetic.

If you want, I can:
- **(A) Start executing now** on the plan in §5, treating decisions as final and making pragmatic sub-decisions as I go (e.g., D5 verdict at hour 6).
- **(B) Pause and revisit one of the open decisions** because the time pressure has shifted the calculus. For instance: D3 vs. HKDF-fallback might look different at hour 22 than it did at hour 0. D7 might look different at hour 14.
- **(C) Stress-test the assumption that no parallel agents are building** — there might be branches, worktrees, or off-repo state I haven't seen.

My recommendation: **(A)**. The decisions were made with eyes open. Honor them, ship the floor, and disclose honestly in the README what was and wasn't built. If hour 6 / hour 14 / hour 18 gates trigger fallbacks, the README records that and we move on.

What do you want?