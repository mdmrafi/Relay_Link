# 32 — Vault UI (list, view, delete)

**What to build:** A "Vault" tab in the app showing the list of vault records (decrypted metadata: created date, recipient if any, status, length). Tap a record to view decrypted content. Delete button per record with confirm.

**Blocked by:** #31

**Status:** ready-for-agent

- [ ] Vault tab visible in main navigation
- [ ] Empty state: "No evidence captured yet. Tap + to capture."
- [ ] Record list shows metadata only (no plaintext preview to prevent shoulder-surfing)
- [ ] View screen decrypts and displays full text
- [ ] Delete confirms before removing
- [ ] Compose screen: text input + "Recipient" picker (from contacts or self)