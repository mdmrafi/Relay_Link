# 11 — Bloom-filter peer-sync on connect

**What to build:** Mesh-layer sync: when a peer connects, both sides exchange their Bloom filters of recently-seen message IDs, then each side computes the symmetric difference (its seen minus peer's seen) and pushes any messages the peer is missing. Implementation lives in `lib/mesh/sync.dart`, hooked into the connect event from discovery (#07).

**Blocked by:** #09, #10

**Status:** ready-for-agent

- [ ] On peer connect: build Bloom filter from local seen-cache IDs, send to peer
- [ ] Receive peer's Bloom filter, compute "messages I have that peer might be missing" via my local message store ∩ NOT peer's filter
- [ ] Push those messages to the peer
- [ ] Receive pushed messages, run through normal relay pipeline (#09) — they're new to us, so we add to seen-cache and re-broadcast
- [ ] Test: simulate two devices with overlapping-but-not-identical message histories; verify all missing messages get pushed, none duplicated
- [ ] README documents Bloom-filter false-positive trade-off (occasional missed relay accepted for efficiency)