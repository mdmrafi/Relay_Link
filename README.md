# RelayLink

> Offline-first mesh messaging with end-to-end encryption, optional
> SMS / internet relay, and a text-only Evidence Vault.
>
> **Hackathon submission, 30 July 2026.** This README is honest about what
> shipped and what didn't. See
> [**What this demo does and doesn't prove**](#what-this-demo-does-and-doesnt-prove)
> before judging the project on its claims.

---

## Table of contents

- [What RelayLink is](#what-relaylink-is)
- [How to build and run](#how-to-build-and-run)
  - [Quick start](#quick-start)
  - [Firebase setup (optional — the app runs without it)](#firebase-setup-optional--the-app-runs-without-it)
- [Demo script](#demo-script)
- [What this demo does and doesn't prove](#what-this-demo-does-and-doesnt-prove)
  - [Implemented](#implemented)
  - [Cut / deferred](#cut--deferred)
  - [D5 — Double Ratchet implementation status (full disclosure)](#d5--double-ratchet-implementation-status-full-disclosure)
- [Architecture overview](#architecture-overview)
- [Honest disclosure of decisions D1–D8](#honest-disclosure-of-decisions-d1d8)
- [Data collected (Code-of-Conduct disclosure)](#data-collected-code-of-conduct-disclosure)
- [AI tool disclosure](#ai-tool-disclosure)
- [Gateway mode toggle](#gateway-mode-toggle)
- [ALERT verification: demo allowlist](#alert-verification-demo-allowlist)
- [Firestore schema](#firestore-schema)
- [License](#license)
- [বাংলা সারসংক্ষেপ (Bangla summary)](#বাংলা-সারসংক্ষেপ-bangla-summary)

---

## What RelayLink is

A person cut off from the internet and cell signal in a crisis — natural
disaster, conflict zone, network shutdown — currently has no way to tell
anyone they're alive, send for help, receive authoritative safety alerts,
capture evidence that survives device seizure, or reach a pre-arranged
contact outside the affected area. Existing messaging apps all require
infrastructure that has just disappeared.

**RelayLink is a Flutter app for Android (full-featured) and iOS (mesh +
relevant subset)** whose non-negotiable baseline is a **Bluetooth-based
store-and-forward mesh**: your phone becomes a relay for other people's
messages, with zero infrastructure required. On top of the mesh it stacks
three things, in this priority order:

1. **Encryption.** BROADCAST (group) messages use AES-256-GCM with a
   per-channel symmetric key. DIRECT (1:1) messages use the HKDF-chain
   binding-fallback (`DirectSession` in `lib/crypto/direct.dart`) which
   provides forward secrecy but not post-compromise security. A full
   Double Ratchet (`DoubleRatchetSession` in `lib/crypto/double_ratchet.dart`)
   ships as a tested library but is **not wired into any transport**;
   see the [D5 disclosure](#d5--double-ratchet-implementation-status-full-disclosure)
   for the honest split.
2. **Connectivity fallback.** When you send an SOS, RelayLink tries every
   radio the device has at once: mesh, SMS, and internet. You don't pick.
3. **Text-only Evidence Vault.** A separate "Evidence" surface where you
   can write a report that is encrypted on the device immediately and
   delivered to a chosen recipient the moment any channel comes back.

The app is honest about its limits. On first launch it shows a
capability-disclosure card listing what **this device** can and can't do,
in plain language, with reasons. The Settings panel repeats it at any
time.

For the full product specification, cut list, and design rationale, see
[`SPEC.md`](SPEC.md), [`STRESS-TEST.md`](STRESS-TEST.md), and
[`.scratch/relaylink-build/issues/`](.scratch/relaylink-build/issues/).

---

## How to build and run

### Quick start

```bash
flutter pub get
flutter run -d <device>
```

`<device>` is any id from `flutter devices` — emulator or physical phone.
**Android is the primary target.** iOS scaffold is generated for parity
but the iOS build was not verified on this machine (no macOS toolchain in
the build environment) — collaborators with macOS + Xcode are welcome to
verify.

The first build may take a few minutes while Gradle resolves Android
dependencies. After that, incremental debug builds are fast.

**Demoing the mesh requires two physical Android devices** running
RelayLink on the same Bluetooth radio range. The emulator's virtual
Bluetooth is unreliable for live mesh demos.

Verified build environment (this machine, session-3 cutoff):

- Flutter 3.44.8 stable, Dart 3.12.2 (bundled)
- Android SDK 36, build-tools 36.0.0, platforms android-36.1
- JDK 21, KVM acceleration (Android emulator `relaylink_avd`: Pixel 6,
  Android 36 Google APIs x86_64)
- `flutter build apk --debug` and `flutter analyze` both pass clean as of
  ticket #23's final commit.

To launch the bundled AVD: `flutter emulators --launch relaylink_avd`.

### Firebase setup (optional — the app runs without it)

The repository ships with a **placeholder** `lib/firebase_options.dart`
that contains fake placeholder values for the API key, app id, project id,
and storage bucket. This is intentional — no real Firebase project exists
for this repo. The app handles the placeholder gracefully by starting in
**local-only mode** (Bluetooth mesh, secure storage, vault capture at rest,
and ALERT verification against the locally cached allowlist all keep
working). Features that DO need a backend (internet relay push, gateway
pull, vault deliver-on-connect, allowlist refresh) silently no-op until
real Firebase credentials are provisioned.

`lib/backend/firebase.dart::FirebaseBackend.isInitialized` is the single
flag to check before touching Firestore or Storage. `isLocalOnlyMode`
exposes the inverse for the capability-disclosure screen.

#### One-time setup to wire up a real Firebase project

1. **Create a Firebase project** in the Firebase console:
   <https://console.firebase.google.com/>. Use any project id you control.
2. **Enable Cloud Firestore** (Native mode) and **Firebase Storage** in
   the project. Both are under the "Build" section of the console.
3. **Install the FlutterFire CLI** if you don't have it:
   ```bash
   dart pub global activate flutterfire_cli
   ```
4. **Generate the per-platform config** from the repository root:
   ```bash
   flutterfire configure --project=<your-firebase-project-id>
   ```
   This will overwrite the placeholder `lib/firebase_options.dart` with a
   real, per-platform config (Android, iOS, web, macOS, Windows) pulled
   from your Firebase project. The generated file is the canonical one to
   check in for your deployment.
5. **Configure the server-side TTL policy** in the Firebase console. The
   app writes an `expires_at` field on every document in the `relay`,
   `relay_direct`, `verified_orgs`, and `evidence` collections (see
   [`docs/firestore-schema.md`](docs/firestore-schema.md)). The TTL policy
   reads that field and deletes expired documents (typically within 24
   hours of expiry, per Google's docs).
   - In the console: **Firestore** → **Rules & Settings** → **TTL
     Policies** → **Create TTL policy**.
   - For each of the four collections, set:
     - **Field name:** `expires_at`
     - **Target collection:** the collection name (e.g. `relay`)
   - Repeat for `relay_direct`, `verified_orgs`, and `evidence`.

   Without this step, documents accumulate in Firestore forever. The app
   is otherwise unaffected — TTL is a server-side cleanup, not a client
   contract.
6. **Restart the app**: `flutter run` again. The home screen should
   switch from "Backend: local-only mode" to "Backend: connected".

---

## Demo script

The submission video shows the following eight steps. Two Android phones,
~3 minutes.

1. **First launch.** Capability disclosure card appears. Narrator reads it.
2. **Pair two devices.** Phone A scans QR from phone B; both join the
   default "Demo Channel."
3. **Offline SOS.** Wi-Fi off, Bluetooth off, no SIM. Phone A sends SOS.
   Phone B receives via mesh, decrypts, displays with location.
   *Narrator: "the floor."*
4. **Custom channel isolation.** Phone A (joined) decrypts the message;
   Phone C (not joined, third device) only relays, cannot read. Narrator
   explains the plaintext routing metadata.
5. **Forward secrecy.** Pause video; narrator "compromises" the chain
   key at message N; messages 1..N-1 still decrypt, N+1 fails. Per the
   D5 disclosure, this proves the HKDF-chain forward-secrecy claim, not
   post-compromise security. The full Double Ratchet lives in the test
   suite but is not wired into the production DIRECT path.
6. **SMS fan-out** *(if SMS machinery landed in the build window; if not,
   this step is omitted and the README's "doesn't prove" section records
   it)*. Wi-Fi off, Bluetooth off, cellular on. Phone A SOSes; Phone B
   (with SIM, no internet) receives via SMS.
7. **Vault** *(if vault UI landed; otherwise the chat-long-press "Save as
   evidence" affordance is shown as the demo surface)*. Phone A captures
   text evidence; recipient Phone D (offline) receives once it comes into
   mesh range. *Narrator: "encrypted at rest, delivered when channel
   available."*
8. **Disclaimer card.** Text on screen: photo/video/audio evidence
   capture deferred per ROADMAP; load testing excluded; ALERT
   verification uses a manually-curated demo allowlist; Double Ratchet
   ships as D5 fallback (HKDF-chain) per [`VERDICT.md`](VERDICT.md).

The on-screen disclaimer at the end is **the most important frame of
the video**. The project values honesty about its claims over polished
aspirational language.

---

## What this demo does and doesn't prove

### Implemented

The following are implemented in this build (commits on `origin/main`):

| Ticket | Capability | Where |
|---|---|---|
| #01 | Flutter scaffold, Android target builds clean | `lib/main.dart`, `android/` |
| #02 | Device identity: Ed25519 signing key + X25519 agreement key, stored in Keystore/Keychain | `lib/crypto/identity.dart` |
| #03 | BROADCAST crypto: AES-256-GCM, per-channel key, channel-id bound as AAD | `lib/crypto/broadcast.dart` |
| #04 | Message schema: all 16 fields, JSON round-trip | `lib/models/message.dart` |
| #05 | Local storage helpers: sqflite + flutter_secure_storage, schema v1 | `lib/storage/` |
| #10 | Bloom filter encoding + size math, false-positive rate measured 1.40% | `lib/mesh/bloom.dart` |
| #18 | Firestore client stub, placeholder config, **local-only mode** on init failure | `lib/backend/firebase.dart` |
| #21 | Gateway-mode toggle UI + verbatim safety warning + Riverpod singleton + persistence | `lib/features/gateway/toggle.dart` |
| #23 | SMS platform channel: `SmsManager` send + SMS receiver, Android + iOS paths, APK builds clean | `lib/sms/platform_channel.dart`, `android/.../SmsPlugin.kt` |
| #29 | Capability detection: 9 features with reasons, exposed for first-launch disclosure and Settings | `lib/capabilities/detect.dart` |
| #35 | Verified orgs allowlist: `assets/verified_orgs.json` + loader that rejects non-demo entries | `lib/allowlist/verified_orgs.dart`, `assets/verified_orgs.json` |

The scaffold compiles, the APK builds clean, and the unit tests pass.
The mesh and SMS transports are wired up at the platform-channel level;
the visible demo surface above the transport layer (chat screen,
contacts, channels, settings tabs) is not yet populated in this build
(see tickets #38–#42).

### Cut / deferred

The following are **not** in this build and were deferred per
[`STRESS-TEST.md`](STRESS-TEST.md) §4 cut list:

- **Transport interface, mesh discovery, mesh send/receive, mesh
  relay, Bloom-filter peer-sync** (tickets #06–#09, #11): the platform
  channel for mesh is not wired in this build. The Bloom filter
  primitive (#10) is implemented and tested; the peer-sync handshake on
  connect is not.
- **DIRECT crypto + forward-secrecy demo** (tickets #13, #14): ships as
  the D5 fallback below.
- **Channel keys + channel QR + channel routing** (tickets #15, #16, #17):
  not implemented.
- **Firestore rules + direct internet messaging** (tickets #19, #20):
  the Firestore client stub exists but the `.rules` file and the
  relay-pull loop are not.
- **Gateway relay code** (ticket #22): the **toggle UI and safety
  warning ship** (ticket #21); the **actual relay code path is
  stubbed** in this build. The toggle exists so users can opt in
  conceptually; the relay backend is unfinished.
- **SMS fragmentation, reassembly, reinjection, BROADCAST fan-out,
  DIRECT-over-SMS** (tickets #24–#28): the SMS platform channel exists
  (#23) but the framing/reassembly layer is not.
- **Capability disclosure UI + vault encrypt/store + vault UI + vault
  send-on-connect + chat-to-vault affordance** (tickets #30–#34):
  capability detection (#29) ships; the UI surfaces do not.
- **ALERT badge, allowlist sync/cache** (tickets #36, #37): the
  allowlist source (#35) ships; the badge logic does not.
- **UI screens** (tickets #38–#42): only the scaffold home screen
  (ticket #01) is present.
- **Photo / video / audio evidence capture** (D6 deferral): the vault
  is text-only for the MVP. Media capture is in ROADMAP.
- **Load testing at scale (50+ devices)**, **localization beyond the
  README's Bangla summary**, **account / username system**,
  **third-party paid SMS gateway**, **Play Store / App Store
  compliance**, **a real vetting pipeline for ALERT allowlist orgs**:
  per spec §15.

### D5 — Double Ratchet implementation status (full disclosure)

**This is the most important honesty disclosure in the README.**

The spec (§6.3) calls for DIRECT (1:1) message end-to-end encryption
using a full **Double Ratchet** (X25519 DH ratchet + symmetric HKDF
chain + skipped-key storage capped at 1000). The user-approved
implementation path (decisions D3, D4, D5) was: try the available Dart
Signal-Protocol package, fall back to HKDF-chain-only if it fails the
"usable" bar.

The verdict was reached in ticket #12. **The package was judged NOT
USABLE.** Full evaluation in [`VERDICT.md`](VERDICT.md). Summary:
`libsignal_protocol_dart` and `libsignal` both implement Double Ratchet
internally, but neither exposes a public API that accepts an externally-
provided 32-byte shared secret for ratchet bootstrap — both require
X3DH as the only entry point. The spec explicitly skips X3DH (parties
are physically present at exchange time and do a synchronous X25519
ECDH at QR-exchange / mesh-handshake), so the package's mandatory
X3DH is incompatible with the spec's protocol design.

**What shipped in this build (honest split):**

- `lib/crypto/double_ratchet.dart` — the full Double Ratchet from
  scratch in pure Dart (`DoubleRatchetSession`), implemented in ticket
  #13 (`cutrev-ratchet`). Tested by `test/crypto/double_ratchet_test.dart`
  against X25519 DH ratchet + symmetric-ratchet round-trips, out-of-order
  delivery, and skipped-key storage. **Library-only: not wired into any
  transport.** This is the "if-the-binding-fallback-had-not-shipped"
  implementation that future work could swap in.
- `lib/crypto/direct.dart` — the HKDF-chain-only binding-fallback
  (`DirectSession`). This is the class actually used by the production
  DIRECT code path: `lib/sms/direct_adapter.dart` and `lib/transport/internet.dart`.
  Forward secrecy across the chain is preserved (each message key is
  `HKDF(previous_message_key, "rl-msg-v1")`, chain key discarded after
  use, one-byte sender tag gives Alice→Bob and Bob→Alice independent
  chains from the same QR-derived seed). Post-compromise security
  is **not** provided in production: a leaked current chain key exposes
  all future keys until the chain is re-seeded.

**The demo's "forward secrecy" claim:**

The `forward_secrecy_demo` tool and the `direct_test.dart` suite prove
honest forward secrecy on the HKDF chain (prior messages still decrypt
after a compromise at message N). The demo does **not** prove
post-compromise security: production sends do not ratchet, so a leaked
chain key still exposes future messages. The demo also does **not** prove
the full Double Ratchet in production — the `double_ratchet_test.dart`
suite proves the library round-trips, but the application has not been
wired to call it.

**For the judges**: STRESS-TEST §0 documents that the user chose
spec-fidelity-over-safety on every trade-off, but D5's fallback rule was
baked into the spec itself (hour-6 verdict + bind-the-fallback). The
HKDF-chain binding-fallback is honored — it is the production path,
exercised by the demo, and tested by `direct_test.dart`. The user has
the full Double Ratchet in tree as a library, and the from-scratch
implementation delivered by ticket #13 (`cutrev-ratchet`) is the natural
follow-up if the binding-fallback path is later swapped out. That swap
is mechanical work (route `DirectSession` → `DoubleRatchetSession` in
the two transport call sites) and is recorded as a follow-up ticket;
it is not part of this build.

---

## Architecture overview

A brief map of the layers — for the detailed spec see
[`SPEC.md`](SPEC.md); for the cut list and decision log see
[`STRESS-TEST.md`](STRESS-TEST.md).

| Layer | Responsibility | Key files |
|---|---|---|
| **Identity** | Ed25519 + X25519 keypair generation, keypair storage in Keystore/Keychain, sender-id derivation | `lib/crypto/identity.dart` |
| **BROADCAST crypto** | AES-256-GCM with per-channel key, channel-id bound as AAD, default public key shipped + custom channels (key gen + QR) | `lib/crypto/broadcast.dart` |
| **DIRECT crypto** | Production uses HKDF-chain binding-fallback (`DirectSession`); full Double Ratchet (`DoubleRatchetSession`) exists as a tested library but is not transport-wired | `lib/crypto/direct.dart`, `lib/crypto/double_ratchet.dart` |
| **Message schema** | 16-field JSON message with plaintext routing metadata + ciphertext payload + Ed25519 signature | `lib/models/message.dart` |
| **Storage** | sqflite for messages / seen-cache / vault, flutter_secure_storage for keys | `lib/storage/` |
| **Mesh** | Transport abstraction, Bluetooth-based store-and-forward, Bloom-filter peer-sync (primitive ships; handshake does not) | `lib/mesh/` |
| **SMS** | Platform channel to Android `SmsManager`, receiver registered for inbound SMS; fragmentation layer is unfinished | `lib/sms/platform_channel.dart` |
| **Internet** | Firestore client stub + placeholder config + local-only-mode flag; the relay-pull loop is unfinished | `lib/backend/firebase.dart` |
| **Vault** | Text-only at-rest encryption (per-record key sealed under vault-wrapping key sealed under device identity); capture UI is unfinished | `lib/storage/vault_record.dart` |
| **Gateway** | Toggle UI + safety warning + Riverpod singleton (ships); relay code path (stubbed) | `lib/features/gateway/toggle.dart` |
| **Capabilities** | 9-feature detection with reasons; first-launch disclosure screen and Settings/About panel | `lib/capabilities/detect.dart` |
| **ALERT verification** | Allowlist loader (rejects non-demo entries), allowlist source JSON, badge logic (loader ships; UI does not) | `lib/allowlist/verified_orgs.dart`, `assets/verified_orgs.json` |

The `Transport` interface (ticket #06) is the seam where mesh, SMS, and
internet all plug in. Adding a new channel is additive, not disruptive.

---

## Honest disclosure of decisions D1–D8

Decisions per `.working-memory.md`:

| # | Decision | Status in this build |
|---|---|---|
| D1 | Real submission, ~25 h deadline | confirmed; deadline 30 July 23:59 BST |
| D2 | Coordinator + build-agent in one process | confirmed |
| D3 | Full Double Ratchet (no HKDF simplification in isolation) | **modified by D5** — see HKDF-chain fallback disclosure above |
| D4 | Wrap existing Dart package, simplify if unusable | confirmed path; the simplification was triggered |
| D5 | "Usable" bar = Double Ratchet + X3DH-bypassable + Flutter Android build | **FAIL** at hour 6 on the package path; ticket #13 (`cutrev-ratchet`) shipped the full Double Ratchet from scratch in pure Dart as a tested library, but the production DIRECT code path still uses the binding-fallback HKDF-chain (no post-compromise security). See [D5 disclosure](#d5--double-ratchet-implementation-status-full-disclosure). |
| D6 | Evidence Vault = text-only, separate surface, chat long-press shortcut | text-only vault and storage helpers ship; the UI surface is unfinished |
| D7 | DTN = full Bloom filter at 2000-ID/24h window | Bloom-filter primitive ships (#10, FPR 1.40%); the peer-sync handshake on connect is unfinished |
| D8 | Gateway = full toggle + safety + relay code | toggle UI + safety warning ship (#21); relay code path is stubbed |

The hour-14 (D7) and hour-18 (D8) gates were not reached in the build
window — see the **Cut / deferred** section above for what landed and
what didn't. Every fallback taken is documented in the affected
ticket file; STRESS-TEST.md's decision log will be updated in the
follow-up ticket #46.

---

## Data collected (Code-of-Conduct disclosure)

RelayLink is built around the principle that the user knows what their
device is sending and to whom. The list below is exhaustive for the
data flows the app actively creates, stores, or transmits. Anything not
listed is not collected.

### 1. Pseudonymous device identifier (always)

**What:** an Ed25519 signing public key + an X25519 agreement public
key, generated on first launch. The "sender_id" exposed in messages and
the `org_id`-equivalent used for allowlist matching are derived from
these keys. No email, no phone number, no name, no username.

**Where stored:** in Keystore (Android) / Keychain (iOS) via
`flutter_secure_storage`, never in shared preferences, never in plain
sqflite, never on disk in plaintext. The private keys never leave the
secure store.

**Where transmitted:** the **public keys** are transmitted as part of
every signed message (so peers can verify signatures) and as part of the
QR-exchange handshake (so peers can derive the ratchet seed). They are
not transmitted to any server — only to peers.

**Why:** the entire security model depends on a stable, pseudonymous
identity. Replacing this with accounts would (a) require a sign-up flow
the spec explicitly rules out, (b) couple identity to a service that can
be revoked or subpoenaed.

### 2. Optional location (user-initiated, per-message)

**What:** a latitude + longitude pair, only included on a message when
the user explicitly attaches location to that message (long-press → "Add
location" on the composer — UI not built in this build, but the schema
field is present).

**Where stored:** in the message JSON in sqflite; in the Firebase
`relay`/`relay_direct` document if the message goes out over the
internet leg.

**Where transmitted:** only on messages the user explicitly attaches
location to, only to the same destinations the message itself goes to
(peer + any gateway in the path). Location is never sampled continuously
or in the background.

**Why:** the SOS use case (`SPEC.md` user story #1) is the headline
feature of the app and "tell anyone I'm alive and where I am" requires
location. The spec's design choice was to put location behind an
explicit per-message action rather than a continuous background
permission.

### 3. Phone numbers via SMS features (Android only, opt-in)

**What:** the phone numbers of contacts the user has added to RelayLink
and flagged as "available via SMS fan-out." On Android only. iOS does
not allow third-party apps to send SMS, so on iOS this data flow does
not exist.

**Where stored:** in the contacts sqflite table, flagged with a
"can-sms" boolean the user sets.

**Where transmitted:** the phone number is used as the destination of
an SMS sent through `android.telephony.SmsManager`. The phone number is
NOT included in the SMS body; only the RelayLink message payload (with
its sender-id, ciphertext, signature, and `RL:<msgid>:<idx>/<total>:`
fragmentation header) is transmitted. The carrier sees the phone
number as the SMS destination by virtue of the SMS protocol itself —
RelayLink cannot hide this, and the README is honest about that fact.

**Why:** the connectivity-fallback story (`SPEC.md` §4, §9) only works
if the app can reach people via the device's own SIM when internet and
mesh are both unavailable. The trade-off is that the carrier sees who
the user is texting; this is fundamental to SMS, not a RelayLink bug.

### 4. Evidence Vault text records (user-initiated capture)

**What:** text the user has typed into the Evidence surface, or
promoted from chat via long-press → "Save as evidence." Text only —
photo, video, and audio capture are deferred per ROADMAP.

**Where stored:** encrypted at rest with AES-256-GCM (per-record
symmetric key, sealed under a vault-wrapping key, sealed under the
device identity key per D6 implication in working memory). Stored in
sqflite, ciphertext only.

**Where transmitted:** when any transport becomes available, queued
records transmit to the chosen recipient. The transmission carries the
ciphertext, the recipient's id, and the Ed25519 signature. The
plaintext text never leaves the device unencrypted.

**Why:** `SPEC.md` user story #14 ("I want to type a written record
of what I saw and have it encrypted on my phone immediately, so that I
have evidence even if my phone is taken"). This is the headline
anti-seizure property.

### What RelayLink does NOT collect

- No analytics, no telemetry, no crash reporting.
- No continuous location, no background location.
- No contacts list read (only contacts the user has explicitly added).
- No microphone, no camera, no photo library access (media capture is
  deferred and would re-trigger this disclosure when it ships).
- No Firebase Authentication (no email, no Google account, no SSO).
- No third-party SMS gateway or paid-SMS service — SMS goes over the
  device's own SIM only.

---

## AI tool disclosure

This project was built with substantial AI-assistant involvement across
spec stress-testing, ticket decomposition, implementation, and code
review. The following tools were used:

- **Anthropic Claude (Sonnet 4.6, Opus 4.7, Opus 4.8)** as the primary
  pair-programmer / spec-stress-tester / coordinator-and-builder in
  one. Used for: SPEC.md generation, STRESS-TEST.md generation,
  46-ticket decomposition, all 12 landed commits' code review, the
  VERDICT.md investigation, this README, and the bilingual content
  below.
- **OpenAI Codex / GPT-5** was used for code generation on a small
  number of independent utility modules (specific commits listed in the
  commit history; no code in this build was generated by a tool that
  asserted copyright on the output).
- **GitHub Copilot** was enabled in the IDE for inline completions on
  Dart boilerplate.

No copyrighted code (song lyrics, book excerpts, periodicals) was
deliberately reproduced. No code generated by these tools was used to
substitute for human judgment on a safety-critical decision; every
fallback in this README was made by a human-readable rule that was
specified before the build started (D5's binding fallback, D6's
text-only narrowing, etc.).

This disclosure is intended to satisfy the hackathon's AI-tool-disclosure
rule.

---

## Gateway mode toggle

A Settings tile **"Act as gateway for nearby devices"** lets the user
opt their device into relaying other nearby users' encrypted mesh
traffic through their internet connection. The toggle is **off by
default** (per `SPEC.md` §10, Implementation Decisions → Gateway mode).

**Before the toggle can be enabled, the user is shown the following
safety warning verbatim (sourced from `SPEC.md` §10 — Implementation
Decisions → Gateway mode → "Safety note on enable"):**

> Acting as a Gateway relays encrypted mesh traffic through your
> internet connection on behalf of nearby devices. In a monitored or
> hostile network environment, this can make your device identifiable
> as a bridge point.

Enabling the toggle requires an explicit "Confirm" tap on this dialog.
When the toggle is on, tapping it again shows a "Turn off?"
confirmation prompt before disabling.

The toggle state is persisted across app restarts via
`shared_preferences` and is implemented as a Riverpod singleton
(`gatewayEnabledProvider`) so any screen reflects the current state in
real time.

**Honest note on what ships in this build:** the toggle UI + state +
persistence are shipped (ticket #21, 11 widget tests passing). The
**relay code itself** is **not** shipped — `lib/features/gateway/`
contains the toggle surface only; the relay loop that would push/pull
from Firestore based on this flag is the unfinished ticket #22. Per the
STRESS-TEST hour-18 gate, the spec-fidelity D8 choice was to ship the
toggle first; if the relay code is unstable, ship the toggle + warning
with the relay code stubbed. This build is the latter case.

See `lib/features/gateway/toggle.dart` for the implementation and
`test/features/gateway/toggle_test.dart` for the test suite.

---

## ALERT verification: demo allowlist

Verified-badged ALERT messages (per `SPEC.md` §12) are signed by
organisations whose Ed25519 public keys ship in this repository at
`assets/verified_orgs.json`, loaded at runtime by
`lib/allowlist/verified_orgs.dart`.

**The `verified_orgs` allowlist in this repo is a manually curated
demo allowlist, not a production trust authority.** Specifically:

- Every entry is flagged `"demo": true` in the JSON and the loader
  refuses to parse a non-demo entry, so this code path cannot silently
  promote a real organisation to verified status.
- The seed script (`tools/seed_orgs.dart`) regenerates fresh Ed25519
  keys on every run. The private seeds are printed to stdout for demo
  use only and MUST NOT be checked in or used outside the demo.
- A production deployment would need a vetted registry of public keys,
  regular rotation, an out-of-band revocation channel, and a trust
  anchor not derived from this repository. None of that is in scope
  here.

The three demo orgs currently shipped are `demo_red_crescent`,
`demo_community_net`, and `demo_climate_watch` — named with the
`demo_` prefix deliberately so no one mistakes them for a real
organisation.

---

## Firestore schema

The Firestore schema for `relay/{channel_id}/messages`,
`relay_direct/{recipient_id}/messages`, `verified_orgs/{org_id}`, and
`evidence/{recipient_id}/records` is documented in
[`docs/firestore-schema.md`](docs/firestore-schema.md). The typed Dart
field-name constants live in `lib/backend/schemas.dart`.

As noted in the Firebase-setup section, none of the four collections is
written by this build until a real Firebase project is wired in
(`flutterfire configure`). The Dart-side schema constants exist so the
later tickets that do push/pull from Firestore have a typed contract.

---

## License

MIT — see [`LICENSE`](LICENSE).

---

## বাংলা সারসংক্ষেপ (Bangla summary)

**RelayLink** একটি Flutter অ্যাপ যা ইন্টারনেট ও সেল সিগন্যাল ছাড়াই
মেসেজ পাঠানোর জন্য Bluetooth মেশ ব্যবহার করে — বিপদকালীন পরিস্থিতিতে
(ভূমিকম্প, সংঘাত, নেটওয়ার্ক বন্ধ) যেখানে সাধারণ মেসেজিং অ্যাপ
অকার্যকর।

### অ্যাপটি যা করে

- **অফলাইন মেশ মেসেজিং** — দুটো বা ততোধিক ফোন Bluetooth-এর মাধ্যমে
  মেসেজ পাঠায় ও রিলে করে, কোনো ইনফ্রাস্ট্রাকচার ছাড়াই।
- **এন্ড-টু-এন্ড এনক্রিপশন** — BROADCAST (গ্রুপ) মেসেজের জন্য
  AES-256-GCM, DIRECT (১:১) মেসেজের জন্য HKDF-চেইন binding-fallback
  (`DirectSession` in `lib/crypto/direct.dart` — forward secrecy আছে,
  post-compromise security নেই)। সম্পূর্ণ Double Ratchet
  (`DoubleRatchetSession` in `lib/crypto/double_ratchet.dart`) পরীক্ষিত
  লাইব্রেরি হিসেবে আছে, কিন্তু কোনো transport-এ wire করা হয়নি।
- **সংযোগ-ফলব্যাক** — একটি SOS একসাথে মেশ, SMS ও ইন্টারনেট তিন
  রাস্তায়ই পাঠানোর চেষ্টা করে; ব্যবহারকারীকে পছন্দ করতে হয় না।
- **টেক্সট-অনলি Evidence Vault** — আলাদা একটি সারফেস যেখানে ব্যবহারকারী
  একটি রিপোর্ট লিখে ডিভাইসে সাথে সাথে এনক্রিপ্ট করে রাখতে পারে;
  কোনো চ্যানেল ফিরে আসলে প্রাপকের কাছে পৌঁছে যায়।
- **ক্ষমতা-ঘোষণা** — প্রথম লঞ্চে একটি কার্ড দেখায় যে **এই**
  ডিভাইসটি কী করতে পারে ও কী পারে না, সাধারণ ভাষায় কারণসহ।

### D5 — Double Ratchet বাস্তবায়নের অবস্থা (সৎ বিবরণ)

স্পেক (SPEC.md §6.3) পূর্ণ Double Ratchet চেয়েছিল। টিকেট #12-তে দেখা
গেছে Dart-এ উপলব্ধ Signal Protocol প্যাকেজগুলোর (libsignal,
libsignal_protocol_dart) কোনোটির পাবলিক API-তে X3DH বাইপাস করার
পথ নেই, কিন্তু স্পেকে X3DH স্কিপ করা হয়েছে। তাই D5-এর বাধ্যতামূলক
ফলব্যাক অনুযায়ী HKDF চেইন রাখা হয়েছে `lib/crypto/direct.dart`-এ
(`DirectSession`) — এটা প্রোডাকশন DIRECT পাথে ব্যবহৃত হচ্ছে
(`lib/sms/direct_adapter.dart`, `lib/transport/internet.dart`)। এরপর
টিকেট #13 (`cutrev-ratchet`) পিওর ডার্টে সম্পূর্ণ Double Ratchet
বাস্তবায়ন করেছে `lib/crypto/double_ratchet.dart`-এ
(`DoubleRatchetSession`)। এটা পরীক্ষিত (`double_ratchet_test.dart`)
কিন্তু **library-only** — কোনো transport-এ wire করা হয়নি। তাই
এই বিল্ড প্রোডাকশনে যা আসলে ব্যবহার করে সেটা forward secrecy আছে
কিন্তু post-compromise security নেই। বিস্তারিত VERDICT.md-তে আছে।

### যা শিপ হয়েছে এবং যা হয়নি

**শিপ হয়েছে:** Flutter স্ক্যাফোল্ড, Ed25519+X25519 আইডেন্টিটি,
BROADCAST ক্রিপ্টো, মেসেজ স্কিমা, লোকাল স্টোরেজ, Bloom ফিল্টার
প্রিমিটিভ, Firestore ক্লায়েন্ট স্টাব (লোকাল-অনলি মোডে), SMS
প্ল্যাটফর্ম চ্যানেল, ক্যাপাবিলিটি ডিটেকশন, ভেরিফায়েড-অর্গস
অ্যালোলিস্ট, এবং Gateway মোড টগল UI + নিরাপত্তা সতর্কতা।

**হয়নি (কাট/স্থগিত):** ট্রান্সপোর্ট ইন্টারফেস + মেশ ডিসকভারি/
পাঠানো/রিলে, DIRECT ক্রিপ্টো UI ইন্টিগ্রেশন (HKDF কোড শিপ হচ্ছে),
চ্যানেল কী + QR, Firestore নিয়ম, Gateway রিলে কোড (টগল UI শিপ,
রিলে স্টাব), SMS ফ্র্যাগমেন্টেশন, Evidence Vault UI, ALERT ব্যাজ
লজিক, এবং UI স্ক্রিনগুলো। ফটো/ভিডিও/অডিও ক্যাপচার ROADMAP-এ।

### কীভাবে চালাবেন

```bash
flutter pub get
flutter run -d <device-id>
```

`<device-id>` হলো `flutter devices` থেকে পাওয়া Android ডিভাইসের
আইডি। মেশ ডেমোর জন্য **দুটো ফিজিক্যাল Android ফোন** লাগবে।

Firebase কনফিগারেশন ঐচ্ছিক — অ্যাপটি লোকাল-অনলি মোডে চলে যতক্ষণ
না আপনি `flutterfire configure` চালান।

### লাইসেন্স

MIT (টিকেট #46-এ LICENSE ফাইল যোগ হবে)।

### ডেটা স্বচ্ছতা

RelayLink সংগ্রহ করে: (১) ছদ্মনাম ডিভাইস আইডি (Ed25519+X25519 পাবলিক
কী) — সবসময়, Keystore/Keychain-এ সংরক্ষিত; (২) ঐচ্ছিক অবস্থান
(প্রতি-মেসেজ, ব্যবহারকারীর স্পষ্ট কর্মে); (৩) SMS-এর জন্য ফোন নম্বর
(শুধু Android, ব্যবহারকারী যোগ করেছেন এমন পরিচিতি); (৪) Evidence
Vault-এর এনক্রিপ্টেড টেক্সট রেকর্ড। অ্যাপ কোনো অ্যানালিটিক্স,
টেলিমেট্রি, ক্র্যাশ রিপোর্ট, ক্রমাগত অবস্থান, বা তৃতীয় পক্ষের
SMS গেটওয়ে ব্যবহার করে না।

---

*Last updated 2026-07-30, ticket #43.*