# 13 — DIRECT crypto (Double Ratchet OR HKDF-chain fallback)

**What to build:** `lib/crypto/direct.dart` exposing `DirectSession` for encrypt/decrypt of DIRECT messages. Initial state bootstrap from a shared secret (one-shot X25519 ECDH from #02). If D5 verdict (#12) is USABLE, integrates the ratchet package. If NOT USABLE, ships HKDF-chain-only: per-message `key_n = HKDF(key_{n-1}, "rl-msg-v1")`, message key discarded after use, no skipped-key storage.

**Blocked by:** #02, #12

**Status:** complete

**Path taken:** HKDF-chain fallback (D5 verdict from #12 was NOT USABLE — see VERDICT.md).

- [x] `DirectSession.create(sharedSecret, isInitiator)` constructs an initial session state
- [x] `encrypt(plaintext)` returns ciphertext + ratchet_header (with msg_index, direction_byte)
- [x] `decrypt(ciphertext, ratchet_header)` returns plaintext or throws on tamper
- [ ] If ratchet package: skipped-key map capped at 1000 entries; out-of-order delivery handled (N/A — HKDF-chain path; skipped-key storage intentionally omitted, documented in code)
- [x] If HKDF-chain fallback: forward secrecy demonstrated (compromise of key_N does not expose messages 1..N-1)
- [x] README discloses which path was taken and why
- [x] Integration test: two sessions encrypt/decrypt round-trip 5 messages, all decrypt correctly

## Implementation notes

* Library: `lib/crypto/direct.dart` exposes `DirectSession` with a synchronous-style async API matching `BroadcastCrypto`.
* Chain design: two independent roots per direction (Alice→Bob, Bob→Alice) derived via HKDF over the shared secret with direction tag mixed into the info. The next chain key is `HMAC-SHA256(chain_key, [0x02])` and the per-message key is `HKDF(HMAC-SHA256(chain_key, [0x01]), info=<dir><idx>, out=64)`. The first 32 bytes are the AES-256 key; the trailing 32 bytes are reserved for a future MAC key.
* Direction byte 0x01 = Alice→Bob, 0x02 = Bob→Alice (matches `libsignal_protocol_dart` `chain_key.dart` seed-byte convention, though we are NOT bit-compatible).
* Nonce is deterministic per `(direction, msgIndex)` — safe because each message uses a unique AES key.
* `DirectMessage.chainKeyAfterMessage` carries the chain key AFTER `encrypt` advanced, so the forward-secrecy test can simulate a compromise of key_n by `DirectSession.fromChainKey(..., nextMessageIndex: n)`.
* The ratchet header is intentionally minimal: `msgIndex` and `directionByte`. There is no DH public key / prev_chain_len because this is the symmetric-chain fallback, not Double Ratchet.

## Limitations (per design — be honest)

* **Forward secrecy (yes):** compromising the chain key at message N cannot recover message keys for messages 1..N-1, because HMAC is one-way. Demonstrated in `test/crypto/direct_test.dart` "forward secrecy…" test.
* **Post-compromise secrecy (no):** a leaked current chain key exposes all future keys until the chain is re-seeded. For the hackathon demo this is acceptable; per §6.3 a full Double Ratchet would be required for production.
* **No skipped-key storage:** out-of-order decryption is impossible once a message has been skipped past. This was an optional ticket acceptance criterion. Skipped-key storage is the natural extension point if needed.
* **Mutability:** `DirectSession` holds mutable state (chain keys, counters) because each `encrypt`/`decrypt` advances the chain. Tests instantiate fresh sessions per scenario.
