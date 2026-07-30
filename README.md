# RelayLink

RelayLink is an offline-first, peer-to-peer alerting prototype built in Flutter. When the internet is down or hostile, devices swap short text messages over local radios (Bluetooth mesh, SMS, Wi-Fi Direct), buffer what they receive, and forward it opportunistically. Devices with a working internet connection can opt into "gateway mode" and ferry other devices' encrypted mesh traffic to a Firestore relay, so alerts can reach a coordination channel without ever trusting the gateway with plaintext.

## What it does (verified against `lib/`)

- **Encrypted local messaging over mesh, SMS, and internet.** Every transport carries the same `Message` envelope through a shared `Transport` interface (`lib/transport/transport.dart`); the manager fans out in parallel (`TransportManager.fanOutSend`) so a slow transport never blocks the others. **BROADCAST bodies are encrypted end-to-end** through the chat widget: `LocalChatController` encrypts with `BroadcastCrypto` keyed on `channelId`, the envelope JSON rides in `Message.payload`, and the chat widget renders plaintext back via an injected `MessageDecryptor` (`lib/screens/chat.dart`).
- **Verified-org alerts.** Outgoing broadcasts can be tagged with an org id; receiving devices verify the tag against a 24-hour-TTL allowlist (`lib/alerts/allowlist.dart`, `assets/verified_orgs.json`) and render a `VerifiedBadge` (`lib/widgets/verified_badge.dart`). The current asset ships three demo entries, all flagged `"demo": true`; the loader rejects non-demo entries until a production fetcher is wired.
- **Opportunistic mesh relay.** When two peers can't see each other, intermediate devices decrement TTL, increment `hop_count`, and forward what they've seen — guarded by an LRU seen cache (`lib/mesh/relay.dart`, `LruSeenCache` capacity 2000) and a Bloom-filter peer-sync (`lib/mesh/bloom.dart`, m=19171 bits, k=7, theoretical FPR ≈ 0.81%).
- **Evidence Vault.** Locally captured text is encrypted at rest with AES-256-GCM using a three-layer key ladder (`lib/vault/store.dart`): per-record key, vault wrapping key, and an identity-derived wrap key. Storage is text-only in this build; photos, video, and audio are deferred.
- **Gateway mode toggle (opt-in).** The Settings tile (`lib/features/gateway/toggle.dart`) shows the SPEC §10 safety warning verbatim and requires an explicit "Confirm" before enabling. With the toggle on, `lib/features/gateway/relay.dart` shuttles mesh traffic up to Firestore and back down again, subject to the safety boundaries in that file (toggle-off drop, addressed-to-self drop, seen-cache drop).

## Architecture overview

| Layer | Responsibility | Key files |
|---|---|---|
| Models | Single `Message` envelope used by every transport; supports BROADCAST, DIRECT, ALERT. | `lib/models/message.dart` |
| Crypto | Device identity (Ed25519 + X25519), broadcast symmetric crypto (wired end-to-end through chat), direct session. | `lib/crypto/identity.dart`, `lib/crypto/broadcast.dart`, `lib/crypto/direct.dart`, `lib/crypto/double_ratchet.dart` |
| Transports | Shared `Transport` interface + fan-out manager; concrete mesh/internet/SMS implementations. | `lib/transport/transport.dart`, `lib/transport/internet.dart`, `lib/mesh/transport.dart`, `lib/sms/transport.dart` |
| Mesh | Discovery + relay + Bloom peer-sync. The production platform is currently a stub. | `lib/mesh/discovery.dart`, `lib/mesh/relay.dart`, `lib/mesh/bloom.dart` |
| SMS | Fragmented envelope send + receive path with reassembly; DIRECT-over-SMS uses `DirectSmsAdapter` (no in-band encryption yet — see Cryptography disclosure). | `lib/sms/transport.dart`, `lib/sms/platform_channel.dart`, `lib/sms/direct_adapter.dart`, `lib/sms/fanout.dart` |
| Channels | Per-channel key registry and QR-based invites. | `lib/channels/keys.dart`, `lib/channels/qr.dart` |
| Features | Gateway toggle UI + relay orchestrator; Evidence Vault capture/list/view/compose. | `lib/features/gateway/toggle.dart`, `lib/features/gateway/relay.dart`, `lib/vault/store.dart` |
| Screens | App shell: Home, Chat, Vault, Capability Disclosure. | `lib/screens/home.dart`, `lib/screens/chat.dart`, `lib/screens/vault.dart`, `lib/screens/capability_disclosure.dart` |
| Backend | Firebase init + Firestore/Storage paths; rules enforce schema-version + per-collection field protection. | `lib/backend/firebase.dart`, `lib/backend/schemas.dart`, `firestore.rules` |
| Capabilities | Runtime detection of 9 device features used by the capability-disclosure gate. | `lib/capabilities/detect.dart` |
| Alerts | Verified-org allowlist with 24h TTL + badge widget for verified senders. | `lib/alerts/allowlist.dart`, `lib/widgets/verified_badge.dart` |

