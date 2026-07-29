# RelayLink — Submission Package (Ticket #46)

> This file is the canonical record of the hackathon submission form, judging
> weights, and current readiness state. It is the source of truth that ticket
> #43's bilingual README and ticket #44's `ARCHITECTURE.md` link back to.
>
> It is **intentionally explicit** about which items have been completed by
> automation and which require the coordinator's manual action — judges should
> be able to tell at a glance what shipped and what was deferred.

---

## 1. Submission form fields

These are the fields the hackathon submission form asks for, with the
authoritative answer. **The form itself must be filled and submitted by the
project coordinator** — automation cannot impersonate a participant.

| Form field | Value |
|---|---|
| **Project name** | RelayLink |
| **One-line tagline** | Offline-first mesh messaging with end-to-end encryption, SMS / internet fallback, and a text-only Evidence Vault. |
| **Repository URL** | <https://github.com/Azm1ne/July-2026-hackathon> |
| **Submission deadline** | 30 July 2026, 23:59 BST |
| **License** | MIT — see [`LICENSE`](./LICENSE) |
| **Has a buildable demo?** | The repository documents `flutter pub get`, `flutter run`, and `flutter build apk --debug`. Ticket #46 does **not** claim a final APK; the coordinator must record a fresh successful build before making that claim. iOS remains unverified on this machine. |
| **AI tool disclosure** | See [`AI-TOOLS.md`](./AI-TOOLS.md) and the "AI Tool disclosure" section of `README.md`. |
| **Data collected** | See [`CODE-OF-CONDUCT.md`](./CODE-OF-CONDUCT.md), which is the authoritative disclosure. |
| **Bilingual?** | English + Bangla ("বাংলা"), see "Bilingual content" section of `README.md`. |

## 2. Judging criteria acknowledgement

Hackathon evaluation explicitly considers (per §17 of `SPEC.md`):

1. **Public repo** — ✅ ready; visibility toggle is a one-step coordinator action (see §3 below).
2. **OSI license (MIT default)** — ✅ `LICENSE` file present.
3. **Incremental commits** — ✅ 17 commits on `main` at ticket #46; implementation commits reference ticket numbers in their messages (`#01`, `#02`, `#03`, `#04`, `#05`, `#10`, `#12`, `#18`, `#21`, `#23`, `#29`, `#35`, plus this `#46`). View history with `git log --oneline`.
4. **AI-tool disclosure** — ✅ `AI-TOOLS.md` + README section.
5. **Bilingual-capable README** — ✅ README has both English and Bangla sections.
6. **Submission form** — ⏳ Awaiting coordinator input — see §3.
7. **Judging weights acknowledged** — ✅ this file. (See §3 below.)
8. **GitHub-stars / presentability** — ✅ README, ARCHITECTURE place-holder, LICENSE, CODE-OF-CONDUCT, SUBMISSION, VERDICT, HANDOFF notes, and `docs/firestore-schema.md` all present at repository root.

### Judging-weights acknowledgement

The hackathon organisers' published rubric and weighting were **not** stored in
this repository, so this document does **not** claim to reproduce them.
Submission #46 acknowledges that the project will be evaluated against whatever
weights the organisers publish, and the coordinator should record the
authoritative rubric here before the external submission form is submitted.
RelayLink's §17 disclosure package is intended to satisfy the "open-source
completeness" and "presentation" criteria without committing to numeric
weights that have not been verified.

## 3. Manual checklist — what still requires the coordinator

These items are listed for transparency. **They are not claimed as complete here.**
Each is something the coordinator must do (or has already done) outside the
repo; documenting them here makes "who owns this" unambiguous.

- [ ] **(M1)** Toggle the GitHub repository visibility to **public**. *Automation cannot do this on the participant's behalf.* Run: `gh repo edit Azm1ne/July-2026-hackathon --visibility public --accept-visibility-change` — then verify with `gh repo view Azm1ne/July-2026-hackathon --json visibility`.
- [ ] **(M2)** Fill in and submit the hackathon's external submission form. The fields are in §1 above; the form is at the link provided by the organisers.
- [ ] **(M3)** Cross-check ARCHITECTURE.md content when ticket #44 lands and merge the canonical architecture document (currently a place-holder stub). Until then, ARCHITECTURE.md points readers at `SPEC.md` and `STRESS-TEST.md` for the layered design.
- [ ] **(M4)** If the second-language choice for the bilingual README is to be changed away from Bangla, update the corresponding section in `README.md` and this file. The current default is Bangla because it is the developer's strongest second language and is not represented elsewhere in the project's docs.
- [ ] **(M5)** Run the two-device integration scenario from ticket #45 on physical hardware and capture the demo video; embed it in `README.md` (or link to it). This is a manual hands-on step.
- [ ] **(M6)** Push the local commits to `origin/main` *only after* §17 deliverables (LICENSE, README bilingual, AI-TOOLS, CODE-OF-CONDUCT, SUBMISSION, ARCHITECTURE place-holder) are visible in the working tree. This repo's `worktree-agent-ad2b25bd` branch has the local commits; `origin/main` may already be current. Verify with `git log --oneline origin/main | head -3`.

## 4. Tickets referenced by this submission

- `#01` Flutter scaffold — landed
- `#02` Device identity — landed
- `#03` BROADCAST crypto — landed
- `#04` Message schema — landed
- `#05` Local storage helpers — landed
- `#10` Bloom filter encoding — landed
- `#12` D5 verdict on Double Ratchet — landed (verdict: **NOT USABLE**, binding fallback to HKDF-chain for #13)
- `#18` Firestore stub — landed
- `#21` Gateway toggle UI + safety warning — landed
- `#23` SMS platform channel — landed
- `#29` Capability detection — landed
- `#35` Verified orgs allowlist — landed
- `#13`, `#14`, `#19`, `#20`, `#22`, `#24`–`#28`, `#30`–`#34`, `#36`, `#37`, `#38`–`#45` — see `.scratch/relaylink-build/issues/` and per-ticket status. The honest "What this demo does and doesn't prove" section of the README (per ticket #43) lists which of these shipped in time and which were deferred per `STRESS-TEST.md` §4.
- **`#46` (this ticket)** — landed locally on the worktree branch, awaiting coordinator push.

## 5. Reproduction quick-start

```bash
git clone https://github.com/Azm1ne/July-2026-hackathon.git
cd July-2026-hackathon
flutter pub get
flutter run -d <android-device-or-emulator>
```

For the two-device mesh demo, see `STRESS-TEST.md` §6 and the script in
`tools/demo_two_device.md` (added by ticket #45 when that lands).

## 6. Where judges should look first

- 5-minute read: `README.md` → "What this demo does and doesn't prove" section.
- Architecture mental model: `ARCHITECTURE.md` (stub for now; canonical content
  lands with ticket #44).
- Honest scope: `STRESS-TEST.md` §2 (floor), §3 (priority order), §4 (cut list).
- Decision history (D1–D8): `.working-memory.md` and `VERDICT.md`.
- Submission form fields: the table at §1 of this document.
- Code of Conduct / data disclosure: `CODE-OF-CONDUCT.md`.
- AI tooling used: `AI-TOOLS.md`.
