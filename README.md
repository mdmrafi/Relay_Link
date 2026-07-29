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