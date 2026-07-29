# 36 — Allowlist sync + local cache

**What to build:** `lib/alerts/allowlist.dart` exposing `VerifiedOrgsCache`: pulls `verified_orgs` from Firestore opportunistically (whenever app is online), persists a local copy in shared_preferences, exposes `isVerified(orgPublicKey)` returning bool. Cache invalidated on a 24-hour rolling basis.

**Blocked by:** #35, #18

**Status:** ready-for-agent

- [ ] First online launch: pulls allowlist, caches locally
- [ ] Subsequent launches (online or offline): use cache, refresh if > 24h old
- [ ] `isVerified(pubkey)` checks against cached set, returns true/false
- [ ] If allowlist collection is empty, no error — just `isVerified` always returns false
- [ ] Tests: cache hit, cache miss with refresh, cache miss with no refresh possible (offline) all behave correctly