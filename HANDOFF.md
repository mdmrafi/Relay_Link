# HANDOFF.md — Session 1 → Session 2

**Date:** 2026-07-30
**Branch:** `main`
**Deadline:** 30 July 2026 23:59 BST

---

## What's verified and ready

### Environment (verified this session)
- Flutter 3.44.8 stable at `~/flutter/bin`
- Dart 3.12.2 (bundled)
- Android SDK 36.0.0 at `~/Android/Sdk`, build-tools 36.0.0, platforms android-36.1, emulator 36.6.11.0
- `cmdline-tools/latest/` installed and on PATH
- All Android SDK licenses accepted (7 license files in `~/Android/Sdk/licenses/`)
- `/dev/kvm` available — KVM acceleration works for emulator
- Docker 29.6.2 daemon is running (unused — emulator is the chosen path)
- Git identity configured: `Azmine <mdbinmonjurazmine@gmail.com>`
- JDK 21.0.11 at `/usr/bin/java`

### Persistence in `~/.bashrc`
A marker-delimited block (id `relaylink-android-env`) at the bottom of `~/.bashrc` exports:
- `PATH="$HOME/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$HOME/Android/Sdk/platform-tools:$PATH"`
- `ANDROID_HOME="$HOME/Android/Sdk"`
- `ANDROID_SDK_ROOT="$HOME/Android/Sdk"`

**For new sessions:** open a fresh terminal or `source ~/.bashrc` — `flutter`, `adb`, `sdkmanager`, `avdmanager` will all be on PATH.

### Scope decisions made this session
- **iOS: parked, not abandoned.** Scaffold should include both `android/` and `ios/` platforms. Dart code stays platform-agnostic. README will carry "iOS build not verified on this machine — collaborators with macOS/Xcode welcome." Per STRESS-TEST §4 this aligns with the existing cut list.
- **Device verification: emulator (KVM-accelerated AVD), not Docker.** Emulator binary and KVM are both verified. Docker is overkill for the scaffold ticket.
- **Final demo (per STRESS-TEST §6) still requires two physical Android devices.** Document this in README.

---

## What's NOT done (next session's work)

### Ticket #01 — Flutter scaffold + Android target builds
**Status:** NOT STARTED. Awaiting user approval.

**What to do:**
1. Create AVD: `avdmanager create avd -n relaylink_avd -k "system-images;android-36;google_apis;x86_64" -d "pixel_6"`
2. `flutter create .` at repo root (preserves existing markdown docs, overwrites `lib/main.dart`, `pubspec.yaml`, generates `android/` + `ios/`)
3. Replace `pubspec.yaml` with the **complete dependency list** below (pre-declare everything for all 45 later tickets)
4. Replace `lib/main.dart` with a minimal MaterialApp showing centered "RelayLink" text
5. `flutter pub get` → `flutter build apk --debug`
6. `flutter emulators --launch relaylink_avd` → `flutter run -d <avd-id>` and confirm the text appears
7. Mark `#01-flutter-scaffold.md` acceptance items, commit, push

### Pre-extracted dependency list (from parallel scan this session)
**Runtime `dependencies:`**
- `cryptography` — X25519, Ed25519, AES-256-GCM, HKDF (#02, #03, #13, #31, #44)
- `flutter_riverpod` — state management (#38-#42)
- `sqflite` — messages, seen-cache, vault, contacts (#05, #09, #31, #40)
- `flutter_secure_storage` — identity keys, channel keys, secrets (#02, #05, #15)
- `uuid` — message IDs (#04)
- `qr_flutter` — channel QR encode (#16)
- `mobile_scanner` — channel QR decode (#16)
- `shared_preferences` — gateway toggle, first-launch flag, allowlist cache (#21, #30, #36)
- `firebase_core` — Firebase init (#18)
- `cloud_firestore` — relay collections, allowlist (#18, #20, #22, #35, #36)
- `firebase_storage` — evidence uploads (#18)

**Dev `dev_dependencies:`**
- Standard `flutter_lints` only (no test packages explicitly named in tickets — add `flutter_test` if not auto-added by `flutter create`)

**NOT pre-declared (intentional):**
- `libsignal_protocol_dart` — gated on **#12 D5 verdict at hour 6** (STRESS-TEST §1). If verdict says usable, add then. If unusable, #13 ships HKDF-chain-only with no ratchet package.
- `flutter_nearby_connections` — #07 names it "or equivalent." Add when #07 lands and a specific package is chosen.
- `xxhash` (Bloom filter hash, #10) — exact package not pinned. Add when #10 lands.
- Geolocation, webview, system contacts — no ticket names a plugin. Don't add speculatively.
- `firebase_auth` — spec explicitly excludes auth. Don't add.

---

## Files added this session (untracked, ready to commit)

- `.scratch/relaylink-build/scripts/setup-android-env.sh` — idempotent Android env setup (PATH persistence + license acceptance + doctor re-verify). Already ran this session, no changes needed. Just commit it.

## Files to read first thing in next session

1. `CONTEXT.md` — how the project works (tickets, blockers, decision gates, honesty requirements)
2. `SPEC.md` — what we're building
3. `STRESS-TEST.md` — what's cut, what decision gates exist (hour-6, hour-14, hour-18)
4. `.working-memory.md` — decisions D1-D8 with reasoning
5. `.scratch/relaylink-build/issues/01-flutter-scaffold.md` — the immediate next ticket
6. This file (`HANDOFF.md`)

## Decision gates to remember

- **Hour 6:** #12 D5 verdict on Double Ratchet package — if not usable, fall back to HKDF-chain.
- **Hour 14:** #11 D7 verdict on Bloom filter — if slipping, fall back to bounded last-200-IDs.
- **Hour 18:** #22 D8 verdict on Gateway relay — if unstable, ship toggle UI + safety warning with stubbed code.

Document every fallback in the affected ticket file and update STRESS-TEST.md's decision log. **Don't silently fall back.**