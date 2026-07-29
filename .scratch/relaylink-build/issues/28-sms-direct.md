# 28 — SMS DIRECT (DIRECT messages to a specific phone number)

**What to build:** When sending a DIRECT message, if the recipient has a phone number and no other transport is available, use the SMS transport (#26) to send directly to that number. (DIRECT messages typically ride mesh or internet, but SMS is the fallback when neither is available.)

**Blocked by:** #26, #40

**Status:** ready-for-agent

- [ ] Direct message with a known phone-number recipient uses SMS transport when mesh/internet unavailable
- [ ] Manual demo: device A DIRECT-message to device B's phone number, B receives and decrypts correctly
- [ ] No phone number → SMS skip, message waits for mesh/internet
- [ ] README names this as a fallback path, not the default