# Scale Harness for RelayLink Mesh Layer — Design

**Date:** 2026-07-30
**Branch:** worktree-agent-aa3ec1a7
**Author:** puku-cli (brainstorming skill)
**Status:** Approved

---

## 1. Purpose & scope

Provide an in-process, multi-peer simulator that proves RelayLink's mesh-layer primitives (TTL decrement, bloom-filter seen-cache dedup, broadcast fan-out, direct addressing) scale to 10+ peers without breaking, before the user attempts it on physical hardware.

### In scope

- A peer pool that spawns N simulated devices in a single Dart process.
- Four scenarios: broadcast storm, pairwise DIRECT, mixed broadcast+direct, and stress-mode saturation (every peer broadcasting simultaneously).
- A relay strategy interface (`RelayStrategy`) so the same harness can drive an in-process mirror today and the eventual real mesh transport later without touching scenarios or metrics code.
- Metrics: fanout latency (P50/P95/P99/max/mean), seen-cache hit rate, RSS per peer, bloom-filter FPR under load, throughput (relayed/sec), TTL drops, messages lost, peer errors.
- Additional metrics: per-peer relayed count distribution (min/max/mean/median across N peers), hop-count distribution (histogram of hop counts observed), bytes-per-peer throughput (total bytes relayed / N), peer saturation variance (standard deviation of relayed counts across peers to detect skew).
- Output: console summary always, CSV + Markdown results written when `SCALE_WRITE_RESULTS=1` is set.
- A smoke default (N=4, 5 messages) so the harness runs on every CI invocation in well under 10s.

### Out of scope

- Real Bluetooth or Wi-Fi-Direct transport — the harness explicitly uses loopback.
- Network partitioning / sparse topologies — fully-connected baseline only.
- Latency calibration against physical hardware — `DELAY_US` is a configurable knob, not a measurement of real BLE.
- Replacing the harness with the real mesh transport — that's a follow-up when ticket #08 lands.

---

## 2. Architecture

```
test/scale/
├── README.md                                  (usage docs)
├── _config.dart                               (env / dart-define parsing)
├── loopback_mesh_discovery.dart               (peer registry)
├── relay_strategy.dart                        (interface)
├── mirror_relay_strategy.dart                 (in-process relay)
├── _peer.dart                                 (per-peer state)
├── _harness.dart                              (peer pool + bootstrap/teardown)
├── _metrics.dart                              (_LatencyStats, _ScenarioReport)
├── _output.dart                               (console + CSV + Markdown writers)
├── scenarios/
│   ├── broadcast_scenario.dart
│   ├── direct_scenario.dart
│   ├── mixed_scenario.dart
│   └── saturation_scenario.dart
├── mesh_scale_test.dart                       (test driver)
├── _metrics_test.dart                         (unit tests for stats math)
├── _config_test.dart                          (unit tests for env parsing)
└── loopback_mesh_discovery_test.dart          (unit tests for peer registry)
```

### Key abstraction — `RelayStrategy`

```dart
abstract class RelayStrategy {
  /// Called when a peer's `incoming` stream produces a message.
  /// Returns the relayed Message (TTL decremented, hopCount incremented),
  /// or null if the message was dropped (seen-cache hit or TTL=0).
  Message? onIncoming({
    required String peerId,
    required Message msg,
    required BloomFilter seenCache,
  });

  /// Called to send a freshly-originated message into the network.
  void originate({
    required String senderId,
    required Message msg,
  });

  /// Tear down timers and subscriptions.
  Future<void> close();
}
```

`MirrorRelayStrategy` implements this against the in-process `LoopbackMeshDiscovery`. When the real mesh transport lands, a `MeshRelayStrategy` can implement the same interface without touching the scenarios or metrics code.

### Peer pool

- `_Harness.bootstrap()` — spawns N peers; each gets `peerId`, `LoopbackTransport`, `BloomFilter.empty()`, a `_Peer` instance.
- Each peer's `transport.incoming` is subscribed to a relay function from the strategy.
- Strategy's `originate()` calls `discovery.broadcast()` which schedules delivery to all OTHER peers' transports with `deliveryLatency + jitter`.
- `_Harness.teardown()` — closes transports, drains timers, awaits all peer `dispose()`s.

### Why split `_Peer` from `_Harness`?

- `_Peer` is the per-device runtime state (counters, relay wiring) — testable in isolation.
- `_Harness` is the peer-pool lifecycle (bootstrap/teardown, scenario coordination) — orchestration only.

---

## 3. Data flow

