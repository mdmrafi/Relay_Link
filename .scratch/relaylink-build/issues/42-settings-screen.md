# 42 — Settings/About screen (capability disclosure, Gateway toggle, README link)

**What to build:** `lib/screens/settings.dart` — settings screen with: "This device's capabilities" entry (#30), "Act as gateway for nearby devices" toggle (#21), README link (in-app webview or external), App version, Code-of-Conduct disclosure link.

**Blocked by:** #30, #21

**Status:** ready-for-agent

- [ ] Capabilities entry navigates to disclosure screen (#30)
- [ ] Gateway toggle is the same as in #21, presented in Settings context
- [ ] README link opens the project README (or hosted version)
- [ ] App version shown
- [ ] Code-of-Conduct disclosure: lists exactly what's collected (device ID, optional location, phone numbers via SMS features, evidence capture) and why