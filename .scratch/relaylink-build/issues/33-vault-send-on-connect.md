# 33 — Vault send-on-connect (queue, transmit when channel available)

**What to build:** When any transport (mesh, internet, SMS) becomes available, the vault records with a `recipientId` are queued for transmission as DIRECT messages. On success, status updated to "sent."

**Blocked by:** #31, #20, #08

**Status:** ready-for-agent

- [ ] When a transport reports `isAvailable() = true`, scan vault records with `recipientId != null && status != "sent"`
- [ ] For each, create a DIRECT message containing the decrypted plaintext, encrypt per #13, send via TransportManager
- [ ] On transport success, mark record `status = "sent"`
- [ ] If transport fails, leave status unchanged for next attempt
- [ ] Manual demo: capture offline, then bring online, recipient receives the message and decrypts correctly