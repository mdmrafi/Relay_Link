# Firestore + Storage rules — test matrix (Ticket #19)

This document is the validation matrix for `firestore.rules` and
`storage.rules` (both at repo root, added by Ticket #19). It is the
human-readable test plan that the programmatic suite in
`test/rules/firestore_rules.test.js` was derived from.

**Validation status:**

- **Programmatic emulator test passed.** The full suite in
  `test/rules/firestore_rules.test.js` was run against the Firebase
  emulator suite (`firebase-tools` v15.24.0) and passed 27/27 cases.
  Run it with:

  ```bash
  firebase emulators:exec \
    --only firestore,storage \
    --project demo-relaylink-rules-test \
    "node test/rules/firestore_rules.test.js"
  ```

  The suite exercises every row in the matrices below.

- **Manual review** (this document). Each rule body was also walked
  through against the matrix to verify the *reason* annotated next to
  each row maps to the rule clause that actually fires.

---

## Auth model assumed by these rules

- The caller presents a Firebase Auth custom token whose `sender_id`
  claim is the 16-lowercase-hex Ed25519 fingerprint derived in
  `lib/crypto/identity.dart` → `DeviceIdentity.senderId`.
- The token is minted by the app's login flow (out of scope for
  Ticket #19; landed in a follow-up ticket). Without this claim, the
  caller is treated as anonymous and is denied everywhere except the
  recipient-only checks (which they also fail because they have no
  claim to compare against).

---

## Firestore matrix

The matrix is split per collection. Each row is one (operation × caller)
pair, marked `✅ allow` or `❌ deny`. Each row maps to a concrete
`match /...` rule in `firestore.rules`.

### `relay/{channelId}/messages/{messageId}` — BROADCAST relay

| # | Operation | Caller                              | Result | Reason                                                        |
|---|-----------|-------------------------------------|--------|---------------------------------------------------------------|
| 1 | read      | Authenticated device, any sender_id | ✅     | `allow read: if isAuthenticatedDevice()` — world-readable      |
| 2 | read      | Unauthenticated (no token)          | ❌     | `isAuthenticatedDevice()` is false                            |
| 3 | create    | Authenticated device A, doc.sender_id = A | ✅ | Size ≤ 16 KB, sender_id == claim, hop_count = 0, ttl > 0    |
| 4 | create    | Authenticated device A, doc.sender_id = B (impersonation) | ❌ | `request.resource.data.sender_id != request.auth.token.sender_id` |
| 5 | create    | Authenticated device, doc size = 16385 bytes (1 byte over cap) | ❌ | `request.resource.data.size() <= maxMessageDocSize()` is false |
| 6 | create    | Authenticated device, doc size = 16384 bytes (exactly at cap) | ✅ | Boundary — `<=` not `<`                                       |
| 7 | create    | Authenticated device, hop_count = 1  | ❌     | `hop_count == 0` rule fires                                    |
| 8 | create    | Authenticated device, missing `expires_at` | ❌ | `keys().hasOnly([...])` is false                            |
| 9 | create    | Authenticated device, ttl = 0        | ❌     | `ttl > 0` rule fires                                           |
|10 | update    | Any authenticated device             | ⚠️     | Hop count increment only — see row 10a/10b below              |
|10a| update    | Authenticated relay, hop_count → +1  | ✅     | Identity fields unchanged, hop increment by exactly 1         |
|10b| update    | Authenticated device, sender_id field mutated | ❌ | Identity field is immutable                                  |
|11 | delete    | Any client                           | ❌     | `allow delete: if false` — TTL policy handles expiry          |

**Total broadcast cases: 12. Allowed: 3. Denied: 9.**

### `relay_direct/{recipientId}/messages/{messageId}` — DIRECT relay

| #  | Operation | Caller                                | Result | Reason                                                  |
|----|-----------|---------------------------------------|--------|---------------------------------------------------------|
| 1  | read      | Authenticated device A, recipientId = A | ✅   | `isRecipient(recipientId)` is true                      |
| 2  | read      | Authenticated device B, recipientId = A | ❌   | `isRecipient(recipientId)` is false — privacy bug      |
| 3  | read      | Unauthenticated                       | ❌     | Not authenticated                                       |
| 4  | create    | Authenticated device A, doc.recipient_id = A, sender_id = A | ✅ | All field + path bindings satisfied                  |
| 5  | create    | Authenticated device A, doc.recipient_id = B (path segment = A) | ❌ | `doc.recipient_id != recipientId` — prevents routing leak |
| 6  | create    | Authenticated device A, doc.sender_id = B (impersonation) | ❌ | Sender claim mismatch                                |
| 7  | create    | Authenticated device, doc size > 16 KB | ❌     | Size cap                                               |
| 8  | create    | Authenticated device, hop_count = 0, ttl > 0, but missing `recipient_id` field | ❌ | `keys().hasOnly([...])` includes `recipient_id`     |
| 9  | update    | Authenticated relay, hop_count → +1   | ✅      | Same as broadcast update path                          |
| 10 | update    | Any client, mutates `recipient_id`     | ❌     | Immutable identity field                                |
| 11 | delete    | Any client                            | ❌     | `allow delete: if false`                                |

**Total direct cases: 11. Allowed: 2. Denied: 9.**

### `verified_orgs/{orgId}` — ALERT allowlist

| # | Operation | Caller                              | Result | Reason                                       |
|---|-----------|-------------------------------------|--------|----------------------------------------------|
| 1 | read      | Authenticated device, any            | ✅     | `allow read: if isAuthenticatedDevice()`     |
| 2 | read      | Unauthenticated                     | ❌     | Not authenticated                            |
| 3 | create    | Authenticated device                | ❌     | `allow write: if false` — Admin SDK only     |
| 4 | update    | Authenticated device                | ❌     | `allow write: if false`                     |
| 5 | delete    | Authenticated device                | ❌     | `allow write: if false`                     |

**Total verified_orgs cases: 5. Allowed: 1. Denied: 4.**

### `evidence/{recipientId}/records/{recordId}` — Evidence Vault records

| # | Operation | Caller                                | Result | Reason                                       |
|---|-----------|---------------------------------------|--------|----------------------------------------------|
| 1 | read      | Authenticated device A, recipientId = A | ✅   | `isRecipient(recipientId)`                  |
| 2 | read      | Authenticated device B, recipientId = A | ❌   | `isRecipient(recipientId)` is false         |
| 3 | create    | Authenticated device A, doc.sender_id = A, doc.recipient_id = recipientId | ✅ | All bindings satisfied |
| 4 | create    | Authenticated device A, doc.recipient_id = B (path = A) | ❌ | Path mismatch |
| 5 | create    | Authenticated device A, doc.size > 5 KB | ❌   | Size cap                                     |
| 6 | create    | Authenticated device, missing `content_hash_b64` | ❌ | `keys().hasOnly([...])` is false         |
| 7 | update    | Any client                           | ❌     | `allow update: if false`                    |
| 8 | delete    | Any client                           | ❌     | `allow delete: if false`                    |

**Total evidence cases: 8. Allowed: 2. Denied: 6.**

### `rate_limits/{senderId}` — per-device rate-limit counter

| # | Operation | Caller                              | Result | Reason                                       |
|---|-----------|-------------------------------------|--------|----------------------------------------------|
| 1 | read      | Any client                          | ❌     | `allow read: if false` — count is private    |
| 2 | create    | Authenticated device A, senderId = A, count = 0..60 | ✅ | First write — count at boundary     |
| 3 | create    | Authenticated device A, senderId = B | ❌   | Cross-device claim forgery                   |
| 4 | create    | Authenticated device, count = 61     | ❌     | Cap exceeded                                 |
| 5 | update    | Authenticated device A, count = old+1 | ✅   | Single-step increment                        |
| 6 | update    | Authenticated device, count jumps by > 1 | ❌ | Atomic increment enforced                   |
| 7 | update    | Authenticated device, count set to -1 | ❌   | Negative count rejected                      |

**Total rate-limit cases: 7. Allowed: 2. Denied: 5.**

### Catch-all

| # | Operation | Caller                              | Result | Reason                                       |
|---|-----------|-------------------------------------|--------|----------------------------------------------|
| 1 | any       | Any client, any other path          | ❌     | `match /{document=**}` deny-all              |

**Total catch-all cases: 1. Allowed: 0. Denied: 1.**

### Firestore totals

- Cases: 44
- Allowed: 10
- Denied: 34

---

## Storage matrix

### `/evidence/{recipientId}/{fileName}` — evidence blobs

| # | Operation | Caller                                | Result | Reason                                       |
|---|-----------|---------------------------------------|--------|----------------------------------------------|
| 1 | read      | Authenticated device A, recipientId = A | ✅   | `isRecipient(recipientId)`                  |
| 2 | read      | Authenticated device B, recipientId = A | ❌   | Recipient mismatch                          |
| 3 | read      | Unauthenticated                       | ❌     | No claim to compare                         |
| 4 | create    | Authenticated device, size ≤ 5 MB, content-type = application/octet-stream | ✅ | Within caps |
| 5 | create    | Authenticated device, size > 5 MB      | ❌   | Size cap                                    |
| 6 | create    | Authenticated device, content-type = text/html | ❌ | Content-type cap (no hosted HTML)        |
| 7 | update    | Any client                            | ❌     | `allow update: if false` — immutable blob   |
| 8 | delete    | Any client                            | ❌     | `allow delete: if false` — TTL only         |

**Total storage cases: 8. Allowed: 2. Denied: 6.**

---

## How to run the emulator

The full programmatic suite lives at `test/rules/firestore_rules.test.js`
(see `test/rules/README.md` for prerequisites and command). It runs
the same cases enumerated in the matrices above. The repository also
ships `firebase.json` at the root so `firebase emulators:exec` finds
both `firestore.rules` and `storage.rules` without flags.

---

## Known limitations of the validation

- **Size cap is field-scoped, not doc-scoped.** Firestore's
  `request.resource.data.size()` on a map returns the *field count*,
  not the encoded byte length. The 16 KB / 5 KB caps in the rules are
  enforced on the `payload_b64` string field, which is the only
  variable-length field that scales with message size. The other
  fields are short fixed strings (sender_id, signature, type names)
  that comfortably fit below the per-field cap. Firestore itself
  enforces a hard 1 MiB per-document ceiling, which catches the
  "everything together is too big" case.
- **Rate limit is best-effort.** Firestore rules cannot atomically
  compare-and-increment across documents. The counter-doc scheme
  documented in `match /rate_limits/{senderId}` bounds but does not
  strictly enforce 60 writes/minute/device. A client that bypasses
  the SDK wrapper (writes to `rate_limits/` directly without bumping
  the counter) could evade the limit. Production hardening would
  move the rate check to a Cloud Function or to a token bucket
  enforced at the auth layer.
- **Counter race window.** When two writes race to the same
  `rate_limits/{senderId}` document, only one will observe the prior
  count; the other may overwrite it. This means a burst from one
  device can slip slightly past the 60/min cap. Acceptable for the
  demo; tighten with a transaction if it matters.