## Cryptography disclosure (D5)

We do **not** ship a Signal-grade ratchet. Decision D5 in `STRESS-TEST.md` records that `libsignal_protocol_dart` v0.8.2 was judged **NOT USABLE** because its public API forces X3DH and provides no entry point that accepts an externally-supplied shared secret (see `VERDICT.md`). License: libsignal is AGPL-3.0, which would also propagate through this app if it linked in.

What we actually ship:

- **BROADCAST** (wired end-to-end through the chat controller): `BroadcastCrypto` (`lib/crypto/broadcast.dart`) — AES-256-GCM with a per-channel 256-bit key. The default public-channel key is embedded in source as `networkKey` and is documented in-file as "⚠️ EMBEDDED IN SOURCE — NOT A SECRET"; custom channels can be registered at runtime via `BroadcastCrypto.setChannelKey(channelId, key)`. Channel id is bound as AAD so a message can't be replayed across channels. `LocalChatController.sendMessage` encrypts the body and the chat widget decrypts via the injected `MessageDecryptor`; nothing on the wire is plaintext.
- **DIRECT**: `DirectSession` (`lib/crypto/direct.dart`) — HKDF-chain fallback. Header comment: *"this class is the LEGACY HKDF-chain fallback from the original ticket #13 work. The full Double Ratchet has since been implemented and lives at `package:relaylink/crypto/double_ratchet.dart`"*. Provides forward secrecy; **does not provide post-compromise secrecy**. **Library-only — not invoked by any transport path today.** A `DirectMessageEncryptor` abstract seam exists at `lib/vault/send_on_connect.dart` but has no concrete implementation, so DIRECT bodies flow as `Message.payload` bytes (i.e. today they are plain bytes unless the caller wires `DirectSession` themselves).
- **Double Ratchet**: `DoubleRatchetSession` (`lib/crypto/double_ratchet.dart`) — a from-scratch pure-Dart implementation, library-only and unit-tested. It is **not wired into any transport** as of this build; following ticket (#47) covers the wire-up.
- **Identity**: `DeviceIdentity` (`lib/crypto/identity.dart`) — Ed25519 signing key + X25519 ECDH key, persisted via `flutter_secure_storage`. `senderId` is derived from the Ed25519 public key.

If you need a real Signal-grade ratchet today, do not ship RelayLink for that use case.

## Cut / deferred (with ticket refs)

The following items are intentionally **not** in this build. Each is verifiable in the code:

- **Real Bluetooth mesh radio.** `lib/mesh/discovery.dart` defaults to `StubMeshDiscoveryPlatform`; no BLE radio is actually turned on in the shipped app. The transport-layer envelope (`MeshTransport`, `MeshDiscovery`, `MeshRelay`, peer-sync) is fully implemented and unit-tested; only the platform-channel call to a real BLE library is missing. *(Tickets: #07, #08 partial — the transport is wired, the platform is not.)*
- **iOS Multipeer Connectivity.** Stub only; no native side is shipped. *(#07)*
- **Wi-Fi Direct.** Stub only; no native side is shipped. *(#07)*
- **DIRECT crypto wire-up (post-compromise security).** `DirectSession` and `DoubleRatchetSession` are libraries with passing tests; neither is invoked by the DIRECT transport paths today. The `DirectMessageEncryptor` seam at `lib/vault/send_on_connect.dart` has no concrete implementation. *(#13, #47)*
- **Verified-org production fetcher.** `assets/verified_orgs.json` ships three `"demo": true` entries (`demo_red_crescent`, `demo_community_net`, `demo_climate_watch`); the loader refuses non-demo entries. *(#36)*
- **Vault media.** Photos, video, audio are deferred; the Vault UI is text-only. *(#32 partial)*
- **iOS SMS.** `lib/sms/platform_channel.dart` throws on iOS; SMS is Android-only.
- **Real Firestore credentials in-repo.** `firestore.rules` is committed and ready, but no production Firebase project is bundled; first launch with no Firebase config runs in local-only mode (`lib/backend/firebase.dart` → `FirestoreGatewayUnavailable`).

## How to run

```bash
# 1. Install dependencies
flutter pub get

# 2. Run unit + widget tests (no device required)
flutter test

# 3. Run the demo app
flutter run
```

What works on which target:

| Target | Mesh | SMS | Internet | Gateway |
|---|---|---|---|---|
| Android emulator/device | stub discovery | yes (with permissions) | yes if Firebase configured | yes if Firebase configured |
| iOS simulator/device | stub discovery | throws on iOS | yes if Firebase configured | yes if Firebase configured |
| Test fixtures | simulated via `MeshTransport.setSimulatedPeerConnected` / `_FakeMeshPlatform` | simulated via `SmsTransport.simulateIncoming` | simulated via `FakeFirestoreGateway` | simulated via `GatewayRelay` tests |

Permission rationale (Android): `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `ACCESS_FINE_LOCATION`, `NEARBY_WIFI_DEVICES`, `SEND_SMS`, `RECEIVE_SMS`, `READ_SMS`, `INTERNET`, `ACCESS_NETWORK_STATE`. The capability-disclosure screen (`lib/screens/capability_disclosure.dart`) shows the iOS-specific rationale verbatim and gates first launch.

## Test status

- **677 tests pass**, 6 skipped (all 6 are the SCALE_N-gated scale-harness scenarios; they print "Set --dart-define=SCALE_N=<n> to run scale harness" and are intentionally skipped on the regular CI run).
- `flutter analyze` reports 0 errors, 0 warnings, with a handful of info-level lint suggestions (mostly `unintended_html_in_doc_comment`, `avoid_print`, `prefer_initializing_formals`).
- Per-layer test counts (active tests only, scale harness excluded): crypto 41, mesh 116, sms 84, transport 39, gateway 39, vault 34, ui/screen 132, alerts 23, channels 54, capability 50, storage 21, models 20, allowlist 7, integration 2, demo 3, misc 3. Total file count: 52.

## Open follow-up tickets

- **#47 — Wire Double Ratchet into DIRECT transports.** Replace the HKDF-chain `DirectSession` call sites in the DIRECT paths (SMS + internet + mesh) with `DoubleRatchetSession`. Forward-secrecy status stays; post-compromise secrecy becomes real.
- **#48 — Relay-strategy harness.** Build the evaluation harness so future changes to `lib/features/gateway/relay.dart` (push-up cadence, pull-down filters, safety boundaries) can be compared against a fixed baseline.
- **#36 (follow-on) — Production verified-org fetcher.** Replace the demo-only allowlist loader with a signed, refreshable source so non-demo orgs can be added without code changes.

## Data transparency

Four categories of data touch this app:

1. **Pseudonymous device id.** Generated locally from your Ed25519 key (`DeviceIdentity.senderId`, derived from the Ed25519 public key). Stored in `flutter_secure_storage`. Sent as the `sender_id` field on every outgoing message.
2. **Optional coarse location.** Only requested when the user opts into Bluetooth/Wi-Fi Direct discovery (Android `ACCESS_FINE_LOCATION` / `NEARBY_WIFI_DEVICES`). Not transmitted by RelayLink itself; the OS uses it to discover nearby radios.
3. **Phone numbers.** Used only for SMS transports. Stored locally for the contacts you've chosen; sent as part of an SMS only when you actually send a message to that number. Not exfiltrated to any other service.
4. **Evidence Vault text.** Stored locally, encrypted at rest with AES-256-GCM via the three-layer key ladder in `lib/vault/store.dart`. Never leaves the device unless you explicitly choose to send a vault item through a transport.

No analytics, no crash reporting, no third-party SDKs beyond `cloud_firestore`, `firebase_storage`, `firebase_core`, and `mobile_scanner` (the scanner only runs when you tap "Scan QR" on the channel-invite screen).

## License

MIT. See [`LICENSE`](LICENSE); every source file carries an SPDX-License-Identifier header.
