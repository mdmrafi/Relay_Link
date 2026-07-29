# 26 — SMS re-injection into normal pipeline

**What to build:** `lib/sms/transport.dart` implementing `Transport` over the SMS platform channel (#23) and reassembler (#25). `send` fragments and dispatches via #23 to known phone numbers. `incoming` is fed by the reassembler's completion stream. Completed messages are added to seen-cache, TTL decremented, re-broadcast via TransportManager — same as messages received over mesh or internet, with `origin = SMS_TRANSPORT`.

**Blocked by:** #25, #23, #09

**Status:** done

- [x] `SmsTransport implements Transport`
- [x] `isAvailable()` returns true iff device has cell signal + permission
- [x] `send` looks up the recipient's phone number from a Contacts store (see #40) and dispatches fragments
- [x] `incoming` emits reassembled Message objects with `origin = SMS_TRANSPORT`
- [x] Messages received via SMS are added to seen-cache and re-broadcast via TransportManager — verified in tests
- [x] README discloses the cost/volume risk the spec §9 flags

## Assumptions made (because blockers were not yet in the repo)

The blocker tickets (#06 Transport interface, #24 fragmentation, #25 reassembly, #40 contacts) were not yet present when this ticket landed. The following minimal local adapters were used so the reinjection flow could be tested in isolation. When the canonical implementations land, the corresponding files in `lib/sms/` and `lib/transport/` should be merged with their canonical counterparts:

- `lib/transport/transport.dart` — minimal local `Transport` interface (drop-in merge with #06's canonical).
- `lib/sms/framing.dart` — minimal `frameMessage` / `parseSegment` for the `RL:msgid:idx/total:base64` format. Drop-in merge with #24.
- `lib/sms/reassembler.dart` — minimal `SmsReassembler` with buffer + dedupe + completion. Drop-in merge with #25.
- `lib/sms/transport.dart` — `SmsTransportHost` / `ContactsStore` / `SeenCache` / `TransportManagerHost` interfaces are declared as *host* abstractions so the transport doesn't directly depend on the eventual canonical implementations. Production wires up the real #06 / #40 / #05 implementations; tests pass fakes.

## Acceptance gates verified

- `flutter test test/sms/transport_test.dart` — 12 tests, all pass.
- `flutter test` — 149 tests, all pass (137 baseline + 12 new).
- `flutter analyze` — no issues.
