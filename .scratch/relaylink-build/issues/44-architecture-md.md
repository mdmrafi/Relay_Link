# 44 — ARCHITECTURE.md

**What to build:** `ARCHITECTURE.md` documenting the system architecture: layered diagram (UI → TransportManager → Transports [Mesh/SMS/Internet/Gateway] → Storage/Crypto), data flow for a typical message (compose → encrypt → fan-out → mesh peer → store-and-forward → decrypt → display), crypto primitives inventory, security model (what the keys are, who has access), known limitations and deferred items.

**Blocked by:** All other tickets

**Status:** ready-for-agent

- [ ] ASCII or mermaid diagram of the layers
- [ ] Data flow walkthrough for BROADCAST and DIRECT
- [ ] Crypto primitives inventory with rationale (X25519, Ed25519, AES-256-GCM, HKDF — all via `cryptography` package)
- [ ] Security model: device identity keys (where stored, who has access), channel keys (per-channel), vault wrapping key chain
- [ ] "Known limitations" section listing deferred features (per STRESS-TEST §4) and the rationale
- [ ] Pointer to README for the demo script and hackathon compliance