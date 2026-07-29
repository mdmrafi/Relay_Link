# 40 — Contacts screen (QR pair, manage, phone number per contact)

**What to build:** `lib/screens/contacts.dart` — list of paired contacts (paired via QR scan of each other's device identity). Each contact has: display name, public key, optional phone number (set manually). "Add contact" scans a QR; "Show my QR" displays yours. Tap a contact to view details / edit phone number.

**Blocked by:** #02, #16

**Status:** ready-for-agent

- [ ] Add-contact flow: scan QR, prompt for display name, save
- [ ] Show-my-QR flow: display device identity as QR (channel-id + identity public key)
- [ ] Contact list shows display name + first 8 chars of public key + phone icon if number set
- [ ] Edit phone number per contact
- [ ] Contacts persisted in sqflite (separate `contacts` table)
- [ ] Used by SMS fan-out (#27) and SMS direct (#28) and vault recipient picker (#32)