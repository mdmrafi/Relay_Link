# RelayLink — Product Spec

*Generated 2026-07-30 via /to-spec workflow. Source: STRESS-TEST.md rev. 3 + .working-memory.md (decisions D1-D8).*

---

## Problem Statement

A person cut off from the internet and cell signal in a crisis — natural disaster, conflict zone, network shutdown — currently has no way to:
- Tell anyone they're alive and where they are
- Send for help
- Receive authoritative safety information (alerts from verified aid organizations)
- Capture evidence of what's happening in a way that survives device seizure
- Reach a pre-arranged contact outside the affected area (family, journalist, lawyer, aid worker)

Existing messaging apps fail because they all require either internet connectivity or cell signal. SMS partially works but is plaintext at the carrier and interop edges, and isn't end-to-end encrypted. Bluetooth-only tools (AirDrop, Nearby Share) exist but aren't designed for disaster scenarios, lack encryption, and don't propagate through multi-hop chains.

**The user is in a crisis with degraded or no network. They need a tool that:
1. Always works without internet or cell signal (Bluetooth mesh)
2. Optionally uses whatever connectivity does exist (SMS, internet) when available
3. Encrypts everything end-to-end when sending to specific recipients
4. Lets them capture evidence that survives even if their phone is taken
5. Is honest about what it can and can't do, on every device class**

---

## Solution

RelayLink is a Flutter app for Android (full-featured) and iOS (mesh + relevant subset) with optional SMS and internet fallbacks. The mesh layer is the non-negotiable baseline; SMS and internet are additive channels that activate when available.

**The technical pillars:**

| Pillar | What it does | Why it matters |
|---|---|---|
| **Mesh** | Bluetooth-based store-and-forward messaging, multi-hop via nearby phones | Works with zero infrastructure; phone becomes a relay for others' messages |
| **Encryption** | AES-256-GCM for broadcast messages (group-shared key); full Double Ratchet for direct 1:1 messages (forward + post-compromise secrecy) | Privacy and authenticity; messages can be relayed by untrusted nodes without revealing content |
| **Connectivity fallback** | Every message goes out over every channel the device has — mesh, SMS to known contacts, internet — at once. SMS and internet legs only fire if those radios are on. | Reach people via whatever path exists; the user shouldn't have to choose |
| **Custom channels** | Anyone can create a private channel with a unique key shared via QR | A protest group, a neighborhood watch, a response team — all can have a private comms lane that outsiders relay without reading |
| **Text-only Evidence Vault** | Encrypted local capture of text reports, automatically delivered when any channel becomes available | Evidence that survives device seizure; reaches a pre-arranged recipient when network returns |
| **ALERT verification** | Manually curated allowlist of trusted aid organizations; verified badges appear on alerts signed by their keys | Distinguish official warnings from spoofed ones in a chaotic information environment |
| **Capability disclosure** | On first launch, the app tells the user what THIS device can and can't do, in plain language, with reasons | Honest about platform limits; users don't discover "iOS can't send SMS" by tapping a missing button |
| **Gateway mode** | Optional opt-in toggle: relay other nearby users' messages through your internet | Extends reach to peers who lack connectivity, with explicit informed consent about the safety tradeoffs |

**Out of MVP (deferred, with reasons in STRESS-TEST.md):** photo/video/audio evidence capture, full iOS feature parity with Android, multi-hop scale testing, third-party SMS gateway integration, store compliance, localization, accounts/usernames.

---

## User Stories

### Core scenarios

1. As a person trapped after an earthquake, I want to send an SOS via Bluetooth mesh to anyone in range, so that I can call for help without needing cell signal.
2. As a family member separated from loved ones during a network shutdown, I want to send a "I'm safe" status update that propagates through whatever phones are nearby, so that my family eventually sees it.
3. As someone at a protest, I want to alert others in my group that I've been detained, so that my group knows my status without internet.
4. As an aid worker with a satellite uplink, I want my official alert to display a verified badge on every recipient's phone, so that it isn't confused with spoofed warnings.

