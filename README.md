# July-2026-hackathon

RelayLink — offline-first mesh messaging with end-to-end encryption, optional
SMS/internet relay, and a text-only Evidence Vault. See `SPEC.md` for the
product spec, `STRESS-TEST.md` for the cut list and decision log, and
`.scratch/relaylink-build/issues/` for the ticket breakdown.

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