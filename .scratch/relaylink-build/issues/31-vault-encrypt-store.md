# 31 — Vault encrypt-at-rest + storage

**What to build:** `lib/vault/store.dart` exposing `VaultRecord` and `VaultStore`: `capture(text, recipientId?, selfOnly)` encrypts the text with AES-256-GCM using a per-record key sealed under a vault-wrapping key (which itself is sealed under the device identity from #02), inserts into `vault_records` table from #05.

**Blocked by:** #03, #02, #05

**Status:** done

- [x] `VaultRecord.capture(text, recipientId?)` returns a record with ciphertext + metadata
- [x] Encryption chain: text → AES-GCM (per-record key) → wraps per-record key with vault-wrapping key → wraps vault-wrapping key with device identity derived key (HKDF, domain "vault-wrap-v1")
- [x] Stored in sqflite `vault_records` table
- [x] Decrypt round-trip: read record, unwrap keys, decrypt text, verify, return plaintext
- [x] Self-encrypted case (no recipientId) works — the device can decrypt any time
- [x] Tampering test: flip a bit in ciphertext → decrypt throws, no plaintext leaked

## Implementation notes

* `lib/vault/store.dart` defines `VaultRecord` (with `ciphertext`,
  `perRecordKeyWrapped`, `nonce`, `aad`, `createdAt`, `recipientId`)
  and `VaultStore` (`capture`, `list`, `get`, `decrypt`, plus a
  production `instance` and a test-friendly `create` factory).
* `lib/crypto/identity.dart` gains a `deriveKeyMaterial(info, length)`
  method that uses the Ed25519 private seed as HKDF input keying
  material (HKDF-SHA256, `cryptography` package). The raw private
  seed never leaves the identity object — callers receive only
  domain-separated derived bytes.
* `lib/storage/local_db.dart` schema bumped **v1 → v2**: `vault_records`
  gains `per_record_key_wrapped`, `nonce`, and `aad` columns. The
  migration is idempotent (`PRAGMA table_info` guard) so it can be
  re-applied. A new `LocalDb.createV1Sql` getter exposes the v1 DDL
  so migration tests can spin up a strict v1 database.
* `flutter_secure_storage` holds a 60-byte wrapped vault-wrapping key
  blob (`nonce(12) || ciphertext(32) || mac(16)`, base64-encoded)
  under `vault_wrap_key_v1`. The wrapping key is the
  `vault-wrap-v1`-derived HKDF output of the Ed25519 seed.