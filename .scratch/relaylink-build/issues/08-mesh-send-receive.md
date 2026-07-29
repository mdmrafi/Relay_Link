# 08 — Mesh send/receive (basic)

**What to build:** `lib/mesh/transport.dart` implementing `Transport` over the discovery layer from #07. Uses BYTES payload type (not FILE) for messages. `send` encodes the Message to JSON, sends to all connected peers. `incoming` Stream decodes JSON back to Message.

**Blocked by:** #07

**Status:** ready-for-agent

- [ ] `MeshTransport implements Transport` with the four members
- [ ] `send` serializes to JSON, broadcasts to all currently connected peers
- [ ] `incoming` deserializes received bytes back to Message
- [ ] `isAvailable()` returns true iff Bluetooth radio on + permission granted + at least one service active
- [ ] Manual integration test: two devices in range, one sends, other receives, message contents match (verify with `flutter run` on both)