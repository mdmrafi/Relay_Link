# 48 — Refactor mesh_scale_test.dart to honor RelayStrategy contract (#H3)

**What to build:** Bring `test/scale/mesh_scale_test.dart` into alignment with
spec `docs/superpowers/specs/2026-07-30-scale-harness-design.md` §2 (Key
abstraction — `RelayStrategy`). Concretely:

* Extract the in-process relay logic currently inline in `_Peer._onIncoming`
  (seen-cache dedup, TTL decrement, hop-count increment, re-broadcast) into
  a `RelayStrategy` abstract class with `originate()`, `onIncoming()`, and
  `close()` methods.
* Implement `MirrorRelayStrategy` against the in-process
  `LoopbackMeshDiscovery`. When the real mesh transport lands, a
  `MeshRelayStrategy` can implement the same interface without touching
  scenarios or metrics code.
* Wire `peerErrorCount` to a real per-peer try/catch around `onIncoming`.
  Today it is hardcoded to `0` at line ~1054 with a comment "Hook point
  reserved" — counts nothing real.
* Extend `MeshScaleHarness` to accept a `RelayStrategy` (defaulting to
  `MirrorRelayStrategy`).

**Why:** The spec is the source of truth; the harness drifted. Without the
abstraction, plugging a real mesh transport into the harness requires
rewriting the scenarios. Without the try/catch, `peerErrorCount` is a lie
that would mask real regressions when the relay layer becomes non-trivial.

**Blocked by:** None — the spec is approved and the in-process abstractions
are stable.

**Status:** pending

**Acceptance criteria:**
- [ ] `RelayStrategy` abstract class with `originate()`, `onIncoming()`,
      `close()` per spec §2.
- [ ] `MirrorRelayStrategy` implements the interface and reproduces the
      current `_Peer._onIncoming` behavior (seen-cache dedup, TTL
      decrement, hop-count increment, re-broadcast).
- [ ] `_Peer` delegates to the strategy; no inline relay logic remains.
- [ ] `MeshScaleHarness` accepts a `RelayStrategy` parameter (default
      `MirrorRelayStrategy`).
- [ ] `peerErrorCount` is sourced from a per-peer try/catch around
      `onIncoming` — when one peer throws, the run continues and the count
      is non-zero.
- [ ] Unit tests for `RelayStrategy` behavior: dedup drops, TTL drop,
      relay on accept, hop-count increment, peer-error isolation.
- [ ] `flutter test` (smoke default) still green; harness integration
      still passes (`SCALE_N=12`).
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings` clean.
- [ ] CSV/Markdown output rows are unchanged (no schema drift visible to
      downstream consumers).

**Spec deviation source:** Section 57 of the design spec, line 161 (per-peer
try/catch), and §1 ("Metrics: … peer errors"). The integration log
`docs/scale-harness-integration-run-2026-07-30.md` reports `peerErrorCount=0`
on every scenario — under the new try/catch, the same scenarios should still
report 0, but the metric will now MEASURE something real.

**TDD note:** Per project policy, write the failing tests first, watch them
fail for the right reason, then implement. Suggested order:
1. Unit tests for `MirrorRelayStrategy` against fresh peers (the smallest
   seam — pure logic, no harness).
2. Unit test for the per-peer try/catch (force a strategy to throw on one
   peer, assert `peerErrorCount > 0` and the other peers still relay).
3. Refactor `_Peer` to delegate.
4. Smoke run + integration run.