### Connectivity

5. As someone in a partial-coverage area, I want my message to go out via mesh AND SMS AND internet simultaneously if those channels are available, so that I don't have to choose which path to try.
6. As a person with cell signal but no internet, I want my SOS to fan out via SMS to my saved contacts, so that my family is reached even when the internet is down.
7. As a person whose internet is intermittent, I want my text evidence to be held encrypted on my phone and automatically delivered when any channel comes back, so that evidence isn't lost when I'm briefly disconnected.

### Encryption and privacy

8. As a journalist receiving evidence in a hostile environment, I want to read messages from a contact only I can decrypt, so that nobody monitoring the network can read what we discuss.
9. As a person whose phone might be seized at a checkpoint, I want all my local data — messages and evidence — to be encrypted at rest, so that the contents aren't readable if the device is taken.
10. As a privacy-conscious user, I want to create a private channel with a key I share via QR with specific people only, so that my group conversation isn't readable by everyone holding the default public key.
11. As a user in a high-risk environment, I want to choose whether to act as a gateway for other people's traffic, with a clear warning about the safety implications, so that I can decide case-by-case whether to be identifiable as a relay point.

### Trust and verification

12. As a recipient of an alert during a crisis, I want to know whether the alert was signed by a verified aid organization or by an unknown device, so that I can weight official warnings more heavily.
13. As a user, I want to see, on first launch, exactly what THIS device can and can't do (Bluetooth mesh ✓, SMS ✗ on iPhone, etc.) and why, so that I'm not surprised by missing features.

### Vault

14. As a witness to an incident, I want to type a written record of what I saw and have it encrypted on my phone immediately, so that I have evidence even if my phone is taken.
15. As a user, I want to take any chat message and one-tap save it as evidence (without copy-paste through the clipboard), so that I can preserve important exchanges without manually transcribing.

### Mesh behavior

16. As a user in a mesh, I want my phone to hold onto messages destined for others it hasn't seen yet, and forward them later when those people are in range, so that the mesh works even when people are mobile.
17. As a user who has been offline, I want my phone to receive all messages I missed while I was disconnected when I reconnect to the mesh, so that I catch up on what happened during the gap.

### Honest limitations

18. As a judge evaluating the submission, I want to see a clear README disclosure of what the demo does and doesn't prove, so that I can evaluate the project on its actual capabilities, not its aspirational ones.

---

## Implementation Decisions

> *Specific file paths and code snippets are deferred to tickets. Decisions listed here are architectural, not file-level.*

### Project structure
- **Framework:** Flutter, with primary target Android (iOS secondary)
- **Language:** Dart (with Rust via FFI only if needed for crypto — package-first per D4/D5)
- **State management:** Riverpod (standard Flutter choice; no specific reason to choose another)
- **Local storage:** sqflite (relational) + flutter_secure_storage (for keys and other secrets)
- **Networking abstraction:** all transport layers (mesh, SMS, internet) implement a common `Transport` interface, so adding a new channel is additive, not disruptive

### Crypto
- **Primitives:** `cryptography` Dart package — X25519, Ed25519, AES-256-GCM, HKDF
- **Device identity:** Ed25519 signing keypair + X25519 key-agreement keypair, generated at first launch, stored in Keystore/Keychain via flutter_secure_storage
- **BROADCAST crypto (default public channel):** AES-256-GCM with a symmetric key shipped in the app. Caveat disclosed: this deters casual eavesdropping, not a resourced adversary who reads the repo. See spec §0.
- **BROADCAST crypto (custom channel):** AES-256-GCM with a per-channel symmetric key generated locally and shared via QR. Key never committed to source.
- **DIRECT crypto:** Double Ratchet, per spec §6.3 — symmetric-key ratchet (HKDF chain per message) + DH ratchet (fresh X25519 per round-trip) + skipped-key storage capped at 1000. Per D3/D4/D5: implementation wraps an existing Dart Signal Protocol package; fallback to HKDF-chain-only if package is unusable (re-evaluation at hour 6).
- **Initial DIRECT key agreement:** synchronous X25519 ECDH between long-term identity keys at QR-exchange or mesh-handshake time. No X3DH, since both parties are physically present at exchange time per §6.3.
- **Signature:** Ed25519 over ciphertext + metadata, included in every message's `signature` field for sender authenticity.

