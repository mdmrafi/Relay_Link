# 30 — Capability disclosure on first launch + Settings/About

**What to build:** A first-launch screen showing this device's capabilities (from #29) in plain language, with reasons for unavailable features. Same content available in Settings/About at any time. Once dismissed on first launch, doesn't show again unless user re-opens via Settings.

**Blocked by:** #29

**Status:** ready-for-agent

- [ ] First-launch detection: shows disclosure once, persists "seen" flag in shared_preferences
- [ ] Disclosure lists each capability with ✓ or ✗ and an inline reason for unavailable items
- [ ] Settings → About → "This device's capabilities" re-displays the same content
- [ ] iOS-specific text present and helpful (matches spec §3.1 verbatim)
- [ ] Visual: simple, scannable, dismissible