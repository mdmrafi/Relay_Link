# 13 — DIRECT crypto (Double Ratchet OR HKDF-chain fallback)

**What to build:** `lib/crypto/direct.dart` exposing `DirectSession` for encrypt/decrypt of DIRECT messages. Initial state bootstrap from a shared secret (one-shot X25519 ECDH from #02). If D5 verdict (#12) is USABLE, integrates the ratchet package. If NOT USABLE, ships HKDF-chain-only: per-message `key_n = HKDF(key_{n-1}, "rl-msg-v1")`, message key discarded after use, no skipped-key storage.

**Blocked by:** #02, #12

**Status:** ready-for-agent

- [ ] `DirectSession.create(sharedSecret, isInitiator)` constructs an initial session state
- [ ] `encrypt(plaintext)` returns ciphertext + ratchet_header (with dh_public_key, prev_chain_len, msg_index)
- [ ] `decrypt(ciphertext, ratchet_header)` returns plaintext or throws on tamper
- [ ] If ratchet package: skipped-key map capped at 1000 entries; out-of-order delivery handled
- [ ] If HKDF-chain fallback: forward secrecy demonstrated (compromise of key_N does not expose messages 1..N-1)
- [ ] README discloses which path was taken and why
- [ ] Integration test: two sessions encrypt/decrypt round-trip 5 messages, all decrypt correctly