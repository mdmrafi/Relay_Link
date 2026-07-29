# 20 — Direct internet messaging (own traffic, no toggle)

**What to build:** `lib/transport/internet.dart` implementing `Transport` over Firestore. On `send`: push to `relay/{channel_id}/messages` for BROADCAST or `relay_direct/{recipient_id}/messages` for DIRECT, with `expires_at` set to now+2h. On receive: poll collections on a 30s interval when online, decrypt any new entries, emit via `incoming` Stream. Auto-active when device has internet, no user toggle.

**Blocked by:** #06, #18, #19, #03, #13

**Status:** ready-for-agent

- [ ] `InternetTransport implements Transport`, `isAvailable()` returns true iff device has internet
- [ ] `send` writes to correct collection per message mode and channel
- [ ] Polling loop runs every 30s when online; gracefully exits when offline
- [ ] Received entries are added to seen-cache, TTL decremented, re-broadcast via TransportManager (matches spec §9's "received-via-SMS messages re-enter normal pipeline" — same applies here)
- [ ] No toggle UI — this is automatic per spec §10 "Direct Internet Messaging"
- [ ] README discloses: "your own internet traffic uses the relay automatically; this is no new exposure beyond having internet"