// Behaviour-driven validation for firestore.rules + storage.rules
// (Ticket #19, hardening pass). Runs against the Firebase emulator.
//
// Spawned by the same emulator process; started before this test runs,
// the emulators listen on localhost:8080 (Firestore) and 9199 (Storage).
// The default port targets can be overridden with the
// `FIREBASE_EMULATOR_HUB_PORT`, `FIRESTORE_EMULATOR_PORT`, and
// `FIREBASE_STORAGE_EMULATOR_PORT` env vars so a custom emulator
// launched via a `firebase.emu.json` override can be used (see
// test/rules/README.md).
//
// The matrix here mirrors the one in firestore.rules.test.md. Each
// (operation × caller) pair asserts allow or deny explicitly. The
// fuzz section at the bottom extends the matrix with adversarial
// cases for the hardening pass.

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  setDoc,
  getDoc,
  updateDoc,
  deleteDoc,
} = require('firebase/firestore');
const {
  ref,
  uploadBytes,
  getBytes,
  uploadBytesResumable,
} = require('firebase/storage');
const fs = require('fs');
const path = require('path');

const PROJECT_ID = 'demo-relaylink-rules-test';

// Helper: build the initialised test environment.
// Firestore rules path is at repo root; storage rules path is too.
// Rules are resolved relative to this test file so the suite works no
// matter where the repo is cloned.
const REPO_ROOT = path.resolve(__dirname, '..', '..');

let pass = 0;
let fail = 0;

async function check(label, fn) {
  try {
    await fn();
    console.log(`PASS  ${label}`);
    pass++;
  } catch (e) {
    console.error(`FAIL  ${label}: ${e.message || e}`);
    fail++;
  }
}

