# 14 — Forward-secrecy demo (key compromise mid-conversation)

**What to build:** A runnable demonstration script (`tools/demo_forward_secrecy.dart` or a Flutter dev screen) that exercises #13's DIRECT crypto by: establishing a session, encrypting N messages, deliberately "compromising" the session key at message K (where K < N), and showing that messages 1..K-1 still decrypt but messages K+1..N either fail to decrypt or decrypt to garbage.

**Blocked by:** #13

**Status:** ready-for-agent

- [ ] Script or dev screen runs end-to-end in < 10 seconds
- [ ] Compromised message K is named in the output
- [ ] Pre-K messages decrypt cleanly
- [ ] Post-K messages either fail or produce wrong plaintext
- [ ] Output is suitable for recording a 30-second demo clip for the README