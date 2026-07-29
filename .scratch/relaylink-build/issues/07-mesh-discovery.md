# 07 — Mesh discovery + connect (Nearby Connections P2P_CLUSTER)

**What to build:** `lib/mesh/discovery.dart` wrapping `flutter_nearby_connections` (or equivalent) to discover nearby Android devices advertising RelayLink, manage connect/disconnect with backoff, surface peer list as a Stream. Implements the `Transport.isAvailable()` check (true when Bluetooth is on and permission granted).

**Blocked by:** #06

**Status:** ready-for-agent

- [ ] App advertises itself as a RelayLink peer on app start (toggleable for battery)
- [ ] Discovery picks up other RelayLink peers within Bluetooth range
- [ ] Connect succeeds on first attempt with backoff on failure (1s, 2s, 4s, max 30s)
- [ ] Peer list Stream emits on peer connect / disconnect
- [ ] Permission for BLUETOOTH_CONNECT and BLUETOOTH_ADVERTISE requested on first launch with rationale
- [ ] On iOS, equivalent wrapping of Multipeer Connectivity (or stub with "iOS mesh subset deferred" note)