function envPort(name, fallback) {
  const raw = process.env[name];
  if (raw == null || raw === '') return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

(async () => {
  // The framework sends `rules` as the file *content* (not a path), so
  // we read the rules files ourselves.
  const firestoreRules = fs.readFileSync(
    path.join(REPO_ROOT, 'firestore.rules'),
    'utf8',
  );
  const storageRules = fs.readFileSync(
    path.join(REPO_ROOT, 'storage.rules'),
    'utf8',
  );

  // Use a unique ID prefix per run so the emulator's persistent state
  // (firestore keeps state in /tmp between emulators) doesn't make
  // subsequent runs hit "update" rules on docs the previous run created.
  const RUN_ID = Date.now().toString(36);

  const env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    hub: {
      host: '127.0.0.1',
      port: envPort('FIREBASE_EMULATOR_HUB_PORT', 4400),
    },
    firestore: {
      host: '127.0.0.1',
      port: envPort('FIRESTORE_EMULATOR_PORT', 8080),
      rules: firestoreRules,
    },
    storage: {
      host: '127.0.0.1',
      port: envPort('FIREBASE_STORAGE_EMULATOR_PORT', 9199),
      rules: storageRules,
    },
  });

  // Clear the emulator state so each run starts fresh. This matters
  // because if `relay/general/messages/msg-1` exists from a prior run,
  // a create call becomes an update under the hood and our update
  // rule's stricter checks would apply.
  await env.clearFirestore();

  // Two devices, identified by their Ed25519 fingerprints (first 16 hex of
  // the public key). The auth helper for the test environment mints custom
  // tokens with the `sender_id` claim.
  const DEV_A_SENDER_ID = 'aaaaaaaaaaaaaaaa'; // device A
  const DEV_B_SENDER_ID = 'bbbbbbbbbbbbbbbb'; // device B

  async function authedContext(senderId) {
    return env.authenticatedContext(senderId, { sender_id: senderId });
  }

  function goodMessage(overrides = {}) {
    // Fully-formed BROADCAST envelope, ~1 KB; well under the 16 KB cap.
    // Carries `schema_version: 1` so the schema-version allowlist rule
    // admits it. Callers can override the version to assert deny-on-
    // bad-schema cases.
    return {
      id: 'msg-uuid-0001',
      sender_id: DEV_A_SENDER_ID,
      created_at: new Date(),
      payload_b64: 'AAAA',
      ratchet_header: null,
      ttl: 8,
      hop_count: 0,
      signature: 'sig',
      expires_at: new Date(Date.now() + 60 * 60 * 1000),
      schema_version: 1,
      ...overrides,
    };
  }

  // Same as goodMessage but adds a recipient_id field for the
  // DIRECT-relay matrix. The field defaults to the caller A so the
  // path-binding assertion holds for the canonical "create as A
  // addressed to A" case.
  function goodDirectMessage(overrides = {}) {
    return {
      ...goodMessage(),
      recipient_id: DEV_A_SENDER_ID,
      ...overrides,
    };
  }


  // ===== BROADCAST relay matrix =====
  await check('broadcast: any authed device can read', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'relay/general/messages/seed'), goodMessage());
    });
    await assertSucceeds(getDoc(doc(a.firestore(), 'relay/general/messages/seed')));
  });

  await check('broadcast: unauthenticated read denied', async () => {
    const anon = env.unauthenticatedContext();
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'relay/general/messages/seed2'), goodMessage());
    });
    await assertFails(getDoc(doc(anon.firestore(), 'relay/general/messages/seed2')));
  });

  await check('broadcast: create with matching sender_id allowed', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertSucceeds(
      setDoc(doc(a.firestore(), 'relay/general/messages/msg-1'), goodMessage()),
    );
  });

  await check('broadcast: impersonation (sender_id = B, caller = A) denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), 'relay/general/messages/msg-2'),
        goodMessage({ sender_id: DEV_B_SENDER_ID }),
      ),
    );
  });

  await check('broadcast: oversized doc (> 16 KB) denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    // 20 KB payload — over the 16 KB rule cap on payload_b64, under
    // the 1 MiB Firestore hard ceiling.
    const big = 'x'.repeat(20000);
    await assertFails(
      setDoc(
        doc(a.firestore(), 'relay/general/messages/msg-3'),
        goodMessage({ payload_b64: big }),
      ),
    );
  });

  await check('broadcast: hop_count > 0 denied on create', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), 'relay/general/messages/msg-4'),
        goodMessage({ hop_count: 1 }),
      ),
    );
  });

  await check('broadcast: delete denied (TTL handles expiry)', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'relay/general/messages/seed-d'), goodMessage());
    });
    await assertFails(deleteDoc(doc(a.firestore(), 'relay/general/messages/seed-d')));
  });

  // ===== DIRECT relay matrix =====
  await check('direct: recipient (sender_id matches) can read', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-seed`),
        goodDirectMessage(),
      );
    });
    await assertSucceeds(
      getDoc(doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-seed`)),
    );
  });

  await check('direct: non-recipient denied (privacy check)', async () => {
    const b = await authedContext(DEV_B_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-seed2`),
        goodDirectMessage(),
      );
    });
    await assertFails(
      getDoc(doc(b.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-seed2`)),
    );
  });

  await check('direct: create with mismatched path recipient denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-1`),
        { ...goodMessage(), recipient_id: DEV_B_SENDER_ID }, // path = A
      ),
    );
  });

  await check('direct: unauthenticated read denied', async () => {
    const anon = env.unauthenticatedContext();
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-anon`),
        goodDirectMessage(),
      );
    });
    await assertFails(
      getDoc(doc(anon.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-anon`)),
    );
  });

  await check('direct: delete denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-del`),
        goodDirectMessage(),
      );
    });
    await assertFails(
      deleteDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/dm-del`),
      ),
    );
  });

  // ===== verified_orgs matrix =====
  await check('verified_orgs: read allowed for authed device', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), 'verified_orgs/demo-red-crescent'),
        {
          id: 'demo-red-crescent',
          display_name: 'Demo Red Crescent',
          public_key_b64: 'pk',
          last_updated: new Date(),
          expires_at: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
        },
      );
    });
    await assertSucceeds(
      getDoc(doc(a.firestore(), 'verified_orgs/demo-red-crescent')),
    );
  });

  await check('verified_orgs: client write denied (Admin SDK only)', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), 'verified_orgs/spoofed-org'),
        {
          id: 'spoofed-org',
          display_name: 'Spoofed',
          public_key_b64: 'pk',
          last_updated: new Date(),
          expires_at: new Date(Date.now() + 1000),
        },
      ),
    );
  });

  await check('verified_orgs: client delete denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), 'verified_orgs/to-delete'),
        {
          id: 'to-delete',
          display_name: 'X',
          public_key_b64: 'pk',
          last_updated: new Date(),
          expires_at: new Date(Date.now() + 1000),
        },
      );
    });
    await assertFails(
      deleteDoc(doc(a.firestore(), 'verified_orgs/to-delete')),
    );
  });

  // ===== evidence matrix =====
  // Helper: a valid evidence record. Includes `schema_version: 1` so
  // the schema-version gate admits the seed doc.
  function goodEvidence(overrides = {}) {
    return {
      id: 'rec-x',
      sender_id: DEV_B_SENDER_ID,
      recipient_id: DEV_A_SENDER_ID,
      created_at: new Date(),
      payload_b64: 'AAA',
      content_hash_b64: 'AAA',
      signature: 'sig',
      expires_at: new Date(Date.now() + 60 * 60 * 1000),
      schema_version: 1,
      ...overrides,
    };
  }

  await check('evidence: recipient can read own slice', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-1`),
        goodEvidence({ id: 'rec-1', sender_id: DEV_B_SENDER_ID }),
      );
    });
    await assertSucceeds(
      getDoc(doc(a.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-1`)),
    );
  });

  await check('evidence: non-recipient denied', async () => {
    const b = await authedContext(DEV_B_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-2`),
        goodEvidence({ id: 'rec-2', sender_id: DEV_A_SENDER_ID }),
      );
    });
    await assertFails(
      getDoc(doc(b.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-2`)),
    );
  });

  await check('evidence: client update denied (immutable)', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-3`),
        goodEvidence({ id: 'rec-3', sender_id: DEV_A_SENDER_ID }),
      );
    });
    await assertFails(
      updateDoc(
        doc(a.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-3`),
        { payload_b64: 'BBB' },
      ),
    );
  });

  await check('evidence: client delete denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-4`),
        goodEvidence({ id: 'rec-4', sender_id: DEV_A_SENDER_ID }),
      );
    });
    await assertFails(
      deleteDoc(
        doc(a.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-4`),
      ),
    );
  });

  // ===== rate-limit matrix =====
  await check('rate_limit: cross-device create (A writes to B counter) denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `rate_limits/${DEV_B_SENDER_ID}`),
        { count: 1, window_start: new Date() },
      ),
    );
  });

  await check('rate_limit: own counter create within range allowed', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertSucceeds(
      setDoc(
        doc(a.firestore(), `rate_limits/${DEV_A_SENDER_ID}`),
        { count: 0, window_start: new Date() },
      ),
    );
  });

  await check('rate_limit: counter read denied (count is private)', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `rate_limits/${DEV_A_SENDER_ID}`),
        { count: 5, window_start: new Date() },
      );
    });
    await assertFails(
      getDoc(doc(a.firestore(), `rate_limits/${DEV_A_SENDER_ID}`)),
    );
  });

  // ===== catch-all =====
  await check('catch-all: read outside match list denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(getDoc(doc(a.firestore(), 'random-collection/x')));
  });

  // ===== Storage matrix =====
  await check('storage: evidence blob — recipient can read', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await uploadBytes(
        ref(ctx.storage(), `evidence/${DEV_A_SENDER_ID}/seed.bin`),
        new Uint8Array([1, 2, 3]),
        { contentType: 'application/octet-stream' },
      );
    });
    await assertSucceeds(
      getBytes(ref(a.storage(), `evidence/${DEV_A_SENDER_ID}/seed.bin`)),
    );
  });

  await check('storage: evidence blob — non-recipient denied', async () => {
    const b = await authedContext(DEV_B_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await uploadBytes(
        ref(ctx.storage(), `evidence/${DEV_A_SENDER_ID}/seed2.bin`),
        new Uint8Array([1, 2, 3]),
        { contentType: 'application/octet-stream' },
      );
    });
    await assertFails(
      getBytes(ref(b.storage(), `evidence/${DEV_A_SENDER_ID}/seed2.bin`)),
    );
  });

  await check('storage: upload as text/html denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      uploadBytes(
        ref(a.storage(), `evidence/${DEV_A_SENDER_ID}/page.html`),
        new TextEncoder().encode('<html>'),
        { contentType: 'text/html' },
      ),
    );
  });

  await check('storage: any other path denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      uploadBytes(
        ref(a.storage(), 'notevidence/foo.bin'),
        new Uint8Array([1]),
        { contentType: 'application/octet-stream' },
      ),
    );
  });

  // =====================================================================
  // FUZZ / adversarial matrix — hardening pass.
  //
  // Each block below attacks one of the new rule predicates introduced
  // in the hardening pass (schema_version, expiry, field-level writes,
  // per-collection field-level writes, sender-id spoofing on direct
  // messages, oversized payloads, cross-channel reads). All cases
  // should DENY unless explicitly noted.
  // =====================================================================

  // ----- schema_version allowlist -----
  await check('schema_version: unknown version on broadcast create denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), 'relay/general/messages/sv-bad-bc'),
        goodMessage({ schema_version: 99 }),
      ),
    );
  });

  await check('schema_version: missing field on broadcast create denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    const { schema_version, ...noSv } = goodMessage();
    await assertFails(
      setDoc(
        doc(a.firestore(), 'relay/general/messages/sv-missing-bc'),
        noSv,
      ),
    );
  });

  await check('schema_version: non-int version on direct create denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/sv-bad-dm`),
        goodDirectMessage({ schema_version: 'v1' }),
      ),
    );
  });

  await check('schema_version: unknown version on evidence create denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `evidence/${DEV_A_SENDER_ID}/records/sv-bad-ev`),
        goodEvidence({ id: 'sv-bad-ev', sender_id: DEV_A_SENDER_ID, schema_version: 2 }),
      ),
    );
  });

  // ----- expiry on write -----
  await check('expires_at: born-expired broadcast create denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), 'relay/general/messages/exp-bc'),
        goodMessage({
          expires_at: new Date(Date.now() - 1000), // 1s in the past
        }),
      ),
    );
  });

  await check('expires_at: born-expired direct create denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/exp-dm`),
        goodDirectMessage({
          expires_at: new Date(Date.now() - 1000),
        }),
      ),
    );
  });

  await check('expires_at: read of expired direct message denied', async () => {
    // Seed an already-expired doc with the rules disabled (so we can
    // bypass the create-time gate) and confirm the read-time gate
    // denies access.
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/exp-read`),
        goodDirectMessage({
          expires_at: new Date(Date.now() - 1000),
        }),
      );
    });
    await assertFails(
      getDoc(doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/exp-read`)),
    );
  });

  // ----- sender_id spoofing on direct messages -----
  // (re-asserted with the explicit `recipient_id != auth.uid` shape —
  // the requirement is "reject sender_id spoofing when recipient !=
  // auth.uid for direct messages".)
  await check('spoof: direct create with sender_id != auth.uid denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/spoof-1`),
        // caller = A, but the doc claims sender_id = B → spoof attempt
        goodDirectMessage({ sender_id: DEV_B_SENDER_ID, recipient_id: DEV_A_SENDER_ID }),
      ),
    );
  });

  await check('spoof: direct create with sender_id == "0".repeat(16) denied', async () => {
    // A malformed-but-valid-looking hex claim must still be rejected
    // because the doc's `sender_id` doesn't match the caller's claim.
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      setDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/spoof-2`),
        goodDirectMessage({
          sender_id: '0000000000000000',
          recipient_id: DEV_A_SENDER_ID,
        }),
      ),
    );
  });

  // ----- oversized payload -----
  await check('oversize: direct create with > 16 KB payload denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    const big = 'x'.repeat(17000); // 17 KB
    await assertFails(
      setDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/oversize-1`),
        goodDirectMessage({ payload_b64: big }),
      ),
    );
  });

  await check('oversize: evidence create with > 5 KB payload denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    const big = 'x'.repeat(6000); // 6 KB
    await assertFails(
      setDoc(
        doc(a.firestore(), `evidence/${DEV_A_SENDER_ID}/records/oversize-ev`),
        goodEvidence({ id: 'oversize-ev', sender_id: DEV_A_SENDER_ID, payload_b64: big }),
      ),
    );
  });

  // ----- unsigned / read-only field updates -----
  // Direct update by the recipient must keep `sender_id`, `id`,
  // `signature`, and `created_at` immutable; the test below mutates
  // `signature` and asserts deny.
  await check('update_direct: recipient mutating signature denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/upd-sig`),
        goodDirectMessage({ id: 'upd-sig', signature: 'sig-v1' }),
      );
    });
    await assertFails(
      updateDoc(
        doc(a.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/upd-sig`),
        { signature: 'sig-v2' },
      ),
    );
  });

  // Sender (non-recipient) attempting to update a direct message is
  // denied outright — the "sender writes only the immutables"
  // requirement is implemented by gating updates behind the recipient
  // check.
  await check('update_direct: sender update denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    const b = await authedContext(DEV_B_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/upd-sender`),
        goodDirectMessage({ id: 'upd-sender' }),
      );
    });
    // B is the sender; trying to refresh `expires_at` from B must fail
    // because the path's recipientId is A (only A may update).
    await assertFails(
      updateDoc(
        doc(b.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/upd-sender`),
        { expires_at: new Date(Date.now() + 60 * 60 * 1000) },
      ),
    );
  });

  // Broadcast update by a non-relay hop count increment is denied.
  await check('update_broadcast: hop_count jump of 2 denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), 'relay/general/messages/upd-hop'),
        goodMessage({ id: 'upd-hop', hop_count: 0 }),
      );
    });
    await assertFails(
      updateDoc(
        doc(a.firestore(), 'relay/general/messages/upd-hop'),
        { hop_count: 2 },
      ),
    );
  });

  // Broadcast update mutating an immutable field is denied.
  await check('update_broadcast: mutating sender_id denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), 'relay/general/messages/upd-sender-bc'),
        goodMessage({ id: 'upd-sender-bc', sender_id: DEV_A_SENDER_ID }),
      );
    });
    await assertFails(
      updateDoc(
        doc(a.firestore(), 'relay/general/messages/upd-sender-bc'),
        { sender_id: DEV_B_SENDER_ID },
      ),
    );
  });

  // ----- cross-channel reads (direct) -----
  await check('cross_channel: B reads slice of A denied', async () => {
    const b = await authedContext(DEV_B_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/cc-1`),
        goodDirectMessage({ id: 'cc-1' }),
      );
    });
    await assertFails(
      getDoc(doc(b.firestore(), `relay_direct/${DEV_A_SENDER_ID}/messages/cc-1`)),
    );
  });

  await check('cross_channel: B reads evidence addressed to A denied', async () => {
    const b = await authedContext(DEV_B_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `evidence/${DEV_A_SENDER_ID}/records/cc-ev`),
        goodEvidence({ id: 'cc-ev', sender_id: DEV_B_SENDER_ID }),
      );
    });
    await assertFails(
      getDoc(doc(b.firestore(), `evidence/${DEV_A_SENDER_ID}/records/cc-ev`)),
    );
  });

  // ----- storage fuzz: oversized blob, bad file-name, empty blob -----
  await check('storage: oversized blob (> 5 MB) denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    // 6 MB of zeros — over the cap.
    const big = new Uint8Array(6 * 1024 * 1024);
    await assertFails(
      uploadBytes(
        ref(a.storage(), `evidence/${DEV_A_SENDER_ID}/huge.bin`),
        big,
        { contentType: 'application/octet-stream' },
      ),
    );
  });

  await check('storage: empty (zero-byte) blob denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await assertFails(
      uploadBytes(
        ref(a.storage(), `evidence/${DEV_A_SENDER_ID}/empty.bin`),
        new Uint8Array(0),
        { contentType: 'application/octet-stream' },
      ),
    );
  });

  await check('storage: path-traversal file-name denied', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    // The forward slash in `../etc/passwd` is not in the file-name
    // allowlist (only [A-Za-z0-9._-]), so the rule must deny.
    await assertFails(
      uploadBytes(
        ref(a.storage(), `evidence/${DEV_A_SENDER_ID}/..%2Fetc%2Fpasswd`),
        new Uint8Array([1, 2, 3]),
        { contentType: 'application/octet-stream' },
      ),
    );
  });

  // ===== wrap-up =====
  console.log('');
  console.log(`Total: pass=${pass} fail=${fail}`);
  await env.cleanup();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error('TOP-LEVEL ERROR:', e);
  process.exit(2);
});
