# RelayLink

RelayLink is an offline-first, peer-to-peer alerting prototype built in Flutter. When the internet is down or hostile, devices swap short text messages over local radios (Bluetooth mesh, SMS, Wi-Fi Direct), buffer what they receive, and forward it opportunistically. Devices with a working internet connection can opt into "gateway mode" and ferry other devices' encrypted mesh traffic to a Firestore relay, so alerts can reach a coordination channel without ever trusting the gateway with plaintext.

## What it does (verified against `lib/`)

- **Encrypted local messaging over mesh, SMS, and internet.** Every transport carries the same `Message` envelope through a shared `Transport` interface (`lib/transport/transport.dart`); the manager fans out in parallel (`TransportManager.fanOutSend`) so a slow transport never blocks the others. **BROADCAST and DIRECT bodies are encrypted end-to-end** through the chat widget: `RemoteChatController` (the production `ChatController` impl, `lib/screens/remote_chat_controller.dart`) encrypts BROADCAST via `BroadcastCrypto` keyed on `channelId` and DIRECT via the peer's `DirectSession`, the envelope JSON rides in `Message.payload`, and the chat widget renders plaintext back via a mode-dispatched `MessageDecryptor` constructed in `bootstrapServices` (`lib/app/bootstrap.dart`). `lib/main.dart` calls `bootstrapServices()` once at boot so `TransportManager` (with `MeshTransport`, `SmsTransport`, `InternetTransport` registered), `LocalDb`, `DeviceIdentity`, `BroadcastCrypto`, `DirectSessionStore`, `RepositoryContactsLookup`, and `RemoteChatController` are all constructed together.
- **Verified-org alerts.** Outgoing broadcasts can be tagged with an org id; receiving devices verify the tag against a 24-hour-TTL allowlist (`lib/alerts/allowlist.dart`, `assets/verified_orgs.json`) and render a `VerifiedBadge` (`lib/widgets/verified_badge.dart`). The current asset ships three demo entries, all flagged `"demo": true`; the loader rejects non-demo entries until a production fetcher is wired.
- **Contact pairing via invite tokens.** Two devices exchange a `ContactInvite` token (`relaylink-invite-v1:<b64>` payload with the sender's X25519 public key, displayed name, and 16-byte salt, `lib/crypto/contact_invite.dart`). The receiving device decodes the token, derives a shared root via X25519 ECDH + HKDF-SHA256, and constructs a `DirectSession` (`lib/crypto/direct.dart`). The session is persisted across restarts via `DirectSessionStore` (secure-storage-backed, `lib/crypto/direct_session_store.dart`). The Contacts screen exposes a "Pair via invite" button (`lib/screens/contacts.dart`) that opens a paste-invite dialog; the QR-scanner variant is a follow-up (`mobile_scanner` integration).
- **Opportunistic mesh relay.** When two peers can't see each other, intermediate devices decrement TTL, increment `hop_count`, and forward what they've seen — guarded by an LRU seen cache (`lib/mesh/relay.dart`, `LruSeenCache` capacity 2000) and a Bloom-filter peer-sync (`lib/mesh/bloom.dart`, m=19171 bits, k=7, theoretical FPR ≈ 0.81%).
- **Evidence Vault.** Locally captured text is encrypted at rest with AES-256-GCM using a three-layer key ladder (`lib/vault/store.dart`): per-record key, vault wrapping key, and an identity-derived wrap key. Storage is text-only in this build; photos, video, and audio are deferred.
- **Gateway mode toggle (opt-in).** The Settings tile (`lib/features/gateway/toggle.dart`) shows the SPEC §10 safety warning verbatim and requires an explicit "Confirm" before enabling. With the toggle on, `lib/features/gateway/relay.dart` shuttles mesh traffic up to Firestore and back down again, subject to the safety boundaries in that file (toggle-off drop, addressed-to-self drop, seen-cache drop).

## Architecture overview

| Layer | Responsibility | Key files |
|---|---|---|
| Models | Single `Message` envelope used by every transport; supports BROADCAST, DIRECT, ALERT. | `lib/models/message.dart` |
| Crypto | Device identity (Ed25519 + X25519), broadcast symmetric crypto (wired end-to-end through chat), direct session (wired end-to-end through `RemoteChatController`), `ContactInvite` codec + ECDH bootstrap, Double Ratchet (library-only, follow-up ticket). | `lib/crypto/identity.dart`, `lib/crypto/broadcast.dart`, `lib/crypto/direct.dart`, `lib/crypto/contact_invite.dart`, `lib/crypto/direct_session_store.dart`, `lib/crypto/double_ratchet.dart` |
| Transports | Shared `Transport` interface + fan-out manager; concrete mesh/internet/SMS implementations, registered at boot via `bootstrapServices`. | `lib/transport/transport.dart`, `lib/transport/internet.dart`, `lib/mesh/transport.dart`, `lib/sms/transport.dart` |
| Mesh | Discovery + relay + Bloom peer-sync. The production platform is currently a stub. | `lib/mesh/discovery.dart`, `lib/mesh/relay.dart`, `lib/mesh/bloom.dart` |
| SMS | Fragmented envelope send + receive path with reassembly; DIRECT-over-SMS uses `DirectSmsAdapter`. | `lib/sms/transport.dart`, `lib/sms/platform_channel.dart`, `lib/sms/direct_adapter.dart`, `lib/sms/fanout.dart` |
| Channels | Per-channel key registry and QR-based invites. | `lib/channels/keys.dart`, `lib/channels/qr.dart` |
| Features | Gateway toggle UI + relay orchestrator; Evidence Vault capture/list/view/compose. | `lib/features/gateway/toggle.dart`, `lib/features/gateway/relay.dart`, `lib/vault/store.dart` |
| Screens | App shell: Home, Chat, Vault, Contacts, Channels, Settings, Capability Disclosure. Chat is backed by `RemoteChatController`; Contacts is backed by `RepositoryContactsLookup` with a paste-invite pair flow. | `lib/screens/home.dart`, `lib/screens/chat.dart`, `lib/screens/contacts.dart`, `lib/screens/remote_chat_controller.dart`, `lib/screens/vault.dart`, `lib/screens/capability_disclosure.dart` |
| Backend | Firebase init + Firestore/Storage paths; rules enforce schema-version + per-collection field protection. | `lib/backend/firebase.dart`, `lib/backend/schemas.dart`, `firestore.rules` |
| Bootstrap | Single-shot service-locator that constructs every long-lived singleton (`LocalDb`, `DeviceIdentity`, `DirectSessionStore`, `TransportManager`, `BroadcastCrypto`, `RepositoryContactsLookup`, `RemoteChatController`) exactly once at boot and injects the result via `ProviderScope.overrides`. | `lib/app/bootstrap.dart`, `lib/main.dart` |
| Capabilities | Runtime detection of 9 device features used by the capability-disclosure gate. | `lib/capabilities/detect.dart` |
| Alerts | Verified-org allowlist with 24h TTL + badge widget for verified senders. | `lib/alerts/allowlist.dart`, `lib/widgets/verified_badge.dart` |

## Cryptography disclosure (D5)

We do **not** ship a Signal-grade ratchet. Decision D5 in `STRESS-TEST.md` records that `libsignal_protocol_dart` v0.8.2 was judged **NOT USABLE** because its public API forces X3DH and provides no entry point that accepts an externally-supplied shared secret (see `VERDICT.md`). License: libsignal is AGPL-3.0, which would also propagate through this app if it linked in.

What we actually ship:

- **BROADCAST** (wired end-to-end through the chat controller): `BroadcastCrypto` (`lib/crypto/broadcast.dart`) — AES-256-GCM with a per-channel 256-bit key. The default public-channel key is embedded in source as `networkKey` and is documented in-file as "⚠️ EMBEDDED IN SOURCE — NOT A SECRET"; custom channels can be registered at runtime via `BroadcastCrypto.setChannelKey(channelId, key)`. Channel id is bound as AAD so a message can't be replayed across channels. `RemoteChatController.sendMessage` encrypts the body and the chat widget decrypts via the mode-dispatched `MessageDecryptor` constructed in `bootstrapServices` (`lib/app/bootstrap.dart`); nothing on the wire is plaintext.
- **DIRECT** (wired end-to-end through `RemoteChatController.sendDirectMessage`): `DirectSession` (`lib/crypto/direct.dart`) — HKDF-chain fallback. Provides forward secrecy; **does not provide post-compromise secrecy**. The shared root is derived from X25519 ECDH + HKDF-SHA256 off a `ContactInvite` token (`lib/crypto/contact_invite.dart`) and the resulting `DirectSession` is persisted across restarts via `DirectSessionStore` (secure-storage-backed, `lib/crypto/direct_session_store.dart`). The broadcast/direct mode dispatch happens in `bootstrapServices`'s `_decryptMessage` helper.
- **Double Ratchet**: `DoubleRatchetSession` (`lib/crypto/double_ratchet.dart`) — a from-scratch pure-Dart implementation, library-only and unit-tested. It is **not on the active path** today; `DirectSession` is sufficient for the single-bundle-per-pair model we wire here. Adopting `DoubleRatchetSession` (skipped-key map + DH ratchet step) is a follow-up ticket that swaps the call site in `RemoteChatController` without changing the wiring seam.
- **Contact pairing**: `ContactInviteCodec` (`lib/crypto/contact_invite.dart`) — encodes a peer's `deviceId` (16-hex), `x25519PublicKey`, `displayName`, and a 16-byte `salt` into a `relaylink-invite-v1:<base64url>` token. The HKDF `info` string is the fixed domain-separation literal `relaylink-direct-v1` so both sides of the handshake always agree on the derived root. The Contacts screen exposes a "Pair via invite" paste-invite flow; the QR-scanner variant is deferred.
- **Identity**: `DeviceIdentity` (`lib/crypto/identity.dart`) — Ed25519 signing key + X25519 ECDH key, persisted via `flutter_secure_storage`. `senderId` is derived from the Ed25519 public key.

If you need a real Signal-grade ratchet today, do not ship RelayLink for that use case.

## Cut / deferred (with ticket refs)

The following items are intentionally **not** in this build. Each is verifiable in the code:

- **Real Bluetooth mesh radio.** `lib/mesh/discovery.dart` defaults to `StubMeshDiscoveryPlatform`; no BLE radio is actually turned on in the shipped app. The transport-layer envelope (`MeshTransport`, `MeshDiscovery`, `MeshRelay`, peer-sync) is fully implemented, unit-tested, and **registered with `TransportManager` at boot** — only the platform-channel call to a real BLE library is missing. *(Tickets: #07, #08 partial — the wiring is done, the platform is not.)*
- **iOS Multipeer Connectivity.** Stub only; no native side is shipped. *(#07)*
- **Wi-Fi Direct.** Stub only; no native side is shipped. *(#07)*
- **Real Internet transport backing.** `InternetTransport` registers with `TransportManager` but is wired against `_UnavailableFirestoreGateway` (`lib/app/bootstrap.dart`), which throws `FirestoreGatewayUnavailable` on every push/pull. Replace it with a real `FirestoreGateway` once the next bullet is unblocked. *(#20)*
- **Verified-org production fetcher.** `assets/verified_orgs.json` ships three `"demo": true` entries (`demo_red_crescent`, `demo_community_net`, `demo_climate_watch`); the loader refuses non-demo entries. *(#36)*
- **Vault media.** Photos, video, audio are deferred; the Vault UI is text-only. *(#32 partial)*
- **iOS SMS.** `lib/sms/platform_channel.dart` throws on iOS; SMS is Android-only.
- **Real Firestore credentials in-repo.** `firestore.rules` is committed and ready, but no production Firebase project is bundled; first launch with no Firebase config runs in local-only mode (`lib/backend/firebase.dart` → `FirestoreGatewayUnavailable`).
- **QR-scanner UI for contact invites.** The `ContactInvite` codec + paste-invite pair flow ship today; the camera-scanner variant (Ticket #16 follow-up) is deferred. `mobile_scanner` is a one-package add when this lands.

## How to run

```bash
# 1. Install dependencies
flutter pub get

# 2. Run unit + widget + integration tests (no device required)
flutter test

# 3. Run the demo app — single-device full-pipeline demo
flutter run --dart-define=DEV_LOOPBACK=true
# With DEV_LOOPBACK=true, bootstrapServices() registers an EchoTransport
# last, so a single device exercises the full send → fan-out → incoming
# → decrypt → render path end-to-end (BROADCAST + DIRECT). Real radio
# backings are still stubs (see "Cut / deferred" below); without this
# flag the chat only round-trips within an in-memory controller.

# 4. (Optional) Run against a real radio / Firebase
flutter run    # uses real stubs unless you wire a real platform binding
```

What works on which target:

| Target | Mesh | SMS | Internet | Gateway | DEV_LOOPBACK demo |
|---|---|---|---|---|---|
| Android emulator/device | stub discovery | yes (with permissions) | yes if Firebase configured | yes if Firebase configured | yes |
| iOS simulator/device | stub discovery | throws on iOS | yes if Firebase configured | yes if Firebase configured | yes |
| Test fixtures | simulated via `MeshTransport.setSimulatedPeerConnected` / `_FakeMeshPlatform` | simulated via `SmsTransport.simulateIncoming` | simulated via `FakeFirestoreGateway` | simulated via `GatewayRelay` tests | `EchoTransport` loopback |

Permission rationale (Android): `BLUETOOTH`, `BLUETOOTH_ADMIN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `ACCESS_FINE_LOCATION`, `NEARBY_WIFI_DEVICES`, `SEND_SMS`, `RECEIVE_SMS`, `READ_SMS`, `INTERNET`, `ACCESS_NETWORK_STATE`. The capability-disclosure screen (`lib/screens/capability_disclosure.dart`) shows the iOS-specific rationale verbatim and gates first launch.

## Test status

- **739 tests pass**, 6 skipped (all 6 are the SCALE_N-gated scale-harness scenarios; they print "Set --dart-define=SCALE_N=<n> to run scale harness" and are intentionally skipped on the regular CI run). 8 pre-existing widget-test failures hit `FragmentProgram._fromAsset` on the headless sandbox's `shaders/ink_sparkle.frag` — environmental, not regressions (confirmed via `git stash` against the previous commit).
- `flutter analyze` reports 0 errors, 0 warnings, 82 info-level (almost all `avoid_print` in `tools/demo_forward_secrecy.dart`).
- Per-layer test counts (active tests only, scale harness excluded): app 2, crypto 51, mesh 116, sms 84, transport 39, gateway 39, vault 34, screen 132, alerts 23, channels 54, capability 50, storage 29, contacts 8, models 20, allowlist 7, integration 7, demo 3, misc 3. Total file count: 53.
- The integration test in `test/integration/wired_chat_test.dart` exercises the full wiring-gap-closure flow (BROADCAST round-trip, persistence-across-restart, DIRECT crypto round-trip, contact lookup, transport registry).

## Open follow-up tickets

- **#47 — Wire Double Ratchet into DIRECT transports.** Replace the HKDF-chain `DirectSession` call sites in `RemoteChatController.sendDirectMessage` with `DoubleRatchetSession`. Forward-secrecy status stays; post-compromise secrecy becomes real. Pure library swap — no wiring change.
- **#48 — Relay-strategy harness.** Build the evaluation harness so future changes to `lib/features/gateway/relay.dart` (push-up cadence, pull-down filters, safety boundaries) can be compared against a fixed baseline.
- **#36 (follow-on) — Production verified-org fetcher.** Replace the demo-only allowlist loader with a signed, refreshable source so non-demo orgs can be added without code changes.
- **Real radio / platform backings** (BLE mesh, iOS Multipeer, Wi-Fi Direct, SMS for non-Android). The `TransportManager` registration path is done; this is the platform-channel layer underneath each transport.
- **Real Firestore project.** Replace `_UnavailableFirestoreGateway` in `lib/app/bootstrap.dart` with a real `FirestoreGateway` once a Firebase project is provisioned. Unlocks `InternetTransport` and gateway mode.
- **QR-scanner UI for `ContactInvite` pairing.** The codec + paste-pair flow ship today; the camera-scanner variant is a `mobile_scanner` integration.

## Data transparency

Four categories of data touch this app:

1. **Pseudonymous device id.** Generated locally from your Ed25519 key (`DeviceIdentity.senderId`, derived from the Ed25519 public key). Stored in `flutter_secure_storage`. Sent as the `sender_id` field on every outgoing message.
2. **Optional coarse location.** Only requested when the user opts into Bluetooth/Wi-Fi Direct discovery (Android `ACCESS_FINE_LOCATION` / `NEARBY_WIFI_DEVICES`). Not transmitted by RelayLink itself; the OS uses it to discover nearby radios.
3. **Phone numbers.** Used only for SMS transports. Stored locally for the contacts you've chosen; sent as part of an SMS only when you actually send a message to that number. Not exfiltrated to any other service.
4. **Evidence Vault text.** Stored locally, encrypted at rest with AES-256-GCM via the three-layer key ladder in `lib/vault/store.dart`. Never leaves the device unless you explicitly choose to send a vault item through a transport.

No analytics, no crash reporting, no third-party SDKs beyond `cloud_firestore`, `firebase_storage`, `firebase_core`, and `mobile_scanner` (the scanner only runs when you tap "Scan QR" on the channel-invite screen).

## License

MIT. See [`LICENSE`](LICENSE); every source file carries an SPDX-License-Identifier header.
