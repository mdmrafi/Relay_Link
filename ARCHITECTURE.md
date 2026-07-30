# RelayLink — Architecture

This document describes the moving parts of the RelayLink client and how
they fit together. It is a sibling of [`README.md`](README.md) (the
build / demo story) and [`SUBMISSION.md`](SUBMISSION.md) (the
hackathon submission form).

## Top-level layout

```
lib/
├── main.dart                  # App bootstrap, first-launch gate, transport wiring
├── models/                    # Plain-data types
│   └── message.dart           # Message envelope (id, mode, type, payload, …)
├── crypto/                    # Primitives — no IO, no Flutter
│   ├── identity.dart          # Ed25519 + X25519 device identity (#02)
│   ├── broadcast.dart         # AES-256-GCM channel-key crypto (#03)
│   ├── direct.dart            # HKDF-chain DIRECT session — production path (#13)
│   └── double_ratchet.dart    # Full Double Ratchet — library-only, not wired (#13)
├── channels/
│   └── keys.dart              # ChannelKeyStore — 32-byte AES keys per channel (#15)
├── transport/                 # Carrier-agnostic abstraction (#06)
│   ├── transport.dart         # Transport, TransportManager, EchoTransport
│   └── internet.dart          # FirestoreGateway + InternetTransport (#22)
├── mesh/
│   ├── bloom.dart             # Bloom filter helper
│   └── transport.dart         # Minimal in-process MeshTransport stub (#22)
├── sms/                       # SMS as a transport leg (#23–#28)
│   ├── platform_channel.dart  # Native SmsManager Method/EventChannel
│   ├── framing.dart           # RL:<msgid>:<idx>/<total>:<b64> segmentation (#24)
│   ├── reassembler.dart       # Buffer by msgid, dedup, 10-min timeout (#25)
│   ├── transport.dart         # SmsTransport — frames in, reassembles, reinjects (#26)
│   ├── fanout.dart            # BROADCAST → contacts SMS fan-out (#27)
│   ├── fanout_types.dart      # FanoutResult, SmsFanoutTransport seam
│   ├── direct_adapter.dart    # DIRECT → recipient's phone SMS (#28)
│   └── exceptions.dart
├── contacts/
│   ├── contact.dart           # Minimal Contact model
│   └── contacts_lookup.dart   # Lookup seam (#28)
├── features/gateway/          # Gateway mode (push/pull Firestore ↔ mesh, #22)
│   ├── relay.dart             # GatewayRelay orchestrator
│   └── toggle.dart            # Safety-warning toggle UI (#21)
├── alerts/
│   └── allowlist.dart         # VerifiedOrgsCache — 24h allowlist (#36)
├── screens/
│   └── capability_disclosure.dart  # First-launch + Settings gate (#30)
├── storage/
│   └── local_db.dart          # sqflite + flutter_secure_storage (#05, #31)
└── vault/
    └── store.dart             # AES-256-GCM vault envelope (#31)
```

## Data flow

### Send (outgoing) — fan-out

```
UI sends Message
       │
       ▼
BroadcastCrypto.encrypt (or DirectSession.encrypt for 1:1)
       │
       ▼
TransportManager.fanOutSend(msg)
       │      runs every registered Transport's `send` in parallel
       ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ MeshTransport │  │ SmsTransport │  │ InternetTrans │
│  (BLE/Nearby) │  │  (RL:…)      │  │  (Firestore) │
└──────────────┘  └──────────────┘  └──────────────┘
```

A slow or failing transport never blocks the others — `fanOutSend`
awaits in parallel and returns a `List<Object?>` of per-transport
outcomes (`null` = skipped because unavailable, error = throw).

### Receive (incoming) — relay

```
transport.incoming (Stream<Message>)
       │
       ▼
TransportManager
       │  applies seen-cache dedup + ttl decrement
       ▼
UI (chat list, SOS banner, vault capture, …)
```

For SMS, the path is one layer deeper:

```
Native SMS receiver (relaylink/sms/incoming EventChannel)
       │
       ▼
SmsPlatformChannel.incomingSms  (Stream<String>)
       │
       ▼
Reassembler.ingest              (buffer per msgid, dedup, complete)
       │
       ▼
SmsTransport._onReassembled     (JSON decode → Message)
       │
       ▼
_filterAndDecrement             (seen-cache + ttl + origin=smsTransport)
       │
       ▼
SmsTransport.incoming  ───────► TransportManager ───────► UI
```

## Cryptographic model

