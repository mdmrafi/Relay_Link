# 10 — Bloom filter encoding + size math

**What to build:** `lib/mesh/bloom.dart` implementing a standard Bloom filter with: insert(id), mightContain(id) → bool, encode() → bytes, decode(bytes) → filter. Sized for 2000 expected entries with 1% false positive rate (≈ 20 kbit per filter per spec §7).

**Blocked by:** #01

**Status:** ready-for-agent

- [x] Filter sized for n=2000, p=0.01 (document the size math inline: m = -n*ln(p)/(ln(2)^2), k = (m/n)*ln(2))
- [x] Two independent hash functions (use a fast non-cryptographic hash like xxhash, since IDs are already random UUIDs — cryptographic strength not needed here)
- [x] Unit tests: insert 2000 random IDs, query 1000 unseen → false positive rate < 2% in repeated trials
- [x] `encode()` produces compact byte representation; `decode()` is the inverse
- [x] Two filters can be OR'd together (union) to compute symmetric difference queries efficiently