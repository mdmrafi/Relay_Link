# 39 — Chat screen (type selector, composer, display, ALERT badge)

**What to build:** `lib/screens/chat.dart` — the main messaging surface. Composer at the bottom with type selector (SOS / Safe / Help / Chat / Alert), message list above showing received and sent messages sorted by `created_at`. Each message shows sender_display_name, type icon, body (decrypted), origin (MESH/SMS/INTERNET icon). ALERT messages use the badge from #37.

**Blocked by:** #04, #08, #20, #26

**Status:** ready-for-agent

- [ ] Type selector visible in composer
- [ ] Sending: type selector → compose → send via TransportManager
- [ ] Receiving: incoming messages from TransportManager.incoming display in the list
- [ ] Decryption: BROADCAST with current channel key, DIRECT with current session
- [ ] Location attachment toggle (opt-in only per spec §6.4)
- [ ] Long-press on message → context menu with at least "Save as evidence" (#34)
- [ ] ALERT messages display verified badge (#37)