| Mode       | Algorithm                 | Key derivation                          | Notes                                                                                  |
|------------|---------------------------|-----------------------------------------|----------------------------------------------------------------------------------------|
| BROADCAST  | AES-256-GCM (per channel) | Out-of-band channel-key sharing (QR)    | Same ciphertext to every recipient; the channel key is the symmetric secret.           |
| DIRECT (production) | HKDF-chain (HKDF-SHA256) | ECDH(X25519) shared secret at QR exchange | Production path in `lib/sms/direct_adapter.dart` and `lib/transport/internet.dart`. Forward secrecy is preserved; post-compromise security is **not** (no DH ratchet). |
| DIRECT (library-only) | Double Ratchet (X25519 DH + symmetric HKDF chain + skipped-key storage capped at 1000) | ECDH(X25519) shared secret at QR exchange | `lib/crypto/double_ratchet.dart` — full implementation tested by `test/crypto/double_ratchet_test.dart`, but **not wired into any transport** in this build. |
| Vault (at rest) | AES-256-GCM          | Vault-wrapping key derived from device identity | Per-record key wrapped with vault-wrapping key wrapped with device-identity key. |

The `libsignal_protocol_dart` package was rejected (D5 verdict) — see
[`VERDICT.md`](.scratch/relaylink-build/issues/12-libsignal-verdict.md)
for the full reasoning. After the verdict, ticket #13 (`cutrev-ratchet`)
implemented the full Double Ratchet from scratch in pure Dart on top of
the same `cryptography` package primitives. The HKDF-chain in
`lib/crypto/direct.dart` is the binding-fallback that actually shipped
in production; the full Double Ratchet lives as a tested library, and
the mechanical work to swap the production path over to it (route
`DirectSession` → `DoubleRatchetSession` in the two transport call
sites) is recorded as a follow-up ticket, not part of this build.

## Storage

* **LocalDb** (sqflite) — messages, vault records, seen-cache, allowlist.
  Schema migration v1 → v2 adds the per-record AES key + nonce columns
  for the vault (#31).
* **flutter_secure_storage** — device identity seed, vault-wrapping key.
  Never contains plaintext vault records.

## Scale harness

The in-process mesh simulator under `test/scale/` proves the mesh-layer
primitives — TTL decrement, bloom-filter seen-cache, broadcast fan-out,
direct addressing — survive at scale before physical-hardware testing.

* **`RelayStrategy`** (`test/scale/relay_strategy.dart`) is the abstract
  seam between a peer's `transport.incoming` and the relay decision.
  When the real mesh transport lands, a `MeshRelayStrategy` will
  implement the same interface without touching the scenarios or
  metrics code.
* **`MirrorRelayStrategy`** (`test/scale/mirror_relay_strategy.dart`) is
  the in-process implementation against `LoopbackMeshDiscovery`. It
  performs seen-cache dedup, TTL decrement, hop-count increment, and
  re-broadcast — the same relay logic that previously lived inline in
  `_Peer._onIncoming`.
* **`peerErrorCount`** is now sourced from a real per-peer try/catch
  around `strategy.onIncoming` — a single bad peer cannot cascade into
  tearing the harness down. Previously hardcoded to `0` with a "Hook
  point reserved" comment.
* **Scenarios**: broadcast / direct / mixed / saturation + a bloom FPR
  probe. Gated on `SCALE_N=<n>` so the regular CI run stays at 314
  tests; the harness is opt-in via `--dart-define=SCALE_N=12` or
  `SCALE_N=20` for heavier runs.
* **Integration log**: N=4/8/12/20 runs at
  [`docs/scale-harness-integration-run-2026-07-30.md`](docs/scale-harness-integration-run-2026-07-30.md)
  — 0% FPR, 0 lost messages, 0 peer errors across all scenarios.

## Gateway mode

When the user toggles Gateway ON:

* `GatewayRelay` subscribes to the mesh transport's `incoming` and
  pushes each non-self, non-seen BROADCAST/DIRECT message up to
  Firestore (preserving `sender_id` — the relay is a courier).
* `InternetTransport` polls Firestore every 30s. Pulled messages are
  re-injected into the mesh via `TransportManager.fanOutSend` after
  seen-cache dedup and a hop-count increment.
* The toggle defaults to OFF and the first-launch capability
  disclosure (#30) requires the user to explicitly acknowledge the
  safety implications before it can be enabled.

## Submission package

The submission form, judging weights, and readiness checklist live in
[`SUBMISSION.md`](SUBMISSION.md). The AI-tool disclosure is in
[`AI-TOOLS.md`](AI-TOOLS.md). The Code-of-Conduct data disclosure is
in [`CODE-OF-CONDUCT.md`](CODE-OF-CONDUCT.md).