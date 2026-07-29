# Firestore + Storage rules test (Ticket #19)

This directory holds the rules unit-test suite referenced from
`firestore.rules.test.md`. The suite runs against the Firebase emulator
suite (`firebase-tools`) using `@firebase/rules-unit-testing`.

## Prerequisites

- Node.js (16+)
- `firebase-tools` installed globally (`npm install -g firebase-tools`)
- Java (the emulators run on JVM)

## Run

From the repo root:

```bash
# 1. Make sure you have the testing deps cached. One-time setup:
npm install --prefix test/rules @firebase/rules-unit-testing firebase

# 2. Start the emulators and run the suite in one shot:
firebase emulators:exec \
  --only firestore,storage \
  --project demo-relaylink-rules-test \
  "node test/rules/firestore_rules.test.js"
```

The suite cleans the Firestore state at startup (`env.clearFirestore()`)
so re-runs are idempotent.

## What's covered

- 22 Firestore cases (broadcast relay, direct relay, verified_orgs,
  evidence, rate-limit counter, catch-all)
- 4 Storage cases (evidence blob reads, content-type cap, deny-all
  on other paths)

Total: 27 cases. As of the initial commit (Ticket #19), all 27 pass
on a fresh emulator.

## What isn't covered

- Token-bucket rate-limit semantics under heavy contention — the
  counter scheme is documented as best-effort.
- Field-level type assertions beyond what the test fixtures exercise.
  The full field schemas are validated by the rules themselves, not by
  this test suite.
- Storage rules beyond `application/octet-stream` content-type cap.
