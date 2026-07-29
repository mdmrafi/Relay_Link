# 09 — Mesh relay with TTL decrement + seen-cache

**What to build:** Mesh-level relay logic: when a message arrives that's not addressed to me (different `recipient_id` for DIRECT, or just any BROADCAST not from me), check seen-cache by `id`, if unseen and `hop_count > 0`, decrement and re-broadcast to all connected peers. Otherwise drop.

**Blocked by:** #08, #05

**Status:** ready-for-agent

- [ ] On receive, check `seen_cache` for message id
- [ ] If seen, drop silently
- [ ] If unseen and `hop_count <= 0`, mark seen, don't relay
- [ ] If unseen and `hop_count > 0`, mark seen, decrement, re-broadcast to peers except sender
- [ ] Don't relay messages where I'm the sender (avoid loops)
- [ ] Seen-cache backed by sqflite (`LocalDb.markSeen`, `isSeen` from #05)
- [ ] Cap seen-cache: when size exceeds 2000 IDs, evict oldest first within lowest priority tier (priority order: SOS > STATUS_HELP > ALERT > ACK > STATUS_SAFE > CHAT)
- [ ] Test: simulate a 3-message chain through a virtual peer, confirm relaying happens exactly once per message