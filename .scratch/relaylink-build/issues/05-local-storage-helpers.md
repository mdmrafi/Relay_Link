# 05 — Local storage helpers (sqflite + secure storage wrappers)

**What to build:** `lib/storage/` directory with two thin wrappers: `LocalDb` (sqflite) for messages, seen-cache, vault records; `SecretsStore` (flutter_secure_storage) for keys. Tables: `messages` (id, json blob, received_at), `seen_cache` (id, first_seen_at), `vault_records` (id, ciphertext, created_at, recipient_id, status).

**Blocked by:** #01

**Status:** ready-for-agent

- [x] Database initialized on first launch; migrations defined for schema bumps
- [x] `LocalDb.insertMessage(msg)`, `getMessage(id)`, `listMessages(limit, offset)`, `pruneOlderThan(timestamp)` work
- [x] `LocalDb.markSeen(id)`, `isSeen(id)`, `listSeenIds()` work (for the seen-cache in mesh layer)
- [x] `LocalDb.insertVaultRecord(rec)`, `listVaultRecords()`, `deleteVaultRecord(id)` work
- [x] `SecretsStore` exposes typed `getIdentity()`, `setIdentity()`, plus arbitrary `getSecret(key)`/`setSecret(key, value)`
- [x] Tests use an in-memory or temp-dir database (no test pollution)