```
┌──────────────────────────────────────────────────────────────────┐
│ Scenario (e.g. broadcast)                                        │
│                                                                  │
│  for i in 0..messageCount:                                       │
│    msg = peer.originateBroadcast(...)                            │
│    sentTimes[msg.id] = DateTime.now()                            │
│    strategy.originate(senderId=peer.id, msg=msg)                 │
│    await Future.delayed(10ms)                                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ RelayStrategy.originate()  ──►  LoopbackMeshDiscovery.broadcast() │
│                                                                  │
│  discovery.broadcast():                                          │
│    for each (peerId, sink) in peers where peerId != senderId:     │
│      Timer(DeliveryLatency + jitter).then(() => sink(msg))       │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ LoopbackTransport.send(msg)  ──►  transport.incoming stream       │
│                                                                  │
│  peer's relay subscription fires:                                │
│    receivedTimes[msg.id].add(DateTime.now())                     │
│    strategy.onIncoming(peerId, msg, bloom)                        │
│      ├─ if bloom.mightContain(msg.id):  drop (dup)                │
│      ├─ else: bloom.insert(msg.id)                               │
│      ├─ if msg.ttl <= 0:             drop (ttl exhausted)         │
│      └─ else: relay decremented msg back into discovery           │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ After scenario drain (Future.delayed(_drainDelay)):              │
│                                                                  │
│  _Harness._aggregate(sentTimes, receivedTimes, peer counters):    │
│    latency = lastReceived(id) − sentAt(id)         per msg       │
│    hit_rate = totalDuplicates / totalSeenChecks                   │
│    rss = ProcessInfo.currentRss  (best-effort)                   │
│    fpr = _measureBloomFpr(n=2000, q=1000)                        │
│                                                                  │
│  _output.writeConsole(report)        always                       │
│  if (SCALE_WRITE_RESULTS == '1'):                                │
│    _output.writeCsv(report)         test/scale/results/          │
│    _output.writeMarkdown(report)                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Key timing decisions

- **Per-message 10ms spacing** in scenarios prevents the in-process event loop from being saturated at low N — makes timing deterministic enough that percentile spreads are meaningful.
- **Drain delay = 500ms** after the last originate call to let in-flight timers land before subscriptions are cancelled. Scaled to `N * 50ms` for larger runs.
- **TTL = ⌈log₂(N)⌉ + 2** for fully-connected topology — bounds broadcast storm so it terminates at the expected hop count.

---

## 4. Error handling

### Harness-internal errors

- Per-peer try/catch around `peer.relay.onIncoming` — a single bad message from one peer must not cascade into tearing down the whole harness. Counted as `peerErrorCount` metric, surfaced if non-zero.
- `Future.delayed` for send pacing is wrapped in try/catch — if a teardown races with a pacing delay, the delay is silently dropped.
- `_aggregate()` runs after `await Future<void>.delayed(_drainDelay())`. If any message in `sentTimes` has no entry in `receivedTimes`, it's silently dropped from the latency list AND surfaced as `messages_lost` metric — never silent.
- `ProcessInfo.currentRss` is wrapped in try/catch — returns `null` on targets where it's unavailable (e.g., web). RSS metrics default to `-1` and `bytes_per_peer` defaults to `-1`. The harness never crashes on this.

### Scenario failures

- `_runScenario()` wraps each scenario in try/finally so `harness.teardown()` always runs, even if the scenario throws.
- Test driver asserts:
  - `report.messagesSent == messageCount`
  - `report.fanoutLatency.count > 0` (at least one message must reach a peer)
  - broadcast: `report.relayedTotal > messageCount` (storm must fan out)
  - `report.bloomFpr < 0.05`
  - `report.messagesLost == 0` (no message disappeared without explanation)
  - `report.peerErrorCount == 0`

### Configuration errors

- `_HarnessConfig.peerCount()` validates `>= 2` and falls back to default (4) on garbage input. Never throws.
- Unknown scenario name in `_HarnessConfig.scenario()` defaults to `'all'`.
- Invalid `DELAY_US` or `JITTER_US` fall back to 1000µs / 0µs respectively. Logged once at harness start.
- Negative or absurdly-large `SCALE_MSGS` (>10000) falls back to default with a warning.

### Output errors

- `test/scale/results/` is created lazily (`Directory.createSync(recursive: true)`).
- CSV/Markdown writes are best-effort: if the directory is unwritable (permission denied, disk full), the harness logs a warning to stderr and continues. Test result reporting (via `flutter_test`) is the source of truth.
- CSV writes use `O_APPEND` so concurrent test runs don't clobber each other; if file locking fails, we add a per-run UUID to the filename.

### Bloom FPR regression

- The bloom filter FPR probe is its own `test()` block — runs unconditionally as part of the always-on smoke. Asserts FPR < 0.03 with `lessThan(0.05)` message-budget tolerance.

### Race conditions

- Peer's `_Peer.start()` is idempotent — calling it twice doesn't create a duplicate subscription.
- `LoopbackTransport.close()` is idempotent — guarded by `if (!_controller.isClosed)`.
- `discovery.broadcast()` against a peer that's mid-disconnect is a no-op (the sink function checks `transport.isAvailable()`).
- Drain delay uses a generous `Duration(milliseconds: 500)` for smoke and `(N * 50ms)` for larger runs — sized to worst-case fanout.

### Test driver / framework errors

- If the harness takes longer than `Timeout(Duration(seconds: 60))`, the test fails with a clear "scenario X exceeded 60s" message rather than a confusing framework error.

### Memory safety

- `peer.dispose()` closes transport controllers; orphan Timers are cancelled via harness teardown. We use `Zone.current.handleUncaughtError` to surface any leaked timers as test failures.
- For runs `> N=50`, we add `if (N > 50) print('large-N warning: peak memory may exceed 1GB')` to avoid silent OOMs.

### Logging

- All `print()` statements use an `// ignore: avoid_print` comment and are clearly prefixed `scale harness:` for grep-ability in CI logs.

