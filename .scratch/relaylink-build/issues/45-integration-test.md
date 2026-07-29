# 45 — Two-device integration test (manual, recorded)

**What to build:** A runnable integration scenario using two physical Android devices that exercises the full happy path: pair, send SOS over mesh, verify received and decrypted on the other device, save to evidence vault, custom channel isolation, BROADCAST-over-SMS fan-out (if SMS hardware available). Recorded as a video clip for the README.

**Blocked by:** All UI tickets (#38-#42), transport tickets (#08, #20, #26), vault (#32)

**Status:** in-progress

**2026-07-30 update:** All UI / transport / vault / SMS blocking tickets are
still pending per HANDOFF-session2.md. The strongest currently available
end-to-end path is `identity → broadcast crypto → message plumbing → local
storage`, all of which have shipped. This commit ships a **deterministic
in-process integration test** that exercises that path. It deliberately
avoids emulator / Bluetooth / network dependencies and runs in
`flutter test`. It will FAIL meaningfully if any of the following
regresses:

* `DeviceIdentity` — senderId derivation, Ed25519 sign/verify, X25519 ECDH
* `Message` — JSON wire-format, JSON round-trip, field-name drift
* `BroadcastCrypto` — AES-256-GCM MAC verification, AAD binding to channel id
* `LocalDb` — insert/get/seen-cache round-trip

The video + README inclusion items remain open (these are manual-physical-
device artifacts that require #38-#42 + transport to be live).

- [x] Deterministic, offline, no-emulator integration test exercising the strongest available path (`test/integration/two_device_e2e_test.dart`)
- [x] Test fails meaningfully if crypto or message plumbing regresses (verified by injecting a wrong-key regression into `BroadcastCrypto.decrypt`)
- [ ] Script in `tools/demo_two_device.md` step-by-step for two physical devices
- [ ] Video recorded showing the full scenario
- [ ] Video included in README via embed or link
- [ ] All demoed scenarios pass on the two physical devices used for the recording
- [ ] Demo covers: first-launch disclosure, mesh SOS, custom channel isolation, vault capture, ALERT badge (if #37 ships), Gateway toggle UI (if #21 ships)