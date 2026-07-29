# 41 — Channels screen (switcher, create, join via QR)

**What to build:** `lib/screens/channels.dart` — list of joined channels (always includes "public" + any custom), with switcher to set the active channel for chat. "Create Channel" generates a new key and shows the QR (#16). "Join Channel" scans a QR.

**Blocked by:** #15, #16

**Status:** ready-for-agent

- [ ] Channel list with current/active indicator
- [ ] Tap a channel to make it active (chat composer sends on that channel)
- [ ] Create channel flow: prompt for name → generate key → show QR
- [ ] Join channel flow: scan QR → confirm → add to joined list
- [ ] "public" channel cannot be left (always present)