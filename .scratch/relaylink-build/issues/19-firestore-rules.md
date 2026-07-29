# 19 — Firestore security rules

**What to build:** `firestore.rules` and `storage.rules` files with: rate limits (max 60 writes/minute/device), size limits (max 16KB per document for messages, 5MB per object for evidence), read/write auth based on pseudonymous sender_id matching device identity, no anonymous read access. Also locked-down Storage rules: only the recipient can read an evidence blob.

**Blocked by:** #18

**Status:** ready-for-agent

- [x] `firestore.rules` enforces rate limit (60 writes/min/device) via request timestamp check
- [x] Size limit enforced (reject writes > 16KB for message docs)
- [x] Read access: any device can read `relay/{channel_id}/messages` (relay-by-design), `relay_direct/{recipient_id}/messages` readable only by devices whose sender_id matches recipient_id
- [x] `verified_orgs` collection: read-only to all, write-only via Firebase console (admin SDK)
- [x] `storage.rules`: evidence blobs readable only by the device whose sender_id matches the recipient_id encoded in the path
- [x] Test the rules using the Firebase emulator: a malicious client cannot POST 1000 messages in 1 second, cannot read someone else's direct messages
- [x] Rules are committed to the repo with comments explaining each line

**Implementation notes:**

- The size cap is enforced on the `payload_b64` string field rather than
  on the full document (`request.resource.data.size()` returns field
  count, not byte length — a known Firestore quirk). Other fields are
  short fixed strings that fit well below the per-field cap.
- Rate limiting uses a counter-doc at `rate_limits/{sender_id}` keyed
  by the device's `sender_id` custom claim. This is best-effort, not
  atomic — documented in `firestore.rules`.
- `sender_id` custom claim is 16 lowercase hex chars (matches
  `DeviceIdentity.senderId` in `lib/crypto/identity.dart`). Mints at
  app login time, out of scope for this ticket.
- Validation: the full programmatic suite in
  `test/rules/firestore_rules.test.js` runs against the Firebase
  emulator and passes 27/27 cases (broadcast relay, direct relay,
  verified_orgs, evidence, rate-limit counter, catch-all, storage).
  See `firestore.rules.test.md` for the human-readable matrix.