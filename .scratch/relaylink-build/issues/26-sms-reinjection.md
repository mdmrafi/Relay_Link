# 26 — SMS re-injection into normal pipeline

**What to build:** `lib/sms/transport.dart` implementing `Transport` over the SMS platform channel (#23) and reassembler (#25). `send` fragments and dispatches via #23 to known phone numbers. `incoming` is fed by the reassembler's completion stream. Completed messages are added to seen-cache, TTL decremented, re-broadcast via TransportManager — same as messages received over mesh or internet, with `origin = SMS_TRANSPORT`.

**Blocked by:** #25, #23, #09

**Status:** ready-for-agent

- [ ] `SmsTransport implements Transport`
- [ ] `isAvailable()` returns true iff device has cell signal + permission
- [ ] `send` looks up the recipient's phone number from a Contacts store (see #40) and dispatches fragments
- [ ] `incoming` emits reassembled Message objects with `origin = SMS_TRANSPORT`
- [ ] Messages received via SMS are added to seen-cache and re-broadcast via TransportManager — verified in tests
- [ ] README discloses the cost/volume risk the spec §9 flags