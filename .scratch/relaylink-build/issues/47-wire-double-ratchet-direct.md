# 47 — Wire DoubleRatchetSession into DIRECT transports (#H2)

**What to build:** Replace the HKDF-chain session used by DIRECT transports with the
real `DoubleRatchetSession` that already exists in the library. Concretely:

* Extend `Message` with a `ratchetHeader` field (per `DoubleRatchetSession`'s
  header shape — public key + counter + previous chain length) so the header
  can survive the JSON wire-format.
* Swap `DirectSession` → `DoubleRatchetSession` at the two call sites where
  DIRECT messages are encoded/decoded.
* Re-run `direct_adapter_test.dart` and `internet_test.dart` red-green.

**Why:** The README + ARCHITECTURE docs currently describe the
Double-Ratchet transport as "library-only, tested, not wired". The library
already has a working DoubleRatchetSession; the only missing pieces are the
schema change and the call-site swap. Until this lands, the deployment story
is misleading — the production crypto path is HKDF-chain, not what's stated.

**Blocked by:** None. The library code and unit tests already exist.

**Status:** pending

**Acceptance criteria:**
- [ ] `Message.ratchetHeader` added to the wire-format (with
      `copyWith`/`fromJson`/`toJson` round-trip coverage).
- [ ] `DirectSession` removed from the DIRECT encoding path; both call sites
      use `DoubleRatchetSession`.
- [ ] `direct_adapter_test.dart` red-green with the new session.
- [ ] `internet_test.dart` red-green with the new session.
- [ ] README + ARCHITECTURE update: change "HKDF-chain is the production
      path" → "Double Ratchet is the production path" in the relevant
      paragraphs.
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings` clean.
- [ ] Full Flutter test suite green.

**TDD note:** Per project policy, write the failing tests first, watch them
fail for the right reason, then implement. Start with the `Message`
extension — that's the lowest-leverage refactor; the call-site swap comes
after.
