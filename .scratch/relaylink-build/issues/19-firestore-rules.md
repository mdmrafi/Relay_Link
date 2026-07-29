# 19 — Firestore security rules

**What to build:** `firestore.rules` and `storage.rules` files with: rate limits (max 60 writes/minute/device), size limits (max 16KB per document for messages, 5MB per object for evidence), read/write auth based on pseudonymous sender_id matching device identity, no anonymous read access. Also locked-down Storage rules: only the recipient can read an evidence blob.

**Blocked by:** #18

**Status:** ready-for-agent

- [ ] `firestore.rules` enforces rate limit (60 writes/min/device) via request timestamp check
- [ ] Size limit enforced (reject writes > 16KB for message docs)
- [ ] Read access: any device can read `relay/{channel_id}/messages` (relay-by-design), `relay_direct/{recipient_id}/messages` readable only by devices whose sender_id matches recipient_id
- [ ] `verified_orgs` collection: read-only to all, write-only via Firebase console (admin SDK)
- [ ] `storage.rules`: evidence blobs readable only by the device whose sender_id matches the recipient_id encoded in the path
- [ ] Test the rules using the Firebase emulator: a malicious client cannot POST 1000 messages in 1 second, cannot read someone else's direct messages
- [ ] Rules are committed to the repo with comments explaining each line