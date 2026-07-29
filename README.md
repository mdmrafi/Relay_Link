# July-2026-hackathon

RelayLink — offline-first mesh messaging with end-to-end encryption, optional
SMS/internet relay, and a text-only Evidence Vault. See `SPEC.md` for the
product spec, `STRESS-TEST.md` for the cut list and decision log, and
`.scratch/relaylink-build/issues/` for the ticket breakdown.

## Crypto notes

* **DIRECT messages (ticket #13)** use an HKDF-chain fallback rather than a
  full Double Ratchet. This is per the binding D5 verdict in `VERDICT.md`:
  every published Dart Signal Protocol package requires X3DH and there is no
  externally-bootstrappable ratchet available. The HKDF chain gives forward
  secrecy across the chain (compromise of one message key cannot recover
  earlier ones) but does NOT give post-compromise secrecy. For a production
  deployment a full Double Ratchet would be required.

## Building

```bash
flutter pub get && flutter run -d <device>
```

`<device>` is an Android device id from `flutter devices` (emulator or physical
phone). **Android is the primary target.** iOS scaffold is generated for
parity but the iOS build is not verified on this machine — collaborators with
macOS + Xcode are welcome to verify.

The first build may take a few minutes while Gradle resolves Android
dependencies. After that, incremental debug builds are fast.

> Per `HANDOFF.md` the final demo still requires **two physical Android
> devices** for the mesh-relay walkthrough.

## ALERT verification: demo allowlist

Verified-badged ALERT messages (per `SPEC.md` §12) are signed by organisations
whose Ed25519 public keys ship in this repository at
`assets/verified_orgs.json`, loaded at runtime by
`lib/allowlist/verified_orgs.dart`.

**The `verified_orgs` allowlist in this repo is a manually curated demo
allowlist, not a production trust authority.** Specifically:

- Every entry is flagged `"demo": true` in the JSON and the loader refuses
  to parse a non-demo entry, so this code path cannot silently promote a real
  organisation to verified status.
- The seed script (`tools/seed_orgs.dart`) regenerates fresh Ed25519 keys on
  every run. The private seeds are printed to stdout for demo use only and
  MUST NOT be checked in or used outside the demo.
- A production deployment would need a vetted registry of public keys, regular
  rotation, an out-of-band revocation channel, and a trust anchor not derived
  from this repository. None of that is in scope here.

## Gateway mode toggle

A Settings tile **"Act as gateway for nearby devices"** lets the user opt
their device into relaying other nearby users' encrypted mesh traffic through
their internet connection. The toggle is **off by default** (per
`SPEC.md` §10, Implementation Decisions → Gateway mode).

**Before the toggle can be enabled, the user is shown the following safety
warning verbatim (sourced from `SPEC.md` §10 — Implementation Decisions →
Gateway mode → "Safety note on enable"):**

> Acting as a Gateway relays encrypted mesh traffic through your internet
> connection on behalf of nearby devices. In a monitored or hostile network
> environment, this can make your device identifiable as a bridge point.

Enabling the toggle requires an explicit "Confirm" tap on this dialog. When
the toggle is on, tapping it again shows a "Turn off?" confirmation prompt
before disabling.

The toggle state is persisted across app restarts via `shared_preferences`
and is implemented as a Riverpod singleton (`gatewayEnabledProvider`) so
any screen reflects the current state in real time. The relay code itself
(this ticket ships UI + state only; the relay backend is in Ticket #22)
will read this flag to decide whether to push/pull from Firestore.

See `lib/features/gateway/toggle.dart` for the implementation and
`test/features/gateway/toggle_test.dart` for the test suite (11 widget
tests covering the tap-when-off flow, tap-when-on flow, persistence across
restart, and verbatim spec-text matching).

## Firebase setup

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

### One-time setup to wire up a real Firebase project

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
   `docs/firestore-schema.md`). The TTL policy reads that field and
   deletes expired documents (typically within 24 hours of expiry,
   per Google's docs).
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

### What the placeholder is for

The placeholder config is checked in so that:

- `flutter analyze` and `flutter build apk --debug` succeed for any
  collaborator without Firebase credentials.
- The smoke test runs without network access.
- A reviewer can clone the repo and run it offline to see the mesh
  behaviour without committing to a Firebase project.

## Firestore schema

The Firestore schema for `relay/{channel_id}/messages`,
`relay_direct/{recipient_id}/messages`, `verified_orgs/{org_id}`, and
`evidence/{recipient_id}/records` is documented in
[`docs/firestore-schema.md`](docs/firestore-schema.md). The typed Dart
field-name constants live in `lib/backend/schemas.dart`.