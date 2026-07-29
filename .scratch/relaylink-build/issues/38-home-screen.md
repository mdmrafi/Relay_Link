# 38 — Home screen

**What to build:** `lib/screens/home.dart` — the landing screen after first launch. Shows: device's own SenderId (short pseudonymous string), count of connected peers, status of each transport (mesh ✓/✗, SMS ✓/✗, internet ✓/✗), recent activity count.

**Blocked by:** #29, #08, #20, #26, #26

**Status:** ready-for-agent

- [ ] Header shows "RelayLink" + own SenderId (truncated)
- [ ] Transport status row with ✓/✗ for each, updated in real time
- [ ] Peer count badge
- [ ] Recent activity (count of messages sent/received in last 24h)
- [ ] Tap a transport status to navigate to that transport's screen (e.g., tap mesh → mesh peers list)
- [ ] Tab bar to other screens: Chat, Vault, Channels, Settings