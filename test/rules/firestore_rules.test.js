// Behaviour-driven validation for firestore.rules + storage.rules
// (Ticket #19). Runs against the Firebase emulator.
//
// Spawned by the same emulator process; started before this test runs,
// the emulators listen on localhost:8080 (Firestore) and 4443 (Storage).
//
// The matrix here mirrors the one in firestore.rules.test.md. Each
// (operation × caller) pair asserts allow or deny explicitly.

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

const PROJECT_ID = 'demo-relaylink-rules-test';

// Helper: build the initialised test environment.
// Firestore rules path is at repo root; storage rules path is too.

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

(async () => {
  // The framework sends `rules` as the file *content* (not a path), so
  // we read the rules files ourselves.
  const firestoreRules = fs.readFileSync(
    '/home/azmine/Desktop/July-2026-hackathon/firestore.rules',
    'utf8',
  );
  const storageRules = fs.readFileSync(
    '/home/azmine/Desktop/July-2026-hackathon/storage.rules',
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
      port: 4400,    // Firebase Emulator Hub default
    },
    firestore: {
      host: '127.0.0.1',
      port: 8080,
      rules: firestoreRules,
    },
    storage: {
      host: '127.0.0.1',
      port: 9199,    // Firebase Storage Emulator default
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
        { ...goodMessage(), recipient_id: DEV_A_SENDER_ID },
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
        { ...goodMessage(), recipient_id: DEV_A_SENDER_ID },
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
        { ...goodMessage(), recipient_id: DEV_A_SENDER_ID },
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
        { ...goodMessage(), recipient_id: DEV_A_SENDER_ID },
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
  await check('evidence: recipient can read own slice', async () => {
    const a = await authedContext(DEV_A_SENDER_ID);
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(
        doc(ctx.firestore(), `evidence/${DEV_A_SENDER_ID}/records/rec-1`),
        {
          id: 'rec-1',
          sender_id: DEV_B_SENDER_ID,
          recipient_id: DEV_A_SENDER_ID,
          created_at: new Date(),
          payload_b64: 'AAA',
          content_hash_b64: 'AAA',
          signature: 'sig',
          expires_at: new Date(Date.now() + 60 * 60 * 1000),
        },
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
        {
          id: 'rec-2',
          sender_id: DEV_A_SENDER_ID,
          recipient_id: DEV_A_SENDER_ID,
          created_at: new Date(),
          payload_b64: 'AAA',
          content_hash_b64: 'AAA',
          signature: 'sig',
          expires_at: new Date(Date.now() + 60 * 60 * 1000),
        },
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
        {
          id: 'rec-3',
          sender_id: DEV_A_SENDER_ID,
          recipient_id: DEV_A_SENDER_ID,
          created_at: new Date(),
          payload_b64: 'AAA',
          content_hash_b64: 'AAA',
          signature: 'sig',
          expires_at: new Date(Date.now() + 60 * 60 * 1000),
        },
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
        {
          id: 'rec-4',
          sender_id: DEV_A_SENDER_ID,
          recipient_id: DEV_A_SENDER_ID,
          created_at: new Date(),
          payload_b64: 'AAA',
          content_hash_b64: 'AAA',
          signature: 'sig',
          expires_at: new Date(Date.now() + 60 * 60 * 1000),
        },
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

  // ===== wrap-up =====
  console.log('');
  console.log(`Total: pass=${pass} fail=${fail}`);
  await env.cleanup();
  process.exit(fail === 0 ? 0 : 1);
})().catch((e) => {
  console.error('TOP-LEVEL ERROR:', e);
  process.exit(2);
});
