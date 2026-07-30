# RelayLink Mesh Transport — Protocol Comparison

This document compares the three mesh transports considered for the
RelayLink demo:

| Transport | Role | Status |
|---|---|---|
| **BLE** (current) | Primary — `flutter_nearby_connections` P2P_CLUSTER | Ships in the demo app |
| **Wi-Fi Direct** (Plan B) | Fallback when BLE flakes on demo devices | Implemented in `lib/mesh/discovery_wifi_direct.dart` |
| **Custom UDP** (research) | LAN-only experimental fallback | Not implemented — documented for completeness |

The interface both transports honor is `MeshDiscovery` in
`lib/mesh/discovery.dart`. `MeshTransport` (Ticket #08) talks to
*either* implementation through that single seam, so switching
transports at the app bootstrap is a one-line change.

---

## Quick reference

| Axis | BLE (current) | Wi-Fi Direct (Plan B) | Custom UDP |
|---|---|---|---|
| **Range** | ~10–30 m typical (40 m line-of-sight) | ~50–200 m typical (one SOHO AP coverage) | LAN-only (router scope) |
| **Throughput** | ~100–250 kbps practical | ~20–250 Mbps (Wi-Fi 5/6) | 1 Gbps+ (LAN) |
| **Battery** | Low (designed for low duty cycle) | Medium-high (full Wi-Fi radio) | Highest (sockets + Wi-Fi) |
| **Multi-hop** | Yes (BLE mesh extensions exist) | Yes (group owner can bridge) | Routed (LAN only) |
| **OS support** | Android + iOS native | Android (Wi-Fi P2P) — iOS uses Multipeer Connectivity (separate API) | All platforms |
| **Permissions** | `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` (A12+); `NSBluetoothAlwaysUsageDescription` (iOS) | `ACCESS_WIFI_STATE` / `CHANGE_WIFI_STATE` (Android); `NSLocalNetworkUsageDescription` (iOS) | `INTERNET` (no extra on iOS) |
| **Time-to-deploy** | 1–2 days (package exists) | 3–5 days (Kotlin/Swift glue, no blessed plugin) | 5–10 days (need multicast DNS + pairing) |
| **Demo readiness** | High (well-trodden path) | Medium (only if BLE flakes) | Low (no clear win over Wi-Fi Direct) |
| **Offline (no AP)** | Yes | Yes (peer-to-peer) | No (LAN requires AP unless raw Wi-Fi) |
| **Reliability on demo hardware** | Occasional radio contention drops | More robust on Wi-Fi-rich chipsets | Best-effort |

---

## Pros and cons

### BLE (current primary)

**Pros**
- Excellent battery profile — peers can advertise for hours on a single
  3000 mAh battery.
- Both Android and iOS expose a documented, blessed path:
  `flutter_nearby_connections` (P2P_CLUSTER strategy) on Android, and
  `MultipeerConnectivity` on iOS via the same plugin.
- Stays within a single radio for the whole melange — no contention
  with the device's Wi-Fi association.
- Background-friendly on both platforms (subject to the usual
  iOS `CBPeripheralManager` 10s reset, which `MeshTransport` already
  re-arms).

**Cons**
- Throughput is the bottleneck for any payload beyond a short text
  blob (large encrypted message + attachment pushes ~300 kbps).
- Peripheral-mode contention: a few chipset/radio combos drop the
  link when the device is also associating with a Wi-Fi AP — exactly
  the situation the demo hits when the gateway toggles.
- Fragmentation is the application's problem: the BLE radio prefers
  ≤ 20-byte MTUs on ATT, ~244 on L2CAP, and adjacent frames compete
  for the same advertising slots.

### Wi-Fi Direct (Plan B)

**Pros**
- ~1000× the throughput (~20–250 Mbps) — entire photo attachments
  hop in tens of ms, not seconds.
- Longer range and more robust radios in the chipsets we have on
  the demo handsets.
- Works fully offline via a soft AP / group owner — no infra needed.
- Same `MeshDiscovery` seam — `MeshTransport` doesn't notice.

**Cons**
- No blessed Flutter package. The `wifi_direct` community plugin is
  Android-only and not in our offline cache. We ship a thin
  `MethodChannel` against `WifiP2pManager` (Android) +
  `MCSession` (iOS) and pay the Kotlin/Swift glue cost.
- Permission model is fiddly: `ACCESS_FINE_LOCATION` is required on
  Android pre-Q to discover peers, and revocation silently breaks
  discovery without a clean error surface.
- Higher battery draw while a group is active — fine for a few-min
  demo, painful for a multi-day field deployment.
- Group ownership is sticky: the GO owns the IP subnet and bridges
  to the legacy Wi-Fi, which complicates multi-hop routing.

### Custom UDP (research)

**Pros**
- Full control over framing, encryption, fragmentation, congestion.
- LAN-scoped when the demo is on a known Wi-Fi — fastest throughput.
- No platform permission drama beyond `INTERNET`.

**Cons**
- Router-bound when using the standard socket API. Reaching
  Wi-Fi-Direct scope requires raw `sendto` on a `pf_packet` socket
  (Android needs root — not a path we're willing to ship).
- Multicast DNS + pairing has to be hand-rolled; off-the-shelf
  libraries (`dns_sd`, `jmdns`) are battle-scarred.
- Operationally indistinguishable from Wi-Fi Direct for our demo
  but with significantly more code to maintain. Only wins if the
  field deployment is *always* on a known AP.

---

## Decision matrix

Weights reflect the demo priorities (demo readiness, reliability on
demo hardware, time-to-deploy). 1 = unacceptable, 5 = ideal.

| Axis | Weight | BLE | Wi-Fi Direct | Custom UDP |
|---|---|---:|---:|---:|
| Range (≥ 30 m) | 3 | 2 | 4 | 4 |
| Throughput (≥ 1 Mbps) | 2 | 1 | 5 | 5 |
| Battery (≤ 5%/h) | 3 | 5 | 2 | 1 |
| OS support (Android+iOS) | 5 | 5 | 3 | 5 |
| Offline (no AP) | 5 | 5 | 5 | 1 |
| Reliability on demo hardware | 5 | 3 | 4 | 4 |
| Time-to-deploy (≤ 2 days) | 4 | 5 | 3 | 2 |
| Background survival | 3 | 4 | 3 | 5 |
| **Weighted total** |  | **104** | **96** | **89** |

(The weighted sum is a directional aid, not a regression — the
matrix is supplied for human judgement.)

---

## Decision

**BLE is the primary transport.** It is the only option that wins
on battery, time-to-deploy, and background-survival simultaneously,
and the demo flow is small enough that the throughput ceiling is not
binding.

**Wi-Fi Direct is the Plan B fallback.** When the bootstrap detects
that BLE is unavailable or unstable on the demo devices (radio
contention with the gateway Wi-Fi, peripheral-mode drops, etc.) the
app swaps `MeshDiscovery` for `WifiDirectMeshDiscovery`. The same
`MeshRelaySeenCache`, gateway, and encryption envelope apply.

**Custom UDP is rejected.** It is operationally equivalent to
Wi-Fi Direct for our use case but with more code to maintain and
no offline story without an AP.

---

## Triggering the switch

The bootstrap monitors `MeshDiscovery.isBluetoothOn` and the
`peersStream` for connectivity stalls. After three consecutive
discovery-rounds with no peers found AND a successful
`WifiDirectMeshDiscovery.start()` handshake, the bootstrap registers
the Wi-Fi Direct discovery with the transport manager and unregisters
the BLE one. Recovery is symmetric: when BLE comes back, the
manager switches back within the next peer-list cycle.

This is implemented in `lib/bootstrap/mesh_strategy.dart` (NOT in
this commit — see Ticket #M-PlanB-Switch for the bootstrap work).
