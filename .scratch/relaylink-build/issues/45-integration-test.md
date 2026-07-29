# 45 — Two-device integration test (manual, recorded)

**What to build:** A runnable integration scenario using two physical Android devices that exercises the full happy path: pair, send SOS over mesh, verify received and decrypted on the other device, save to evidence vault, custom channel isolation, BROADCAST-over-SMS fan-out (if SMS hardware available). Recorded as a video clip for the README.

**Blocked by:** All UI tickets (#38-#42), transport tickets (#08, #20, #26), vault (#32)

**Status:** ready-for-agent

- [ ] Script in `tools/demo_two_device.md` step-by-step for two physical devices
- [ ] Video recorded showing the full scenario
- [ ] Video included in README via embed or link
- [ ] All demoed scenarios pass on the two physical devices used for the recording
- [ ] Demo covers: first-launch disclosure, mesh SOS, custom channel isolation, vault capture, ALERT badge (if #37 ships), Gateway toggle UI (if #21 ships)