### Message protocol
- **Schema:** per spec §5 — Message with id/mode/type/channel_id/sender_id/sender_display_name/origin/recipient_id/payload/ratchet_header/location/created_at/ttl/hop_count/signature/in_response_to
- **Routing metadata in plaintext** (id, mode, type, channel_id, ttl, hop_count, origin, recipient_id, created_at, signature) so relays can route without decrypting
- **ratchet_header is also plaintext** (per spec §5) — needed by recipient to derive message key, reveals only ratchet position, not content
- **TTLs:** SOS 12, ALERT 10, others 8

### Mesh layer
- **Discovery:** Nearby Connections `P2P_CLUSTER` for Android, Multipeer Connectivity for iOS
- **Seen-cache:** last 2,000 message IDs or rolling 24-hour window (per spec §7), persisted locally
- **Peer-sync on connect:** Bloom filter exchange of recent message IDs (per D7), then push symmetric-difference messages
- **Known trade-off documented:** Bloom filter false positives cause occasional missed relays — accepted per STRESS-TEST §3.4
- **Priority eviction when storage near cap:** SOS > STATUS_HELP > ALERT > ACK > STATUS_SAFE > CHAT, oldest-first within tier
- **No delivery-order guarantee** — UI sorts by `created_at`

### Connectivity fallback
- **All messages, all modes, stack:** every outgoing message goes out over every channel currently available. Mesh always. SMS to known contacts if cell signal. Internet push if online.
- **Tier 1 (everything):** mesh + SMS fan-out + internet push
- **Tier 2 (cell, no internet):** mesh + SMS fan-out
- **Tier 3 (mesh only):** mesh alone, the non-negotiable floor

### SMS stack (Android only)
- **Library:** platform `SmsManager` accessed via Flutter platform channel (not a third-party SMS plugin, to keep control of fragmentation)
- **Fragmentation:** ciphertext base64-encoded, chunked to ~140 usable characters per segment, header `RL:<8-char-msgid>:<idx>/<total>:`, sent via SmsManager
- **Reassembly:** app-managed, buffers fragments by message-id prefix, tracks received/total, discards incomplete after 10 minutes
- **Transport role:** messages arriving via SMS are re-injected into the normal pipeline (added to seen-cache, TTL decremented, re-broadcast onward) — `origin = SMS_TRANSPORT` is just another entry point

### Internet layer
- **Backend:** Firebase Firestore + Firebase Storage, no authentication system (device pseudonymous identity via keypairs)
- **BROADCAST messages:** pushed to relay collection keyed by `channel_id`; pulled by other gateways or direct-connected devices
- **DIRECT messages:** pushed tagged by `recipient_id`; picked up by the recipient's gateway or the recipient's own device
- **Ephemeral:** relay entries auto-expire after a few hours
- **Security rules:** rate limits and size limits in Firestore `.rules` file, alongside client-side enforcement

### Gateway mode
- **Toggle:** Settings → "Act as gateway for nearby devices." Off by default.
- **Safety note on enable:** "Acting as a Gateway relays encrypted mesh traffic through your internet connection on behalf of nearby devices. In a monitored or hostile network environment, this can make your device identifiable as a bridge point."
- **Code path:** pulls other devices' messages from local mesh, pushes to Firestore relay; pulls from Firestore, injects into local mesh. Continues while toggle is on.

