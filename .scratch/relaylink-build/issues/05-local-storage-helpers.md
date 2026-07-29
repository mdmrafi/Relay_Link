# 05 — Local storage helpers (sqflite + secure storage wrappers)

**What to build:** `lib/storage/` directory with two thin wrappers: `LocalDb` (sqflite) for messages, seen-cache, vault records; `SecretsStore` (flutter_secure_storage) for keys. Tables: `messages` (id, json blob, received_at), `seen_cache` (id, first_seen_at), `vault_records` (id, ciphertext, created_at, recipient_id, status).

**Blocked by:** #01

**Status:** ready-for-agent

- [ ] Database initialized on first launch; migrations defined for schema bumps
- [ ] `LocalDb.insertMessage(msg)`, `getMessage(id)`, `listMessages(limit, offset)`, `pruneOlderThan(timestamp)` work
- [ ] `LocalDb.markSeen(id)`, `isSeen(id)`, `listSeenIds()` work (for the seen-cache in mesh layer)
- [ ] `LocalDb.insertVaultRecord(rec)`, `listVaultRecords()`, `deleteVaultRecord(id)` work
- [ ] `SecretsStore` exposes typed `getIdentity()`, `setIdentity()`, plus arbitrary `getSecret(key)`/`setSecret(key, value)`
- [ ] Tests use an in-memory or temp-dir database (no test pollution)