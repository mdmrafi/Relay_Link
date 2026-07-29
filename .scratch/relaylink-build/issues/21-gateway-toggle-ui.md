# 21 — Gateway mode toggle UI + safety warning

**What to build:** `lib/features/gateway/toggle.dart` exposing a Settings tile "Act as gateway for nearby devices." Off by default. On tap-to-enable, presents the spec §10 safety warning verbatim, requires explicit confirm. Toggle state stored in shared_preferences. UI reflects current state. (This ticket is UI + state only; the relay code is in #22.)

**Blocked by:** #01

**Status:** ready-for-agent

- [x] Settings tile shows toggle state, switches on tap
- [x] Tap when off → display safety warning modal, "Confirm" required to enable
- [x] Tap when on → confirmation prompt "Turn off?", then disable
- [x] Safety warning text matches spec §10 word-for-word
- [x] Toggle state persists across app restarts
- [x] README discloses the toggle and links to the safety warning text