# AI Tool Disclosure

> Submission requirement (§17 of `SPEC.md` and ticket #46):
> "AI-tool disclosure: required in README — naming tools used and confirming
> compliance with hackathon rules."
>
> This file is the authoritative disclosure. The README links here so its
> "AI Tool disclosure" section stays short.

## Tool used

| Tool | Team | Role | Where used |
|---|---|---|---|
| **Puku CLI (`puku-ai-2.7`)** | Puku AI team | AI coding assistant and intelligent model-request routing system used to draft, refactor, review, test, and document project changes in ticket-scoped git worktrees. | `.scratch/relaylink-build/issues/`, source and test directories, Android platform-channel code, and repository documentation. |

Puku can route eligible requests to a managed model pool. Depending on
configuration, availability, task complexity, quality requirements, latency,
cost, and user/workspace preferences, that pool may include Opus, Sonnet,
MiniMax, GLM, Kimi, OpenAI-compatible models, and other supported models.
Routing is dynamic and may change per request; this project does not have or
disclose a reliable per-request provider/model log. The exact live routing
decisions and private routing policies are not part of this disclosure.

Substantial portions of Dart/Flutter source, Kotlin platform-channel code,
ticket descriptions, commit messages, and documentation were drafted with
Puku CLI and then reviewed, edited, validated, and committed by the human
project owner.

## Compliance statement

1. **Disclosure is prominent.** This file is at the repository root and is
   linked from `README.md` and `SUBMISSION.md`.
2. **Human responsibility remains explicit.** The project owner reviews and
   approves repository changes and remains responsible for the submission.
3. **Work is ticket-scoped and reviewable.** AI-assisted changes are organized
   through `.scratch/relaylink-build/issues/` and incremental git commits.
4. **Established cryptographic primitives are used.** RelayLink relies on the
   Dart `cryptography` package for X25519, Ed25519, AES-256-GCM, and HKDF; it
   does not claim AI-generated cryptographic primitives.
5. **External submission remains manual.** Puku CLI does not submit the
   hackathon form or change repository visibility for ticket #46.

## Questions

Open an issue at
<https://github.com/Azm1ne/July-2026-hackathon/issues>.
