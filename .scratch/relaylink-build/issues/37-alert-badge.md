# 37 — ALERT verified badge in UI

**What to build:** When displaying an ALERT message, look up the sender's public key in `VerifiedOrgsCache` (#36). If verified, show "Verified: [org name]" badge next to the message. If not verified, show "Signed by: [display name]" standard label.

**Blocked by:** #36, #39 (chat/feed display)

**Status:** ready-for-agent

- [ ] ALERT messages display with the appropriate label based on allowlist lookup
- [ ] Verified badge visually distinct (color, icon) from the unsigned-by label
- [ ] Lookup is offline-first (uses #36's local cache)
- [ ] No field in the Message schema claims verification — verification is receiver-side only
- [ ] Manual demo: ALERT from a verified org shows badge; ALERT from unknown device does not