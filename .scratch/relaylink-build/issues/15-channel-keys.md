# 15 — Channel key generation + storage

**What to build:** `lib/channels/keys.dart` exposing `ChannelKeyStore`: generate a new 256-bit key for a custom channel, store in flutter_secure_storage keyed by `channel_id`, list joined channels, get/set key for a channel.

**Blocked by:** #02, #03

**Status:** ready-for-agent

- [ ] `generateKey()` returns a fresh random 32-byte AES key
- [ ] `addChannel(channelId, key)` stores the key
- [ ] `getChannelKey(channelId)` returns the key, or null if not joined
- [ ] `listChannels()` returns all joined channel IDs
- [ ] "public" channel is auto-added on first launch with the default network key from #03
- [ ] Tests: generate, add, get, list round-trip works