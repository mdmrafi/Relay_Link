# 03 — BROADCAST crypto (AES-256-GCM with default public key)

**What to build:** `lib/crypto/broadcast.dart` exposing `BroadcastCrypto` with: a `networkKey` constant for the default public channel (`channel_id = "public"`), encrypt(plaintext, channelId) → ciphertext+nonce+tag, decrypt(ciphertext, channelId) → plaintext or throws on tamper, channel-key registration so non-default channels can be added at runtime.

**Blocked by:** #01

**Status:** ready-for-agent

- [x] AES-256-GCM used (via `cryptography` package), not hand-rolled
- [x] Default `networkKey` for `"public"` channel shipped in source (caveat: deters casual eavesdropping, not a resourced adversary — documented in README and inline comment)
- [x] Round-trip encrypt/decrypt unit tests pass
- [x] Tampering test: flip a bit in ciphertext → decrypt throws, no plaintext leaked
- [x] Custom channel keys can be registered at runtime via a `setChannelKey(channelId, key)` method
- [x] Decryption of a message from a channel we don't have a key for throws a typed exception (not a generic one) so callers can distinguish "wrong key" from "bug"