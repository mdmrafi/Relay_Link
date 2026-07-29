# 30 — Capability disclosure on first launch + Settings/About

**What to build:** A first-launch screen showing this device's capabilities (from #29) in plain language, with reasons for unavailable features. Same content available in Settings/About at any time. Once dismissed on first launch, doesn't show again unless user re-opens via Settings.

**Blocked by:** #29

**Status:** done

- [x] First-launch detection: shows disclosure once, persists "seen" flag in shared_preferences
- [x] Disclosure lists each capability with ✓ or ✗ and an inline reason for unavailable items
- [ ] Settings → About → "This device's capabilities" re-displays the same content
  - **Status (deferred to #42):** Ticket #42 (Settings screen) is not yet implemented in the codebase. #30 exposes a public route builder `buildSettingsAboutCapabilitiesRoute(capabilities)` (in `lib/screens/capability_disclosure.dart`) and a `CapabilityDisclosurePage(mode: CapabilityDisclosureMode.settingsAbout)` constructor so #42 can wire the entry point when the Settings screen lands. The disclosure screen itself is fully implemented and reusable; the only remaining work is a one-line link in the future Settings/About screen.
- [x] iOS-specific text present and helpful (matches spec §3.1 verbatim)
  - Verbatim text from SPEC.md §3.1: **"SMS features unavailable — Apple doesn't allow apps to send or read SMS automatically."** — exposed as `kIosDisclosureVerbatim` in `lib/screens/capability_disclosure.dart` and shown verbatim in a banner above the row list whenever `capabilities.platform == 'ios'` and either SMS feature is unavailable.
- [x] Visual: simple, scannable, dismissible

## Implementation notes

- **Files added/modified:**
  - `lib/screens/capability_disclosure.dart` — new file. Contains `CapabilityDisclosurePage` (used for both first-launch and Settings/About modes), `hasSeenCapabilityDisclosure()` / `markCapabilityDisclosureSeen()` helpers (SharedPreferences key `capability_disclosure_seen_v1`), and `buildSettingsAboutCapabilitiesRoute()` for #42 to wire up later.
  - `lib/main.dart` — added the first-launch `_FirstLaunchGate` widget that reads the seen flag and pushes the disclosure on top of `RelayLinkHome` when the user hasn't seen it yet.
  - `test/screens/capability_disclosure_test.dart` — 12 widget tests covering: 9-capability list, ✓/✗ icon counts per platform, iOS banner verbatim, first-launch flag persistence, Settings/About "Close" doesn't touch the flag, and helper round-trip.
- **Visual:** Single-child `Column` inside a `SingleChildScrollView` so all 9 rows are always in the widget tree (testable without scroll gymnastics); `_CapabilityRow` is a `ListTile` with a leading `Icons.check_circle` (green) / `Icons.cancel` (red), the feature name as title, and the reason as subtitle (or `"available"` when supported).
- **Mode toggle:** the confirm button label switches between "Got it" (first-launch, persists flag + pops) and "Close" (Settings/About, just pops).
- **iOS banner:** shown above the row list only when `platform == 'ios'` and either SMS row is unavailable, displaying the SPEC §3.1 verbatim string.
- **Tests:** `flutter analyze` clean for the new/modified files; `flutter test test/screens/capability_disclosure_test.dart` passes 12/12. Full suite has 168 tests (3 pre-existing failures unrelated to #30 — `test/alerts/allowlist_test.dart`, `test/crypto/direct_test.dart`, `test/widget_test.dart` — all from concurrent in-flight work by other agents).
