# RelayLink — Firestore + Storage Threat Model

**Cut #11 / Ticket #19** · Companion document to `firestore.rules` and `storage.rules`

This document explains, in human terms, what the RelayLink Firebase security rules block. It is a *reader-friendly* companion to the rule files; the rule files remain the authoritative implementation. Where the doc says "blocked", it points at the specific line that does the blocking. Where the doc says "best-effort", it means the rule is a guard, not a guarantee.

The threat model is written for the disaster-zone deployment context: a population of pseudonymous mobile devices coordinating during infrastructure outages, with selected peer organisations (BRAC, Red Crescent, etc.) allowlisted as verified senders.

---

## Table of Contents

1. [Assets](#1-assets)
2. [Adversaries](#2-adversaries)
3. [Threats (STRIDE per asset)](#3-threats-stride-per-asset)
4. [Mitigations (rule-by-rule)](#4-mitigations-rule-by-rule)
5. [Residual risks](#5-residual-risks)
6. [Out-of-scope threats](#6-out-of-scope-threats)

---

## 1. Assets

The rules protect the following logical assets. Each asset maps to a Firestore collection, a Storage path, or a field within a document.

| ID | Asset | Backing storage | Why it matters |
|----|-------|-----------------|----------------|
| **A-BROADCAST** | Per-channel broadcast messages | `relay/{channelId}/messages/{messageId}` (Firestore) | SOS / ALERT / chat traffic on the mesh. Encrypted to a channel key but the ciphertext is opaque to the server. |
| **A-DIRECT** | Per-recipient direct messages | `relay_direct/{recipientId}/messages/{messageId}` (Firestore) | One-to-one sealed messages. The whole point of DIRECT mode is that the server cannot disclose them to anyone except the recipient. |
| **A-EVIDENCE** | Evidence Vault text records | `evidence/{recipientId}/records/{recordId}` (Firestore) + `evidence/{recipientId}/...` (Storage) | Tamper-evident short text records. Used as evidence in crisis coordination. |
| **A-ORGLIST** | Verified-org allowlist | `verified_orgs/{orgId}` (Firestore) | The "verified" badge on ALERT messages. Each row binds a `public_key_b64` to a display name. |
| **A-SENDERID** | Pseudonymous sender id (custom claim) | Firebase Auth token claim `sender_id` | The single trust root that ties every rule check to a pseudonym. Minted from the device's Ed25519 fingerprint. |
| **A-EXPIRES** | Document expiry timestamp | `expires_at` field on every message / evidence doc | Drives the server-side TTL policy. Without it, deleted / overwrite semantics would leak. |
| **A-SCHEMA** | Document schema versioning | `keys().hasOnly([...])` clauses | The rules enforce a flat, closed schema per collection. Anything outside the schema is rejected. |
| **A-RATELIMIT** | Per-device rate-limit counter | `rate_limits/{senderId}` (Firestore) | Best-effort guard against a single device flooding the project. |
| **A-EVIDENCE-BLOB** | Encrypted evidence blobs | `evidence/{recipientId}/{fileName}` (Storage) | End-to-end encrypted — server sees ciphertext. Rules only enforce recipient access. |

---

## 2. Adversaries

The threat model focuses on adversaries that are *real* in the disaster-zone deployment context. We are not attempting to defend against a well-resourced state-level APT — that is materially infeasible and we are honest about it (see §6).

### A1 — Compromised legitimate user (their auth leaks)
A user's Firebase Auth custom token leaks (stolen device, MITM on a bad day, malicious app on the same device). The adversary can now sign as that user for the token's lifetime. **In scope.** The rules assume `request.auth.uid` and `request.auth.token.sender_id` are unforgeable but perishable.

### A2 — Malicious peer on the mesh
A device that joined the mesh with a legitimate `sender_id` (e.g. a community member whose device was compromised, or simply a misbehaving or curious participant). They can post messages, read broadcast messages, and try to manipulate ratchet headers / hop counts. **In scope.** The rules bound what they can do.

### A3 — Network observer / direct Firestore attacker
Someone who can read or write to the Firestore / Storage endpoints directly (intercepted TLS, leaked service-account key, leaked API key, or a malicious server-side script). They bypass the mobile client entirely. **In scope.** The rules are the only line of defence here — Firestore is the trust boundary.

### A4 — Compromised Firebase admin / project owner — **OUT OF SCOPE**
A compromised `firebase-admin` credential, or a malicious operator with the Firebase console open, can do anything: write to `verified_orgs/`, mint custom claims, delete the project. The rules cannot block this; the Admin SDK bypasses them by definition. We document this explicitly so the reader does not over-trust the rule layer. See §6.

### A5 — Insider at an allowlisted org
A rogue employee at BRAC / Red Crescent / etc. whose `public_key_b64` is already in `verified_orgs/`. They can sign valid ALERT messages that the mesh will mark as "verified". The rules treat them as a legitimate sender because they hold the private key. **Partially in scope.** The rules block impersonation of *orgs* (because clients cannot write `verified_orgs/` themselves), but the rules cannot block an insider who has the real key.

---

## 3. Threats (STRIDE per asset)

Threat IDs use the format `T-{asset}-{STRIDE-letter}-{index}`. For each threat we ask: can the attacker do X? If yes, then in §4 we cite the rule that blocks it.

### Spoofing

- **T-BROADCAST-S-1:** Can attacker forge a BROADCAST message from another sender id? *(A1, A2)* — Yes, by default. The rules block this by binding `sender_id` to the caller's custom claim.
- **T-DIRECT-S-1:** Can attacker forge a DIRECT message so the recipient sees it as from sender X? *(A1, A2)* — Same protection.
- **T-ORGLIST-S-1:** Can attacker create a row in `verified_orgs/` claiming to be e.g. "BRAC"? *(A3)* — Default-deny blocks client writes; Admin SDK only.
- **T-ORGLIST-S-2:** Can attacker forge a `public_key_b64` row to backdoor the verify-check? *(A5)* — Out of rule layer (insider holds the real key; the rule stores the public key verbatim).
- **T-EVIDENCE-S-1:** Can attacker write evidence claiming to be from another sender? *(A1, A2)* — Same custom-claim binding.

### Tampering

- **T-BROADCAST-T-1:** Can attacker modify a message in flight? *(A3)* — The signature is verified by the recipient offline; the rule layer cannot validate signatures (no public-key verify in Firestore rules). Hop-count / signature immutability is enforced by the update rule.
- **T-BROADCAST-T-2:** Can attacker edit their own message after posting? *(A1, A2)* — Updates are restricted to hop_count + 1 by relays; identity fields are immutable.
- **T-DIRECT-T-1:** Can attacker modify a direct message they sent? *(A1, A2)* — Same as above.
- **T-EVIDENCE-T-1:** Can attacker modify an evidence record after creation? *(A1, A2)* — `allow update: if false`; immutable.
- **T-EVIDENCE-T-2:** Can attacker overwrite an evidence blob in Storage? *(A3)* — `allow update: if false` (storage.rules:116).
- **T-ORGLIST-T-1:** Can attacker tamper with the allowlist? *(A3)* — `allow write: if false`; only Admin SDK can mutate it.
- **T-RATELIMIT-T-1:** Can attacker reset their own counter to bypass the rate limit? *(A1, A2)* — Update rule permits increment-by-1 only.
- **T-EXPIRES-T-1:** Can attacker back-date `expires_at` to keep a message forever? *(A1, A2)* — Update rule permits `hop_count` + 1 only; `expires_at` is not in the change path. *Residual:* the `expires_at` is mutable only by Admin SDK or by a relay that updates it (the rule does not currently freeze it on update — tightening this is one of the things Agent E is doing).

### Repudiation

- **T-BROADCAST-R-1:** Can a sender deny sending a message? *(A1)* — The signed envelope (`signature` field) is verified by the recipient; the server cannot help here. The rule does not block repudiation — *repudiation is a different problem* (it requires the signature to be present and verifiable on the recipient's device, which is the client's job, not the rule's).
- **T-DIRECT-R-1:** Same as broadcast.
- **T-EVIDENCE-R-1:** Evidence specifically has a `content_hash_b64` plus a `signature` — the rule enforces both fields are present and string-typed; cryptographic verification is client-side.

### Information disclosure

- **T-DIRECT-I-1:** Can attacker read another user's direct messages? *(A1, A2, A3)* — `allow read: if isRecipient(recipientId)` blocks all non-recipient reads.
- **T-EVIDENCE-I-1:** Can attacker read another user's evidence records? *(A1, A2, A3)* — Same recipient-only rule.
- **T-EVIDENCE-BLOB-I-1:** Can attacker fetch another user's Storage evidence blobs? *(A1, A2, A3)* — `storage.rules:91` (`allow read: if isRecipient(recipientId)`).
- **T-BROADCAST-I-1:** Can attacker read broadcast messages? *(A1, A2, A3)* — Broadcast is by design world-readable to authenticated devices. The ciphertext is opaque without the channel key. **Not a leak** — this is the SPEC.
- **T-ORGLIST-I-1:** Can attacker read the allowlist? — Yes, by design. The public keys are public.
- **T-RATELIMIT-I-1:** Can attacker read the rate-limit counter for another device? *(A1, A2, A3)* — `allow read: if false` (firestore.rules:185). Even the owner cannot read their own counter — this is intentional so a device cannot probe its own window boundary.
- **T-ANON-I-1:** Can an unauthenticated client scrape anything? — No. `isAuthenticatedDevice()` gates every read.

### Denial of service

- **T-BROADCAST-D-1:** Can attacker flood the project with million-doc messages? *(A1, A2, A3)* — Best-effort rate limit at 60 writes/min/device; 16 KB per-doc cap; world-readable broadcast but read bills are bounded by the TTL.
- **T-STORAGE-D-1:** Can attacker upload huge blobs to run up the Storage bill? *(A3)* — 5 MB per-blob cap (storage.rules:60).
- **T-BILL-D-1:** Can attacker upload HTML / JS to host content on the project's bucket? *(A3)* — content-type whitelist blocks `text/html`, `application/javascript` (storage.rules:110-112).
- **T-RATELIMIT-D-1:** Can attacker DoS a victim's rate limit by writing their counter? *(A3)* — Counter doc rule requires `request.auth.token.sender_id == senderId` (firestore.rules:155, 168), so device A cannot write device B's counter.
- **T-CATCHALL-D-1:** Can attacker exploit a typo in collection names to land in "no rule" zone? — Explicit catch-all deny (firestore.rules:448).

### Elevation of privilege

- **T-ALL-E-1:** Can attacker escalate from "user" to "admin" (e.g. write to `verified_orgs/`)? *(A1, A2, A3)* — `allow write: if false` on every collection that should be Admin-only (firestore.rules:379).
- **T-ALL-E-2:** Can attacker escalate by writing to a sibling collection? — Catch-all deny (firestore.rules:448).
- **T-ALL-E-3:** Can attacker escalate by spoofing a custom claim? — The mint path is server-side; the rule only trusts claims minted by the project's auth flow. *Residual:* a project owner with Admin SDK access can mint any claim (see §6).
- **T-RATELIMIT-E-1:** Can attacker "promote" themselves by editing their counter to grant extra writes? — Counter increments by 1 per update and is capped at 60 (firestore.rules:179-180).

---

## 4. Mitigations (rule-by-rule)

Each threat from §3 is mapped to the specific rule that blocks it. Line numbers refer to the version of the rules files at the commit this doc is pinned to.

### Spoofing mitigations

**T-BROADCAST-S-1 → Sender ID spoofing blocked**
```
Mitigation: firestore.rules:234  (request.resource.data.sender_id == request.auth.token.sender_id)
Test: test/rules/firestore_rules.test.js: "broadcast: impersonation (sender_id = B, caller = A) denied"
Residual risk: NONE (assuming request.auth.token.sender_id is unforgeable)
```

**T-DIRECT-S-1 → DIRECT sender ID spoofing blocked**
```
Mitigation: firestore.rules:313  (request.resource.data.sender_id == request.auth.token.sender_id)
Test: test/rules/firestore_rules.test.js: covered by "direct: recipient (sender_id matches) can read" + adjacent cases
Residual risk: NONE (same assumption)
```

**T-ORGLIST-S-1 → Allowlist client-write blocked**
```
Mitigation: firestore.rules:379  (allow write: if false)
Test: test/rules/firestore_rules.test.js: "verified_orgs: client write denied (Admin SDK only)"
Residual risk: NONE (client SDK cannot bypass; Admin SDK can — see §6)
```

**T-EVIDENCE-S-1 → Evidence sender ID spoofing blocked**
```
Mitigation: firestore.rules:409  (request.resource.data.sender_id == request.auth.token.sender_id)
Test: implicit in "evidence: recipient can read own slice" (the seed is sender_id = DEV_B)
Residual risk: NONE (same assumption)
```

### Tampering mitigations

**T-BROADCAST-T-2 → Sender cannot edit own broadcast message**
```
Mitigation: firestore.rules:265-275  (update rule: identity fields immutable, hop_count += 1 only)
Test: covered by "broadcast: create with matching sender_id allowed" + update-not-tested gap
Residual risk: LOW — a malicious relay can increment hop_count but cannot change signature/sender_id/id
```

**T-DIRECT-T-1 → Direct message tamper protection**
```
Mitigation: firestore.rules:341-348  (update rule: identity fields immutable, hop_count += 1 only)
Test: covered by "direct: recipient (sender_id matches) can read"
Residual risk: LOW — same as broadcast
```

**T-EVIDENCE-T-1 → Evidence record immutable**
```
Mitigation: firestore.rules:436  (allow update: if false)
Test: test/rules/firestore_rules.test.js: "evidence: client update denied (immutable)"
Residual risk: NONE
```

**T-EVIDENCE-T-2 → Evidence blob immutable in Storage**
```
Mitigation: storage.rules:116  (allow update: if false)
Test: not explicitly tested; implicit in the rule. (Agent E: consider adding a test.)
Residual risk: NONE
```

**T-ORGLIST-T-1 → Allowlist protected**
```
Mitigation: firestore.rules:379  (allow write: if false)
Test: test/rules/firestore_rules.test.js: "verified_orgs: client delete denied"
Residual risk: NONE
```

**T-RATELIMIT-T-1 → Rate-limit counter tampering**
```
Mitigation: firestore.rules:154-180  (create + update rules: count <= 60, += 1 only on update)
Test: test/rules/firestore_rules.test.js: "rate_limit: own counter create within range allowed"
Residual risk: LOW — a client can race two writes to "double-increment" by one; the rule is best-effort
```

**T-EXPIRES-T-1 → Expires-at immutability**
```
Mitigation: firestore.rules:265-275 (broadcast) and firestore.rules:341-348 (direct)
  → update rule pins identity fields + hop_count +1; expires_at is not in the change path
Test: not explicitly tested
Residual risk: MEDIUM — a relay that updates hop_count can also rewrite expires_at. The TTL policy
  in the Firebase console will still bound storage, but a relay can extend the message's alive
  window. (Agent E: pinning expires_at is a hardening improvement.)
```

### Information disclosure mitigations

**T-DIRECT-I-1 → Direct message recipient-only read**
```
Mitigation: firestore.rules:303  (allow read: if isRecipient(recipientId))
Test: test/rules/firestore_rules.test.js: "direct: non-recipient denied (privacy check)"
Residual risk: NONE
```

**T-EVIDENCE-I-1 → Evidence record recipient-only read**
```
Mitigation: firestore.rules:397  (allow read: if isRecipient(recipientId))
Test: test/rules/firestore_rules.test.js: "evidence: non-recipient denied"
Residual risk: NONE
```

**T-EVIDENCE-BLOB-I-1 → Evidence blob recipient-only read**
```
Mitigation: storage.rules:91  (allow read: if isRecipient(recipientId))
Test: test/rules/firestore_rules.test.js: "storage: evidence blob — non-recipient denied"
Residual risk: NONE
```

**T-ANON-I-1 → Anonymous reads blocked**
```
Mitigation: firestore.rules:215 (broadcast), firestore.rules:303 (direct), firestore.rules:374 (orgs),
            storage.rules:40-44 (isAuthenticatedDevice helper)
Test: test/rules/firestore_rules.test.js: "broadcast: unauthenticated read denied",
      "direct: unauthenticated read denied"
Residual risk: NONE
```

**T-RATELIMIT-I-1 → Counter privacy**
```
Mitigation: firestore.rules:185  (allow read: if false)
Test: test/rules/firestore_rules.test.js: "rate_limit: counter read denied (count is private)"
Residual risk: NONE — by design, even the owner cannot read their own counter (probing protection)
```

### Denial of service mitigations

**T-BROADCAST-D-1 → Broadcast flooding**
```
Mitigation: firestore.rules:229 (16 KB per-doc cap),
            firestore.rules:220 (isWithinRateLimit),
            firestore.rules:159 (counter cap at 60)
Test: test/rules/firestore_rules.test.js: "broadcast: oversized doc (> 16 KB) denied"
Residual risk: MEDIUM — see "best-effort" caveat below
```

**T-STORAGE-D-1 → Storage bill-blow-up**
```
Mitigation: storage.rules:60 + storage.rules:103 (5 MB per-blob cap)
Test: not explicitly tested. (Agent E: consider adding a "storage: oversized blob denied" test.)
Residual risk: LOW — 5 MB × N blobs can still cost money; relies on bucket-level lifecycle policy
```

**T-BILL-D-1 → Hosting attacker content in bucket**
```
Mitigation: storage.rules:110-111  (content-type whitelist)
Test: test/rules/firestore_rules.test.js: "storage: upload as text/html denied"
Residual risk: LOW — the whitelist is small; new content-types must be added explicitly
```

**T-RATELIMIT-D-1 → Cross-device counter attack**
```
Mitigation: firestore.rules:155, 168  (request.auth.token.sender_id == senderId)
Test: test/rules/firestore_rules.test.js: "rate_limit: cross-device create (A writes to B counter) denied"
Residual risk: NONE
```

**T-CATCHALL-D-1 → Typo-path vulnerability**
```
Mitigation: firestore.rules:448-449  (match /{document=**} { allow read, write: if false })
            storage.rules:127-128  (match /{allPaths=**} { allow read, write: if false })
Test: test/rules/firestore_rules.test.js: "catch-all: read outside match list denied"
Residual risk: NONE
```

### Elevation of privilege mitigations

**T-ALL-E-1 → Admin-only writes**
```
Mitigation: firestore.rules:379  (verified_orgs), firestore.rules:185 (rate_limit read),
            firestore.rules:436-437 (evidence update/delete), firestore.rules:281 (broadcast delete),
            firestore.rules:350 (direct delete)
Test: test/rules/firestore_rules.test.js: "verified_orgs: client write denied (Admin SDK only)"
Residual risk: NONE (client-side)
```

**T-ALL-E-2 → Catch-all deny**
```
Mitigation: firestore.rules:448-449
Test: test/rules/firestore_rules.test.js: "catch-all: read outside match list denied"
Residual risk: NONE
```

**T-ALL-E-3 → Custom-claim forging**
```
Mitigation: Rules can only trust claims minted by the project's auth flow. Mints are server-side.
Residual risk: HIGH if Admin SDK is compromised — see §6.
```

**T-RATELIMIT-E-1 → Counter self-promotion**
```
Mitigation: firestore.rules:179-180  (count == resource.data.count + 1 OR count == 1 on window rollover)
Residual risk: LOW — a client can rewrite window_start to a fresh window and set count = 1; this is
  the intended rollover path but does allow a malicious client to "reset" its own limit each
  minute. Best-effort.
```

---

## 5. Residual risks

The following are *known, accepted* residual risks. None of these are bugs; they are explicit trade-offs.

1. **PKI / trust-on-first-use (TOFU).** The mesh accepts a peer's `sender_id` as authentic the first time it sees it. The Firestore rules do not enforce PKI because Firestore cannot run signature verification. The TOFU model is enforced by the client (`lib/crypto/identity.dart` + ratchet). An attacker who can MITM the first handshake can substitute their key. **Mitigation lives in the client.**

2. **Compromised credentials.** If an adversary obtains a device's Firebase Auth custom token (A1), they pass every rule check for the token's lifetime. Backend-controlled token expiry is the only mitigation; the rules cannot tell a stolen token from a legitimate one.

3. **Best-effort rate limit.** Firestore rules cannot do atomic cross-document compare-and-increment. The `rate_limits/{senderId}` counter is a *guard*, not a hard ceiling. A determined attacker can bypass it by writing the counter directly... but the counter doc itself is locked down (`request.auth.token.sender_id == senderId`), so they can only bypass by writing their own counter — which doesn't help them. The remaining bypass is to race two increments; we accept this.

4. **`expires_at` not frozen on update.** A relay that updates `hop_count` can also rewrite `expires_at`. The server-side TTL policy still bounds storage cost, but a malicious relay can extend a message's alive window. Agent E is tightening this.

5. **Cross-org trust.** A device that has accepted org X's public key will trust any message signed by X, regardless of which other orgs are also loaded. The rules do not enforce a "verified orgs must come from a hand-curated allowlist" cross-check at read time — the allowlist is *one* layer; the client's ratchet + the verified-orgs lookup is the other.

6. **Quantum-resistant crypto.** Out of scope. RelayLink uses Ed25519 for transport-encryption keys; this is not post-quantum. If a sufficiently capable quantum adversary is in your threat model, the migration path is hinted at in `SPEC.md` but not implemented.

7. **Mesh-peer impersonation.** If an attacker controls a peer's Bluetooth / Wi-Fi-Direct stack they can present a forged `sender_id` over the radio. The rules layer cannot detect this — it sees the post-arrival Firestore write. The signature in the envelope is what catches this, and that is verified client-side.

8. **Storage client-write surface.** Any authenticated device may upload into any recipient's Storage slice (storage.rules:100). The ciphertext is opaque, so the privacy risk is bounded by the 5 MB cap, but a malicious device can still spam "ghost" blobs to a stranger's slice. This is intentional (the alternative requires a pre-arranged key exchange per upload) and is documented in the storage rules comment.

9. **Single-bucket blast radius.** All evidence blobs land in the default bucket. A bucket-level incident (lifecycle policy misconfiguration, region outage) affects all evidence at once. We accept this for the demo.

10. **Insider at an allowlisted org (A5).** A rogue employee at BRAC can sign valid ALERT messages. The rule layer *cannot* help here — the rule stores the public key verbatim. Mitigation is operational: pubkey rotation, multi-party approval for write to `verified_orgs/`, and out-of-band revocation.

---

## 6. Out-of-scope threats

Explicitly outside the rules' threat model. Documented so the reader does not over-trust the rule layer.

1. **Compromised Firebase admin / project owner.** A person with Admin SDK access can do anything: write to `verified_orgs/`, mint custom claims, delete the project, change the rules. The rules cannot block Admin SDK calls. **Mitigation is operational** (2FA, audit logs, separation of duties, project-owner credential rotation).

2. **Compromised Firebase project credentials.** A leaked service-account key, Firestore API key, or Firebase console password bypasses all rules. **Mitigation is operational.**

3. **Compromised Firebase Auth itself.** If Firebase Auth is compromised at the platform level, custom claims can be forged. **Mitigation is choosing Firebase Auth as a vendor.**

4. **FCM compromise.** Out-of-band Firebase Cloud Messaging notifications are not in the rule path and are not modelled here.

5. **Platform-level attacks.** iOS / Android sandbox escape, malicious system-level apps, hardware implants. **Mitigation is device-level**, not in the rules.

6. **Supply-chain attacks on the Dart / Flutter SDK.** Out of scope.

7. **Network-level attacks on the mesh radio.** Bluetooth / Wi-Fi-Direct / LoRa jamming, replay, etc. The rules do not see the radio; they see the post-arrival Firestore write. **Mitigation is in the mesh protocol layer.**

8. **Social engineering of org operators.** A real person at BRAC adds a malicious pubkey to `verified_orgs/`. The rules do not validate the *content* of the allowlist — they only protect the surface from client-side writes. **Mitigation is operational.**

9. **Quantum-capable adversaries.** Already noted in §5.6.

10. **Compromise of the open-source build pipeline.** If a malicious actor backdoors the published APK / IPA, the on-device checks (including the rules layer) are running on attacker-controlled code. **Mitigation is reproducible builds + signed releases.**

---

## Appendix: rule-line index (quick reference)

| Rule file | Line | Purpose |
|-----------|------|---------|
| `firestore.rules` | 46-51 | `isAuthenticatedDevice()` helper |
| `firestore.rules` | 57-59 | `callerSenderId()` helper |
| `firestore.rules` | 65-68 | `isRecipient()` helper (DIRECT privacy) |
| `firestore.rules` | 81-83 | Size-cap constants |
| `firestore.rules` | 119-128 | `isWithinRateLimit()` (best-effort) |
| `firestore.rules` | 149-186 | Rate-limit counter doc |
| `firestore.rules` | 210-282 | Broadcast relay messages |
| `firestore.rules` | 299-351 | Direct relay messages |
| `firestore.rules` | 370-380 | Verified-org allowlist |
| `firestore.rules` | 395-438 | Evidence Vault records |
| `firestore.rules` | 448-450 | Catch-all deny |
| `storage.rules` | 39-44 | `isAuthenticatedDevice()` (mirrors firestore) |
| `storage.rules` | 50-53 | `isRecipient()` (Storage) |
| `storage.rules` | 60 | 5 MB per-blob cap |
| `storage.rules` | 84-118 | Evidence blob match |
| `storage.rules` | 127-129 | Catch-all deny |

---

*This document is documentation-only. It does not modify `firestore.rules`, `storage.rules`, or any test. Pin to a commit hash for review.*