### Evidence Vault
- **Capture surface:** separate "Evidence" tab in the app, distinct from Chat
- **At-rest encryption:** AES-256-GCM, per-record symmetric key, sealed under a vault-wrapping key, sealed under device identity key (per D6 implication in working memory)
- **Send-on-connect:** when any transport becomes available, queued evidence records transmit to chosen recipient
- **Send-from-chat affordance:** long-press any chat message → context menu → "Save as evidence" → copies message body to vault encrypted, with provenance linking back to original chat message id
- **Scope (for this MVP):** text-only. Photo/video/audio deferred per D6 to ROADMAP.

### Channel keys
- **Default public channel key** ships in source (caveat documented)
- **Custom channels:** local random key generation, QR code display for sharing, channel_id tagging on messages, multi-channel membership supported on a single device
- **Non-joined devices** still relay custom-channel messages (routing metadata is plaintext) but cannot decrypt or display them

### ALERT verification
- **Allowlist:** small `verified_orgs` collection in Firestore, manually curated for the demo (2-3 hardcoded entries like "Demo Red Crescent Branch")
- **Sync:** opportunistic via gateway/internet, cached locally for offline checks
- **Verification on receive:** ALERT signature checked against locally-cached allowlist. Match → badge. No match → standard "signed by [device]" label.
- **No self-assertion:** the Message schema has no field claiming verification — that would be spoofable. Verification is receiver-side only.
- **Honest disclosure in README:** this is a demo allowlist, not a production trust authority.

### Capability disclosure (§3.1)
- **On first launch:** a single screen listing this device's capabilities based on detected platform, with plain reasons for unavailable features
- **iOS-specific text:** "SMS features unavailable — Apple doesn't allow apps to send or read SMS automatically." Plus all other relevant cells.
- **Also in Settings/About:** same content available at any time
- **For feature phones (no app):** their capabilities are documented in the SMS bridge's auto-reply text and the README, not in any UI

### Honest demo disclosure
- **README section:** "What this demo does and doesn't prove" — explicit list of cut/fallback items, per STRESS-TEST §2.

### Testing
- **What makes a good test:** only external behavior, not implementation details
- **Modules with tests:** message serialization (round-trip), BROADCAST crypto encrypt+decrypt, custom channel key QR encode/decode, SMS fragment/reassemble round-trip, Evidence Vault encrypt-at-rest + decrypt-on-recipient
- **Manual integration testing required:** two physical Android devices for mesh demo, two physical devices + a SIM-disabled phone for SMS tier demo. No emulator for the in-person demo.

---

## Testing Decisions

**What makes a good test for this project:**
- Tests external behavior, not implementation
- A test that passes should be a meaningful check that the user-visible feature works
- Property-based tests for crypto (encrypt then decrypt yields original; flip a bit, decrypt fails or no-op) — more valuable than snapshot tests for crypto code
- The "ratchet works" test is integration-level, not unit: send a message, deliberately compromise a key mid-sequence, confirm prior messages still decrypt and future ones don't

**Modules to test:**
- `lib/crypto/broadcast.dart` — round-trip encrypt/decrypt, tampering detection (AEAD tag verification)
- `lib/crypto/identity.dart` — keypair generation, signing, verification
- `lib/crypto/direct.dart` — initial-key-agreement, message encrypt, message decrypt, key-compromise-mid-conversation
- `lib/mesh/protocol.dart` — message serialization round-trip, seen-cache dedup, TTL decrement on relay
- `lib/mesh/bloom_sync.dart` — Bloom filter encoding/decoding, false-positive rate within bounds
- `lib/sms/framing.dart` — fragment/reassemble round-trip, partial-with-timeout-discard
- `lib/vault/store.dart` — encrypt-at-rest, decrypt-on-retrieve
- `lib/channels/keys.dart` — QR encode/decode round-trip

