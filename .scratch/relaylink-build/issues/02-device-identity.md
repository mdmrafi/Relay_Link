# 02 — Device identity (Ed25519 + X25519 keypairs)

**What to build:** `lib/crypto/identity.dart` exposing `DeviceIdentity` with: generate-on-first-launch, store in platform secure storage (Android Keystore via flutter_secure_storage), load-on-demand, sign/verify with Ed25519, ECDH with X25519. Also a `SenderId` derived from the Ed25519 public key (first 16 hex chars or similar — short, deterministic, pseudonymous).

**Blocked by:** #01

**Status:** ready-for-agent

- [ ] First launch detects "no identity" and generates a new Ed25519 + X25519 keypair
- [ ] Private keys stored via flutter_secure_storage (Keystore-backed on Android)
- [ ] Subsequent launches load existing identity, never regenerates
- [ ] `sign(bytes)` produces a signature, `verify(bytes, sig, pubkey)` returns bool
- [ ] `ecdh(theirPublicKey)` returns a 32-byte shared secret
- [ ] Unit tests: round-trip sign/verify, ecdh symmetry (A.ecdh(B) == B.ecdh(A))
- [ ] `SenderId` is derived deterministically from the Ed25519 public key