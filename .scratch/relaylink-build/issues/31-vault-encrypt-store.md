# 31 — Vault encrypt-at-rest + storage

**What to build:** `lib/vault/store.dart` exposing `VaultRecord` and `VaultStore`: `capture(text, recipientId?, selfOnly)` encrypts the text with AES-256-GCM using a per-record key sealed under a vault-wrapping key (which itself is sealed under the device identity from #02), inserts into `vault_records` table from #05.

**Blocked by:** #03, #02, #05

**Status:** ready-for-agent

- [ ] `VaultRecord.capture(text, recipientId?)` returns a record with ciphertext + metadata
- [ ] Encryption chain: text → AES-GCM (per-record key) → wraps per-record key with vault-wrapping key → wraps vault-wrapping key with device identity derived key (HKDF, domain "vault-wrap-v1")
- [ ] Stored in sqflite `vault_records` table
- [ ] Decrypt round-trip: read record, unwrap keys, decrypt text, verify, return plaintext
- [ ] Self-encrypted case (no recipientId) works — the device can decrypt any time
- [ ] Tampering test: flip a bit in ciphertext → decrypt throws, no plaintext leaked