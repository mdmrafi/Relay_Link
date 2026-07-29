# RelayLink Code of Conduct & Data Disclosure

> Submission requirement (§17 of `SPEC.md` and ticket #46):
> "Code-of-Conduct data disclosure — required in README — exactly what data is
> collected (device ID, optional location, phone numbers via SMS, evidence
> capture) and why."
>
> This file is the canonical disclosure. The README links here so the README's
> own contents (per ticket #43) can stay focused on the build/demo story.

## Our pledge

RelayLink is built for people in crisis who need a tool that respects their
safety and their privacy. We pledge to make participation in this project a
harassment-free experience for everyone, regardless of experience level,
gender identity and expression, sexual orientation, disability, neurotype,
physical appearance, body size, age, race, nationality, or chosen platform.

We do not tolerate harassment of any form. Participants asked to stop any
harassing behaviour are expected to comply immediately.

## What data RelayLink collects, stores, and transmits

This section satisfies the spec-mandated data disclosure. It is written for
end users, judges, and reviewers — every category is named, the on-device vs
transmitted boundary is explicit, and the reason each piece of data exists is
given.

### Data categories

| Category | What it is | Where it lives | Why we need it |
|---|---|---|---|
| **Device identity keys** | An Ed25519 signing keypair and an X25519 agreement keypair, generated on first launch on this device | Stored in `flutter_secure_storage` (Android Keystore-backed / iOS Keychain-backed) on the device only | Every message RelayLink sends is Ed25519-signed so the recipient can prove it really came from your device, and every DIRECT (1:1) message is X25519-encrypted so only the recipient can read it. The keys never leave the device. |
| **Device ID (sender_id)** | A short, non-PII identifier derived by hashing your Ed25519 public key | Embedded in every message header (plaintext routing metadata, per spec §5) and stored locally in `sqflite` alongside messages | Lets recipients acknowledge or route messages back to *your device* without ever knowing your name, email, phone number, or account. It is pseudonymous by construction. |
| **Optional location** | A latitude / longitude you may optionally attach to an SOS or STATUS_HELP message | Encrypted into the message `payload` field using the same key as the rest of the message; never written to Firestore unencrypted | Lets a recipient know where to look for you when you cannot describe it. You explicitly opt in per message — the app does not request location in the background. |
| **Phone numbers (SMS features, Android-only)** | The phone numbers of contacts you have explicitly chosen to SMS-relay through | Stored locally in `sqflite`; sent (one direction: device → contact) only when you press send and only to the contacts you selected | SMS fan-out is one of the §4 connectivity tiers. We have to know which numbers to send to. We do not look at your address book without permission and we do not store numbers you did not select. |
| **Evidence Vault captures** | Text you typed into the Vault tab, or chat messages you long-pressed → "Save as evidence" | AES-256-GCM encrypted at rest; stored locally until any enabled transport (mesh, SMS, internet) delivers them to the recipient you picked | The whole point of the Vault is that what you write survives device seizure and reaches an outside recipient. Encryption is mandatory; we will not weaken it for convenience. |
| **Firebase / Firestore relay data (only when a real Firebase project is configured)** | BROADCAST messages, `relay_direct` envelopes addressed to your device-id, and `verified_orgs` allowlist rows | Google-hosted Firestore under the project id you choose during one-time setup (see `README.md` → "Firebase setup"); auto-expire via `expires_at` TTL policy | The internet layer's whole job is to extend reach beyond local mesh. Without a backend, BROADCAST, DIRECT, gateway-relay, and the allowlist refresh all degrade to local-only mode. The repo currently ships a placeholder `lib/firebase_options.dart`, so the default build never touches any real backend. |
| **Telemetry / crash reports** | **None.** | — | RelayLink is offline-first and privacy-by-default. We deliberately do not integrate Firebase Analytics, Sentry, Crashlytics, Mixpanel, or any third-party telemetry SDK. |

### What we do **not** collect

- No name, email, account, username, or password (spec §15 deliberately excludes an account system).
- No contact list scan — the app only uses phone numbers you explicitly add.
- No background location, no ambient sensors, no microphone, no camera, no photo/video/audio evidence (deferred per D6 — see ROADMAP).
- No advertising identifiers, no third-party trackers, no telemetry.
- No analytics events to any server. We have no analytics server.

### Where you can read this in the code

| Concern | Source of truth |
|---|---|
| Identity key generation + secure storage | `lib/crypto/identity.dart` |
| Device ID derivation | `lib/crypto/identity.dart` (sender_id is derived from the Ed25519 public key; the exact hash and length live in that file's tests) |
| SMS send path (what numbers it gets and why) | `lib/sms/platform_channel.dart` |
| Evidence Vault at-rest encryption | `lib/crypto/` and `lib/storage/` — ticket #31 owns the at-rest encryption module, expected at `lib/vault/` once it lands |
| Capability disclosure (what features your device class can / cannot do) | `lib/capabilities/detect.dart`; the in-app Settings surface ships with ticket #42 |
| Local-only mode vs. backend-connected mode | `lib/backend/firebase.dart` |

### Reporting concerns

If you believe a contribution to RelayLink violates this disclosure — for
example, a new dependency that emits telemetry — please open an issue on
GitHub at `github.com/Azm1ne/July-2026-hackathon/issues` or contact the
project owner listed in `README.md`. We will respond within the duration of
the hackathon evaluation window.

---

## Attribution / Acknowledgement

This Code of Conduct is adapted from the Contributor Covenant (v2.1), with
the addition of an explicit data-disclosure section required by hackathon
judging criteria.
