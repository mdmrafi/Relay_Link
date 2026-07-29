# 34 — "Save as evidence" from chat (long-press affordance)

**What to build:** In the chat screen, long-press any message → context menu appears with "Save as evidence" option. Tapping it captures the message text into the vault (#31) with provenance linking back to the original chat message id.

**Blocked by:** #32, #39 (chat screen)

**Status:** ready-for-agent

- [ ] Long-press on a chat message row → context menu with at least "Save as evidence" item
- [ ] Tap "Save as evidence" → vault record created with `origin_message_id` set
- [ ] User sees brief confirmation toast: "Saved to Evidence Vault"
- [ ] No copy-paste through clipboard — message body is passed directly to vault
- [ ] Works on own messages and on received messages