# 17 — Channel routing (tag-aware relay + multi-channel membership)

**What to build:** Mesh-layer change: when relaying a message in #09, also tag the BROADCAST message's `channel_id` and confirm the recipient can decrypt it. Devices that don't have the channel key still relay the message (per spec §6.2, since routing metadata is plaintext) but display nothing for it. Implements multi-channel membership: a device can hold keys for many channels and decrypt messages from each.

**Blocked by:** #09, #15

**Status:** ready-for-agent

- [ ] Mesh relay layer passes `channel_id` along unchanged
- [ ] On display, attempt decrypt with `getChannelKey(channel_id)` from #15
- [ ] If key absent and mode=BROADCAST: skip silently (don't show, don't error)
- [ ] If key absent and mode=DIRECT: also skip (a DIRECT message for a channel we're not in isn't for us)
- [ ] If decrypt fails with AEAD error: skip and log a warning (tampering or wrong key)
- [ ] Manual demo: device A in custom channel "demo", device B not in channel — A sends, B relays (verify in B's seen-cache), B doesn't display. C also in "demo" — C receives from B's relay, decrypts, displays.