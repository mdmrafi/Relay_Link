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
│   └── direct.dart            # HKDF-chain DIRECT session (#13)
├── channels/
│   └── keys.dart              # ChannelKeyStore — 32-byte AES keys per channel (#15)
├── transport/                 # Carrier-agnostic abstraction (#06)
│   ├── transport.dart         # Transport, TransportManager, LoopbackTransport
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
| DIRECT     | HKDF-chain (HKDF-SHA256)  | ECDH(X25519) shared secret              | Each direction has its own root; per-message key is discarded after use.               |
| Vault (at rest) | AES-256-GCM          | Vault-wrapping key derived from device identity | Per-record key wrapped with vault-wrapping key wrapped with device-identity key. |

The `libsignal_protocol_dart` package was rejected (D5 verdict) — see
[`VERDICT.md`](.scratch/relaylink-build/issues/12-libsignal-verdict.md)
for the full reasoning. The HKDF-chain in `lib/crypto/direct.dart` is a
deliberately simple, transparent fallback: no Double Ratchet, no X3DH,
but forward secrecy by way of per-message key derivation and discard.

## Storage

* **LocalDb** (sqflite) — messages, vault records, seen-cache, allowlist.
  Schema migration v1 → v2 adds the per-record AES key + nonce columns
  for the vault (#31).
* **flutter_secure_storage** — device identity seed, vault-wrapping key.
  Never contains plaintext vault records.

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