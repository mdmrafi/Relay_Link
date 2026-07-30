# Scale-harness integration run — 2026-07-30

This file records the scale-harness results captured during the
integration that merged `feat-scale-harness` (commits `1214ca5` and
`8a42ef9`) into `main` via `integration/submission-package`.

## Configuration

- Flutter 3.44.8, Dart 3.12.2
- Commit under test: `dc50245` + 4 integration commits on top
- Run command (canonical N=12):
  ```
  SCALE_WRITE_RESULTS=1 flutter test test/scale/mesh_scale_test.dart \
    --dart-define=SCALE_N=12 --dart-define=SCALE_MSGS=20
  ```

## Headline results — N=12, 20 messages, all four scenarios

| Scenario      | p95 fanout | FPR     | Lost | Errors | Wall  | Relayed |
|---------------|-----------:|--------:|-----:|-------:|------:|--------:|
| broadcast     | 6.665 ms   | 0.00 %  | 0    | 0      | 721ms | 220     |
| direct        | 8.214 ms   | 0.00 %  | 0    | 0      | 722ms | 220     |
| mixed         | 7.924 ms   | 0.00 %  | 0    | 0      | 621ms | 220     |
| saturation    | 6.032 ms   | 0.00 %  | 0    | 0      | 621ms | 220     |

All assertions pass: `messages_lost == 0`, `peer_error_count == 0`,
`bloom_fpr < 0.05`. Per the saturation scenario, `peer_relayed_min =
18`, `peer_relayed_max = 19`, `peer_relayed_stddev = 0` — relays are
evenly distributed across the 12 peers, as expected.

## Smoke run — N=4, 5 messages

`flutter test test/scale/mesh_scale_test.dart --dart-define=SCALE_N=4 --dart-define=SCALE_MSGS=5`
ran in 3.5 s wall-clock. All 6 tests pass.

## Mid-scale — N=8, 10 messages

`flutter test test/scale/mesh_scale_test.dart --dart-define=SCALE_N=8 --dart-define=SCALE_MSGS=10`
ran in 4 s wall-clock. All 6 tests pass.

## Heavy — N=20, 30 messages

`flutter test test/scale/mesh_scale_test.dart --dart-define=SCALE_N=20 --dart-define=SCALE_MSGS=30`
ran in 5 s wall-clock. All 6 tests pass. p95 = 11–22 ms depending on
scenario, relayed_total = 570.

## Spec alignment

The implementation honors the design spec at
[`docs/superpowers/specs/2026-07-30-scale-harness-design.md`](../../superpowers/specs/2026-07-30-scale-harness-design.md):

- Saturation scenario + extended metrics (per-peer relayed distribution,
  hop-count histogram, bytes/peer throughput) — present.
- `messages_lost`, `peer_error_count` metrics — present.
- Smoke default N=4, 5 messages; opt-in via `--dart-define=SCALE_N=<n>`
  — present.
- CSV + Markdown output gated on `SCALE_WRITE_RESULTS=1` — present.

Spec deviations noted by the code-review pass (recorded for a follow-up
ticket, not blocking): `RelayStrategy` interface is not split out as the
spec recommends; per-peer try/catch is reserved but not yet wired;
smoke is gated on `SCALE_N` rather than unconditional in CI.

## Notes

The four per-scenario result files at
`scale_20260730_0706_{broadcast,direct,mixed,saturation}.{csv,md}` are
checked into `test/scale/results/`.