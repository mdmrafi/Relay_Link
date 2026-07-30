# RelayLink — Scale-testing harness

In-process, multi-device mesh simulation for verifying RelayLink's
mesh layer at scale before deploying to physical hardware.

## What it does

Spawns `N` device peers in a single Dart process. Each peer has its own
`EchoTransport` (the production `Transport` contract), its own
`BloomFilter` seen-cache, and a tiny relay layer that mirrors the
production mesh relay:

- listens on `transport.incoming`
- dedupes via the seen-cache
- decrements TTL
- re-broadcasts via the in-process `LoopbackMeshDiscovery`

The harness then drives three scenarios and emits per-run statistics.

## Scenarios

| Scenario  | What it stresses                                            |
| --------- | ------------------------------------------------------------ |
| broadcast | one peer broadcasts `M` messages; measure fan-out time     |
| direct    | pairwise `(sender, recipient)` bursts across random pairs |
| mixed     | alternating broadcast + direct, mixed 64 B / 512 B / 4 KB |

## Metrics emitted

| Metric                      | Description                                                   |
| --------------------------- | ------------------------------------------------------------- |
| `fanout_p50_ms` / `p95` / `p99` | end-to-end propagation latency (send → last peer received) |
| `fanout_mean_ms` / `max_ms` | mean and worst-case latency                                    |
| `seen_cache_hit_rate`       | fraction of `incoming` messages dropped by the seen-cache     |
| `duplicates_suppressed`     | raw count of seen-cache hits                                   |
| `rss_bytes_at_start` / `_end` | process resident set size (best-effort, via `ProcessInfo`)  |
| `bytes_per_peer`            | RSS delta / `N`                                                |
| `bloom_fpr`                 | empirical false-positive rate under load (fresh filter, 2k inserts / 1k queries) |
| `bloom_inserts`             | total bloom-filter inserts across the run                     |
| `ttl_drops`                 | messages dropped because TTL hit 0                             |
| `relayed_total`             | total messages forwarded onward across all peers              |
| `relayed_per_peer`          | `relayed_total / N`                                            |
| `relayed_per_peer_per_sec`  | CPU-proxy throughput                                           |
| `wall_clock_ms`             | total scenario duration                                        |

## How to run

### Default (CI)

The harness is **skipped** by default so the regular `flutter test` run
stays at 314 tests. Skipped tests are flagged `~N` in the runner output.

```bash
flutter test
```

### Scale runs

Pick `N` and (optionally) message-count / latency / jitter:

```bash
# 12-peer mesh — the "real" scale run, suitable for the user's
# physical hardware (phones + SIMs + adapters).
flutter test test/scale/mesh_scale_test.dart --dart-define=SCALE_N=12

# 20-peer mesh — heavier load.
flutter test test/scale/mesh_scale_test.dart --dart-define=SCALE_N=20

# Single scenario only.
flutter test test/scale/mesh_scale_test.dart \
  --dart-define=SCALE_N=12 \
  --dart-define=SCENARIO=broadcast

# Tune message count and per-hop latency.
flutter test test/scale/mesh_scale_test.dart \
  --dart-define=SCALE_N=12 \
  --dart-define=SCALE_MSGS=100 \
  --dart-define=DELAY_US=5000 \
  --dart-define=JITTER_US=1000
```

The harness also accepts `SCALE_N`, `SCALE_MSGS`, `SCENARIO`, `DELAY_US`,
`JITTER_US` from the environment, so `SCALE_N=12 flutter test …` works
without `--dart-define`.

### Defaults

| Parameter     | Default | Meaning                                                |
| ------------- | ------- | ------------------------------------------------------ |
| `SCALE_N`     | 4       | peer count (CI smoke); 12+ for real runs               |
| `SCALE_MSGS`  | 30      | messages per scenario                                  |
| `SCENARIO`    | all     | one of `all`, `broadcast`, `direct`, `mixed`           |
| `DELAY_US`    | 1000    | simulated per-hop delivery latency (1 ms)              |
| `JITTER_US`   | 0       | random jitter on top of delivery latency (deterministic) |

## Output

For each scenario, the harness writes a CSV + Markdown summary to:

- `test/scale/results/scale_<date>_<scenario>.csv` — one row per run,
  header written on first row, subsequent runs appended.
- `test/scale/results/scale_<date>_<scenario>.md` — pretty-printed
  summary table.

For example, after `--dart-define=SCALE_N=12` you get:

```
test/scale/results/
  scale_20260730_0425_broadcast.csv
  scale_20260730_0425_broadcast.md
  scale_20260730_0425_direct.csv
  scale_20260730_0425_direct.md
  scale_20260730_0425_mixed.csv
  scale_20260730_0425_mixed.md
```

## Where the metrics come from

- **Latency** — stamped at `transport.send`/`discovery.broadcast` time,
  collected per-message-id at the receiving subscription gate; we
  measure `lastReceived − sentAt` per message.
- **Seen-cache hit rate** — `duplicateDropCount / seenChecks` aggregated
  across every peer for the run.
- **Memory** — `ProcessInfo.currentRss` at start and end of the
  scenario; `bytes_per_peer = (rss_end − rss_start) / N`. **Best-effort**:
  on targets where `ProcessInfo` is unavailable (web), `$rss_*` reads
  as `-1` and `bytes_per_peer` is `-1`. The harness will still run and
  emit everything else.
- **CPU** — proxy: `relayed_per_peer_per_sec` =
  `(relayed_total / N) / wall_clock_seconds`. The user can substitute
  other measurements (e.g. via the `dart:developer` Service Protocol)
  on physical hardware.
- **Bloom FPR** — separate fresh filter, insert N random UUIDs, query
  Q unseen IDs, count positives. Mirrors the regression test in
  `test/mesh/bloom_test.dart` but at message-volume scale.
- **TTL effectiveness** — `ttl_drops` counter; if `ttl_drops > 0`
  the broadcast storm actually terminated at the expected hop count.
  If `ttl_drops == 0` AND the topology is fully connected, the
  chosen TTL is too generous — bump the run with smaller hop limit
  or watch for `fanout_p99_ms` to drift.

## Design notes

- The harness uses `EchoTransport` from `lib/transport/transport.dart`
  rather than the real mesh (which is on the Ticket #08 plan). The
  Transport contract is identical; only the "radio" is in-process.
- The discovery layer (`loopback_mesh_discovery.dart`) is a tiny
  in-memory registry. Fully-connected topology — every peer can
  reach every other peer. This is the **baseline**; partitioning /
  sparse topologies are future work.
- `BloomFilter` is the production filter (`lib/mesh/bloom.dart`),
  not a mock. The harness exercises the real bit math.
- The harness is **read-only** on `lib/mesh/*` — no production
  source files are modified.

## What the user enables on physical hardware

The local-only design means the harness doesn't simulate real Bluetooth
latency or real-world packet loss. When running on physical hardware
the user can:

1. Wire each peer to a real device (phone + SIM + adapter).
2. Replace `EchoTransport` with `MeshTransport` (or the eventual
   Ticket #08 transport) — the `Transport` contract is unchanged.
3. Run the same scenarios against the real mesh.

The metrics emitted by the harness are deliberately transport-agnostic
(latency, hit rate, FPR, TTL drops, throughput) so the same reports
make sense for both the in-process and the on-device runs.
