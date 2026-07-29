# 01 — Flutter scaffold + Android target builds

**What to build:** A Flutter project at the repo root that builds successfully for Android. Includes the standard `flutter create` layout, `pubspec.yaml` with all dependencies pre-declared (cryptography, riverpod, sqflite, flutter_secure_storage, mobile_scanner for QR, firebase_core + cloud_firestore + firebase_storage, permission_handler, etc.), and a "Hello, RelayLink" home screen that runs on a fresh `flutter run -d <android-device>`.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `flutter create` produces a project at repo root (existing placeholder README preserved)
- [ ] `pubspec.yaml` lists every dependency needed for all later tickets, even if unused yet
- [ ] `flutter build apk --debug` succeeds on the agent's machine
- [ ] App installs and launches on a physical Android device
- [ ] A single home screen displays "RelayLink" as text
- [ ] README references how to build (one-liner: `flutter pub get && flutter run -d <device>`)