---

## 5. Testing strategy

### The harness IS a test

Each scenario is a `test()` block. By default it runs at smoke scale (N=4, 5 messages per scenario) on every CI invocation in <10s. When `SCALE_N` is set via `--dart-define=SCALE_N=<n>` (or `SCALE_N=<n>` in the environment), the harness scales up to that peer count. The harness's own assertions are the regression net at both scales.

### Smoke default (always-on)

- N=4, 5 messages per scenario, no `--dart-define` required
- Completes in <10s on any developer machine
- Asserts: messages sent == expected, latency count > 0, broadcast fanned out, bloom FPR < 0.05

### Scale runs (opt-in via `--dart-define=SCALE_N=12`)

- N=12 (or higher), 30 messages per scenario
- Completes in ~30s
- Asserts: same invariants + drain delay longer than `N * 50ms`

### Per-scenario tests

- `broadcast_smoke_test.dart` — broadcast storm
- `direct_smoke_test.dart` — pairwise DIRECT
- `mixed_smoke_test.dart` — mixed broadcast+direct, mixed sizes
- `saturation_smoke_test.dart` — every peer broadcasting simultaneously (worst case)
- `bloom_fpr_smoke_test.dart` — fresh-filter FPR probe (always-on)

### Unit tests for harness internals (separate, fast)

- `test/scale/_metrics_test.dart` — verify `_LatencyStats.percentile()` correctness with known input
- `test/scale/_config_test.dart` — verify env-var parsing edge cases
- `test/scale/loopback_mesh_discovery_test.dart` — verify peer register/unregister, broadcast fan-out, jitter distribution

These run independently and don't depend on the harness scenarios. They're cheap (<100ms total) and catch regressions in the harness itself.

### Why this split?

- Scenario tests prove the system works.
- Unit tests prove the harness isn't lying about its measurements.
- A bug in `_LatencyStats.percentile()` would otherwise silently corrupt every CSV row.

### Test gating summary

| Run mode | What executes | Wall time |
|---|---|---|
| `flutter test` (default) | Smoke harness + unit tests | ~10s |
| `flutter test --dart-define=SCALE_N=12` | Full harness + unit tests | ~30s |
| `flutter test --dart-define=SCALE_N=20` | Heavy scale + unit tests | ~60s |

---

## 6. Implementation plan

Implementation will be dispatched in parallel across subagents, one per file. Each subagent gets a self-contained module brief and produces one file. After all modules land, the test driver wires them together.

**File ownership map:**

| File | Subagent task |
|---|---|
| `test/scale/_config.dart` | A |
| `test/scale/loopback_mesh_discovery.dart` | B |
| `test/scale/relay_strategy.dart` | C |
| `test/scale/mirror_relay_strategy.dart` | D |
| `test/scale/_peer.dart` | E |
| `test/scale/_metrics.dart` | F |
| `test/scale/_output.dart` | G |
| `test/scale/_harness.dart` | H (depends on B, C, D, E, F) |
| `test/scale/scenarios/*.dart` (4 files) | I, J, K, L |
| `test/scale/mesh_scale_test.dart` | M (depends on all) |
| `test/scale/_config_test.dart`, `loopback_mesh_discovery_test.dart`, `_metrics_test.dart` | N, O, P |
| `test/scale/README.md` | Q |
| `.gitignore` updates | R |

**Wave structure:**
- Wave 1 (parallel): A, B, C, D, E, F, G, I, J, K, L, N, O, P, Q, R — all leaf modules.
- Wave 2 (parallel): H (`_harness.dart` after leaf modules land).
- Wave 3: M (`mesh_scale_test.dart` — final integration).

---

## 7. Open questions

None at design time. All decisions resolved during brainstorming.

---

## 8. References

- SPEC.md §15 — explicit "load testing at scale" exclusion (50+ devices, physical constraint).
- STRESS-TEST.md §4 — cut list confirms scale testing is deferred; this harness is a synthetic pre-physical step.
- cutrev-scale branch (commit `c0a5a72`) — pre-existing implementation referenced for shape only; this design re-implements from scratch per user direction.