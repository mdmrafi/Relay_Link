# 04 — Message schema + JSON serialization

**What to build:** `lib/models/message.dart` defining the `Message` class per spec §5 with all fields, plus a `MessageMode` enum (`BROADCAST`, `DIRECT`), `MessageType` enum (`SOS`, `STATUS_SAFE`, `STATUS_HELP`, `CHAT`, `ALERT`, `ACK`, `EVIDENCE_NOTICE`), `MessageOrigin` enum (`MESH`, `SMS_BRIDGE`, `SMS_TRANSPORT`, `INTERNET`), and JSON encode/decode round-trip.

**Blocked by:** #01

**Status:** ready-for-agent

- [ ] All fields per spec §5: id, mode, type, channel_id, sender_id, sender_display_name, origin, recipient_id, payload, ratchet_header, location, created_at, ttl, hop_count, signature, in_response_to
- [ ] `payload` is `Uint8List`, base64-encoded in JSON for portability
- [ ] JSON round-trip test: encode → decode → all fields equal
- [ ] `ratchet_header` nullable, only present when mode = DIRECT
- [ ] Default TTLs encoded as constants: SOS=12, ALERT=10, others=8
- [ ] `signature` is base64-encoded Ed25519 signature
- [ ] UUIDs generated using a standard package (uuid), timestamp UTC