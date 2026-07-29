# 43 — README (bilingual, demo script, honest disclosure per §17)

**What to build:** `README.md` per spec §17: project description, build instructions, demo script (from STRESS-TEST §6), honest "what this demo does and doesn't prove" section (D3/D5/D6/D7/D8 fallback disclosures), bilingual content (English + one other language), Code-of-Conduct data disclosure, AI-tool disclosure, license.

**Blocked by:** All other tickets (so the README can accurately describe what shipped)

**Status:** ready-for-agent

- [ ] Section: "What RelayLink is" — 2-3 paragraphs
- [ ] Section: "How to build" — `flutter pub get && flutter run -d <device>` plus Firebase setup
- [ ] Section: "Demo script" — 8-step demo from STRESS-TEST §6
- [ ] Section: "What this demo does and doesn't prove" — explicit list of cut/fallback items
- [ ] Section: "Architecture overview" — brief description of mesh, crypto, transports, vault, gateway
- [ ] Section: "Honest disclosure of decisions D1-D8" — what was chosen, what was cut, why
- [ ] Section: "Data collected" — device ID, optional location, phone numbers via SMS features, evidence capture — what's stored where, why
- [ ] Section: "AI tool disclosure" — naming tools used and confirming compliance with hackathon rules
- [ ] Bilingual: English + one other language (target language to be determined by team)
- [ ] License: MIT (default per §17)