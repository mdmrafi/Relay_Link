# 16 — Channel QR encode + scan

**What to build:** `lib/channels/qr.dart` exposing `encodeChannelQR(channelId, key)` returning a `Uint8List` PNG bytes (using `qr_flutter` or `mobile_scanner`), and `decodeChannelQR(bytes)` returning `(channelId, key)`. Includes a Flutter screen that displays a QR for a freshly-generated channel and a screen with camera-scan for joining.

**Blocked by:** #15

**Status:** ready-for-agent

- [ ] Encode produces a scannable QR (tested by scanning the QR with a phone and recovering the data)
- [ ] Decode round-trip: encode → decode → original (channelId, key) match
- [ ] Two screens: "Show this QR" (for the channel creator) and "Scan QR to join" (for the joiner, uses camera)
- [ ] Camera permission requested with rationale
- [ ] iOS: same screens; mobile_scanner package supports both platforms