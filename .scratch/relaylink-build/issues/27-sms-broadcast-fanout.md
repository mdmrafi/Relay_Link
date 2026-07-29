# 27 — SMS BROADCAST fan-out to contacts

**What to build:** `lib/sms/fanout.dart` exposing `fanOutBroadcast(msg, contacts)` that takes a BROADCAST message and a list of Contacts with phone numbers, sends the same encrypted payload (#26's transport) to every contact's phone number in parallel.

**Blocked by:** #26, #40 (contacts)

**Status:** ready-for-agent

- [ ] Fans out a BROADCAST to every contact with a phone number on file
- [ ] Same encrypted payload for every recipient (the NETWORK_KEY or custom-channel key handles decryption, not per-recipient wrapping)
- [ ] Fan-out is parallelized via `Future.wait` to minimize wall-clock time
- [ ] Failures on individual recipients are logged but don't fail the whole fan-out
- [ ] Manual demo: device A has 3 saved contacts with phone numbers, A sends SOS BROADCAST, all 3 receive and decrypt on separate phones