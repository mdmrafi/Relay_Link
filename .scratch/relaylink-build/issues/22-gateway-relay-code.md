# 22 — Gateway mode relay code (push others' messages, pull, inject)

**What to build:** When Gateway toggle (#21) is on, the running app: pulls from local mesh any message addressed to others (different recipient_id, or BROADCAST not originated here), pushes those messages to Firestore relay collections (#20). Also pulls from Firestore (under the same rules), injects into local mesh via #08's transport. Runs continuously while toggle is on. Implements a "shadow identity" so messages pushed by us on behalf of others preserve the original sender_id, not ours.

**Blocked by:** #20, #21, #09

**Status:** ready-for-agent

- [ ] When toggle is on, mesh-receive handler checks "is this message for me?" — if no, push to Firestore with original sender_id preserved
- [ ] Firestore-polling handler also pulls for messages destined for nearby mesh users (any direct message where recipient_id matches a known mesh peer, or any BROADCAST)
- [ ] Pulled messages are re-injected into the mesh transport's outgoing pipeline (will be relayed per #09)
- [ ] When toggle is off, no gateway activity — direct internet messaging (#20) still works for own traffic
- [ ] Test: two devices A (gateway on) and B (offline, no internet), A relays B's outgoing message through its internet to Firestore, B comes online, pulls message
- [ ] Manual demo with three devices: B (sender, no internet), A (gateway), C (recipient, no internet, in mesh range of A) — A pushes B's message to Firestore, gateway of C pulls it down, C receives