**Integration / demo-derivable tests:**
- Two-device mesh send/receive — manual only, no emulator
- Two-device DIRECT round-trip with key compromise — manual demo, recorded as video for the judges

**What's NOT in scope for tests:**
- Network performance under load (excluded per §15)
- Visual regression (no UI snapshot tests for the demo)
- Cross-platform iOS tests (iOS gets the mesh subset; full test parity deferred)

---

## Out of Scope

(See STRESS-TEST.md §4 for cut list and STRESS-TEST.md §3 for landmine explanations.)

- Photo / video / audio evidence capture — **D6 deferred to ROADMAP, vault is text-only for the MVP**
- Full iOS feature parity with Android — iOS gets mesh + relevant subset (§3, §16). SMS bridge/transparent unavailable on iOS per platform restrictions, plus the gateway mode where it doesn't depend on SMS.
- Load testing at scale (50+ devices) — §15, physical constraint
- Localization (non-English UI) — §15
- Account / username system — §15, deliberate design boundary (pseudonymous keypairs remain identity)
- Third-party paid SMS gateway (Twilio-style) — §15, deliberate design boundary (SMS via device's own SIM only)
- Play Store / App Store submission compliance — §15, separate workflow
- Production trust authority for ALERT verification — §12 itself says this is a demo allowlist
- Post-compromise security beyond forward secrecy — *contingent on D5 verdict at hour 6: if the Dart ratchet package is unusable, we ship HKDF-chain-only, which gives forward secrecy but not post-compromise*
- DTN Bloom filter at full 2000-window beyond demo scope — *contingent on hour-14 integration; bounded last-200-IDs is the fallback if integration slips*
- ACID-perfect Gateway relay code at scale — §15, demoes with own traffic and 2-3 peers
- A real vetting pipeline for ALERT allowlist orgs — manually curated for demo, README is honest about this

---

## Further Notes

### Open decision gates during execution
- **Hour 6:** D5 verdict — is the Double Ratchet Dart package usable? If yes, integrate; if no, fall back to HKDF-chain and disclose in README.
- **Hour 14:** D7 integration status — is the full Bloom filter peer-sync stable? If slipping, fall back to bounded last-200-IDs.
- **Hour 18:** D8 status — is the Gateway relay code stable? If slipping, ship toggle UI + safety warning with stubbed code path.

### Why "vertical slice" is being deliberately narrowed
Standard vertical slicing (schema → API → UI → tests in one ticket) produces tickets too large for the ~150k-token context window budget multiple parallel agents need. This spec's tickets are *narrower than standard vertical slices* by design: each ticket ships one complete behavior through the smallest possible subset of layers, with prefactoring tickets expanding shared interfaces before the slices that traverse them land. **An agent working a ticket should be able to start, finish, and demo its slice with a fresh context window.**

### Repo state as of 2026-07-30
- Empty except placeholder README and first commit
- No Flutter scaffold yet
- This spec is the source of truth for the build
- `STRESS-TEST.md` holds the cut list, landmine map, and decision log
- `.working-memory.md` holds the conversational decision history (D1-D8)
- Spec, stress-test, and tickets are being published now to make parallel-agent work possible

### Acknowledgment of contested design choices
This spec preserves and ships the spec's choices on Double Ratchet, full Bloom filter, full Gateway, and full-text Vault — even though alternative simpler versions were viable and would be safer in 25 hours. The user explicitly chose spec fidelity over demo safety on all four (D3, D6, D7, D8). This is documented for judge transparency: the project values the spec's stated properties, and accepts the cost of higher implementation risk in exchange for shipping them.

### Submission
- Deadline: 30 July 2026 23:59 BST
- Repo: github.com/Azm1ne/July-2026-hackathon
- Submission package (per §17): public repo, OSI license, incremental commits, AI-tool disclosure, bilingual-capable README (English + single other language — choice deferred), full submission form, judging weights acknowledged
