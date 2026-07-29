# CONTEXT.md — read this first

You are an agent working on RelayLink, a Flutter app for offline mesh messaging with E2E encryption, optional SMS/internet relay, and a text-only Evidence Vault. Read this before anything else.

## Where things live

- `SPEC.md` — the product spec (Problem Statement, Solution, User Stories, Implementation Decisions, Testing Decisions, Out of Scope). Read this to understand *what* you're building.
- `STRESS-TEST.md` — the cut list, landmine map, and decision log. Read this to understand *why* certain things were cut and what landmines exist.
- `.working-memory.md` — design decisions D1-D8 with reasoning. Read this if you need to understand why a decision was made.
- `.scratch/relaylink-build/issues/NN-<slug>.md` — the tickets. **Local files are the source of truth.**
- GitHub Issues at `github.com/Azm1ne/July-2026-hackathon` — mirror of tickets, tagged `ready-for-agent`. Use for assignment/visibility but trust the local files.

## Project state

- **Deadline:** 30 July 2026 23:59 BST
- **Repo:** `/home/azmine/Desktop/July-2026-hackathon` on `main` branch
- **Current state:** empty repo except this and the above docs. **No code yet.** Ticket #01 (Flutter scaffold) is the first thing to land.
- **Platform target:** Android (primary, full-featured), iOS (secondary, mesh + relevant subset). SMS features are Android-only per platform restrictions.

## How work is organized

- **Tickets are sized for ~150k-token context windows.** Each ticket is one narrow vertical slice or one prefactor step. Read the ticket, do the work, ship, move on.
- **Context is cleared between tickets.** Don't expect continuity from prior tickets — the codebase and your ticket file are your context.
- **Parallel agents are expected.** Multiple tickets can be worked simultaneously if their blockers are done.
- **Status:** "ready-for-agent" means the ticket's blockers are clear and you can pick it up. "in-progress" means someone is on it. "done" means merged and verified.

## Working on a ticket

1. Read the local ticket file (`.scratch/relaylink-build/issues/NN-<slug>.md`)
2. Read its "Blocked by" — confirm all blockers are actually done in the repo
3. Read any tickets it depends on if you need their interface contracts
4. Execute the acceptance criteria
5. Self-verify: run the acceptance checklist
6. Commit with a clear message referencing the ticket number
7. Update the ticket file's checkbox list

## Critical decision gates

These tickets have verdicts baked in. **Do not skip the verdict step:**

- **#12 (D5 verdict on Double Ratchet package, hour-6 deadline):** time-boxed to 1 hour. If the chosen Dart Signal Protocol package doesn't meet all three of (req 1) implements Double Ratchet, (req 2) X3DH-bypassable bootstrap, (req 4) Flutter Android build — fall back to HKDF-chain-only. The fallback decision is binding.
- **#13 (DIRECT crypto):** ships whichever path #12 decided.
- **#14 (Forward-secrecy demo):** depends on #13.
- **#11 (Bloom-filter peer-sync):** if integration slips past hour 14, fall back to bounded last-200-IDs sync. Document the trade-off in the README.
- **#22 (Gateway relay code):** if past hour 18 and unstable, ship toggle UI + safety warning (#21) with stubbed code path.

## Honesty requirements (the project values this)

- **Don't claim what you didn't build.** If a ticket's acceptance criteria can't all be met, document what was done, what wasn't, and why. The README's "What this demo does and doesn't prove" section depends on this.
- **Don't hand-roll crypto.** Use the `cryptography` Dart package for X25519, Ed25519, AES-256-GCM, HKDF. The spec explicitly forbids hand-rolling primitives.
- **Don't silently fall back.** If you hit a gate and need to fall back, write a note in the affected ticket file and update STRESS-TEST.md's decision log.

## Sub-decisions that need a human

If you encounter something that requires a human decision (not a technical call you can make yourself), don't make it unilaterally. Document the question in the affected ticket file as a `[DECISION-NEEDED]` comment and flag it to the coordinator.

## Submission

- README must be bilingual (English + one other language, to be chosen — coordinate with the coordinator if unsure)
- License: MIT
- AI-tool disclosure: required in README
- Code-of-Conduct data disclosure: required in README — exactly what data is collected (device ID, optional location, phone numbers via SMS, evidence capture) and why

## Don't

- Don't rewrite the spec, stress-test, or working memory without coordinating with the coordinator
- Don't publish to the main branch without verifying the ticket's acceptance criteria
- Don't push commits that don't reference a ticket number
- Don't break the local-is-source-of-truth contract — GH issues are mirrors, local files are authoritative
