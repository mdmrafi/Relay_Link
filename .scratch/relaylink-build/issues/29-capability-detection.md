# 29 — Capability detection (platform + feature flags)

**What to build:** `lib/capabilities/detect.dart` exposing a `DeviceCapabilities` data class listing every feature from spec §3.1's table with a `bool available` and a `String reason` (e.g., "Apple doesn't allow apps to send or read SMS automatically" for SMS on iOS). Detected once at app start from `Platform.isAndroid` / `Platform.isIOS` plus runtime checks (Bluetooth on, internet reachable, etc.).

**Blocked by:** #01

**Status:** ready-for-agent

- [x] All 9 features from §3.1 table have a detection result
- [x] iOS-specific reasons are accurate and helpful
- [x] Android: SMS features true; iOS: SMS features false with reason
- [x] Feature phones (no app): N/A — handled in README + SMS auto-reply text, not in app UI
- [x] Tests: simulated Android and iOS DeviceCapabilities match expected values