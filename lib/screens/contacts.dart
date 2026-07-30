// RelayLink — Ticket #40: Contacts screen (QR pair, manage, phone number).
//
// The contacts screen is the user-facing surface for paired contacts.
// Each row in the list represents a peer whose device identity was captured
// via QR pairing (Ticket #16) and persisted in the local contacts store
// (see [ContactsRepository]). The screen renders three primary affordances:
//
//   * Tap a row  → opens a dialog showing the contact's identity as a QR
//                   (rendered with `qr_flutter` — no camera needed for the
//                   display side, so this widget stays widget-test friendly).
//   * Long-press → opens a bottom sheet with management actions (rename,
//                   set/edit phone number, copy public key, remove).
//   * App-bar actions:
//       - "Show my QR"  — renders the local device's identity as a QR so a
//                         peer can scan and pair.
//       - "Add contact" — stub entry point. The full camera-driven flow
//                         (Ticket #16) wires in here when shipped; for
//                         #40's standalone UI tests this is behind the
//                         repository abstraction.
//
// Architectural notes:
//   * The screen never touches sqflite directly. It depends on a small
//     [ContactsRepository] interface (mirroring the `ContactsLookup` style
//     in `lib/contacts/contacts_lookup.dart` for the SMS path) so the widget
//     can be exercised in tests without spinning up sqflite or mocking
//     platform channels.
//   * The "My QR" QR rendering also avoids the camera: `qr_flutter` is a
//     pure-Dart-on-top-of-platform-view painter, and the resulting widget
//     shows up in `find.byType(QrImageView)`. Tests don't need the camera
//     at any point.
//   * Public-key display: rows always show at least the first 8 hex chars
//     of the contact's public key — a stable, deterministic pseudonym
//     derived from the identity, per the ticket's "public-key-derived
//     identity rows" requirement. The 16-hex `senderId` from
//     [DeviceIdentity] is the canonical form; we truncate to 8 here just
//     to keep the row compact.
//   * Phone indicator: a small phone icon shows up only when the contact
//     has a non-empty `phoneNumber`. Empty/null hides it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:relaylink/contacts/contact.dart';

/// Result type for [ContactsRepository.list] — a snapshot of currently
/// paired contacts. Order is insertion order; the screen renders the list
/// verbatim.
typedef ContactsListCallback = Future<List<Contact>> Function();

/// Persistence surface the contacts screen depends on. The production
/// implementation is wired in `lib/main.dart` (Ticket #40 ships the seam;
/// the in-memory implementation here makes the widget testable in
/// isolation).
///
/// All methods are async so the production implementation can read from
/// sqflite without blocking the UI.
abstract class ContactsRepository {
  /// All currently-paired contacts, in stable order.
  Future<List<Contact>> list();

  /// Save (insert or replace) a contact.
  Future<void> save(Contact contact);

  /// Update an existing contact's display name and phone number (looked up
  /// by [id]). Returns the updated contact, or `null` if no contact had
  /// that id.
  Future<Contact?> updateDetails({
    required String id,
    String? displayName,
    String? phoneNumber,
  });

  /// Remove a contact by id. Returns `true` if a row was deleted.
  Future<bool> remove(String id);
}

/// Simple in-memory [ContactsRepository]. Used by tests; production wiring
/// builds a sqflite-backed implementation elsewhere.
class InMemoryContactsRepository implements ContactsRepository {
  final Map<String, Contact> _byId;
  InMemoryContactsRepository(Iterable<Contact> seed)
      : _byId = <String, Contact>{
          for (final c in seed) c.id: c,
        };

  @override
  Future<List<Contact>> list() async => _byId.values.toList(growable: false);

  @override
  Future<void> save(Contact contact) async {
    _byId[contact.id] = contact;
  }

  @override
  Future<Contact?> updateDetails({
    required String id,
    String? displayName,
    String? phoneNumber,
  }) async {
    final existing = _byId[id];
    if (existing == null) return null;
    final updated = existing.copyWith(
      displayName: displayName ?? existing.displayName,
      phoneNumber: phoneNumber ?? existing.phoneNumber,
    );
    _byId[id] = updated;
    return updated;
  }

  @override
  Future<bool> remove(String id) async => _byId.remove(id) != null;
}

/// Builds the deterministic short pseudonym shown in each row.
///
/// The contact's `id` is conventionally the hex form of the public key
/// (per `lib/contacts/contact.dart`); we slice off the first 8 hex chars to
/// keep the row compact while still giving the user a stable,
// non-guessable identifier. Falls back to the first 8 chars of any
/// non-hex id (e.g. a test-supplied synthetic id).
String deriveContactShortId(String id) {
  if (id.isEmpty) return '';
  final hex = id.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final source = hex.isNotEmpty ? hex : id;
  return source.length <= 8 ? source : source.substring(0, 8);
}

/// Pair-via-invite outcome returned to the production wiring.
class PairInviteResult {
  /// Human-readable label for the just-paired contact (the invite's
  /// `displayName`, or the deviceId prefix when empty).
  final String displayName;

  /// The peer's device id (16-hex `senderId`).
  final String deviceId;

  /// The peer's X25519 public key (raw 32 bytes), or `null` if the
  /// invite did not carry one (defensive — current codec always does).
  final Uint8List? x25519PublicKey;

  const PairInviteResult({
    required this.displayName,
    required this.deviceId,
    required this.x25519PublicKey,
  });
}

/// Pair-via-invite callback signature. The production wiring does the
/// crypto + session bootstrap + persistence; the widget just collects
/// the token from the user and reports back what happened.
typedef PairInviteCallback = Future<PairInviteResult?> Function(String token);

/// The contacts page. Pass a [repository] for persistence; pass
/// [myDeviceIdentityLabel] to render the local device's identity under
/// "Show my QR" (typically the device's `senderId` from `DeviceIdentity`).
class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.repository,
    this.myDeviceIdentityLabel = '',
    this.onAddContactPressed,
    this.onPairViaInvite,
  });

  /// Persistence seam (see [ContactsRepository]).
  final ContactsRepository repository;

  /// Local device identity label rendered on the "My QR" page. Typically
  /// 16 hex chars (sender-id). Empty string hides the label row.
  final String myDeviceIdentityLabel;

  /// Optional callback used by the "Add contact" app-bar action. The
  /// production flow opens a QR scanner (Ticket #16) and then prompts
  /// for a display name; tests can wire a no-op or counter to verify
  /// the button is wired without invoking the camera.
  final VoidCallback? onAddContactPressed;

  /// Optional callback for the "Pair via invite" affordance. The
  /// production wiring decodes a `ContactInvite` token, derives a
  /// `DirectSession` via `ContactInviteCodec.bootstrapSession`, and
  /// persists it through `DirectSessionStore`. The widget is kept
  /// crypto-agnostic — it just collects the token, hands it to the
  /// callback, and surfaces success / failure.
  final PairInviteCallback? onPairViaInvite;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  late Future<List<Contact>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = widget.repository.list();
  }

  Future<void> _refresh() async {
    setState(_reload);
    await _future;
  }

  /// Tap handler — shows a QR dialog for the tapped contact.
  Future<void> _onTapContact(Contact contact) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _ContactQrDialog(contact: contact),
    );
    if (!mounted) return;
  }

  /// Long-press handler — bottom sheet with management actions.
  Future<void> _onLongPressContact(Contact contact) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext ctx) => _ContactActionsSheet(
        contact: contact,
        onEdit: () async {
          Navigator.of(ctx).pop();
          await _editContact(contact);
        },
        onCopyKey: () async {
          Navigator.of(ctx).pop();
          await _copyPublicKey(contact);
        },
        onRemove: () async {
          Navigator.of(ctx).pop();
          await _removeContact(contact);
        },
      ),
    );
    if (!mounted) return;
  }

  /// "Pair via invite" entry point. Shows a paste-invite dialog. If the
  /// user pastes a valid token and the production [onPairViaInvite]
  /// callback returns a non-null result, we persist the contact row
  /// into the repository and refresh the list.
  Future<void> _pairViaInvite() async {
    final callback = widget.onPairViaInvite;
    if (callback == null) {
      // No wiring — surface a helpful no-op so the gesture is still
      // observable in tests.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pair-via-invite is not wired in this build')),
      );
      return;
    }
    final token = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => const _PairViaInviteDialog(),
    );
    if (token == null) return;
    if (!mounted) return;
    PairInviteResult? result;
    Object? error;
    try {
      result = await callback(token);
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pair failed: $error')),
      );
      return;
    }
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invite was not a valid contact invite')),
      );
      return;
    }
    // Persist into the repository so the row shows up in the list and
    // any later SMS-fan-out resolution can find the device-id → phone
    // mapping. The full `Contact` row uses the deviceId as the
    // canonical id (the legacy Ticket #40 convention), and the
    // peer's X25519 public key as the "publicKey" string (hex-encoded
    // for compactness).
    final pkHex = result.x25519PublicKey == null
        ? ''
        : result.x25519PublicKey!
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    await widget.repository.save(
      Contact(
        id: result.deviceId,
        displayName: result.displayName,
        publicKey: pkHex,
        phoneNumber: null,
      ),
    );
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.displayName.isEmpty
              ? 'Paired with ${result.deviceId}'
              : 'Paired with ${result.displayName}',
        ),
      ),
    );
  }

  Future<void> _editContact(Contact contact) async {
    final updated = await showDialog<_ContactEditResult>(
      context: context,
      builder: (BuildContext ctx) => _ContactEditDialog(contact: contact),
    );
    if (updated == null) return;
    await widget.repository.updateDetails(
      id: contact.id,
      displayName: updated.displayName,
      phoneNumber: updated.phoneNumber,
    );
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Contact updated')),
    );
  }

  Future<void> _copyPublicKey(Contact contact) async {
    await Clipboard.setData(ClipboardData(text: contact.publicKey));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Public key copied')),
    );
  }

  Future<void> _removeContact(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        key: const ValueKey<String>('contactsRemoveConfirmDialog'),
        title: const Text('Remove contact?'),
        content: Text(
          'Remove ${contact.displayName.isEmpty ? 'this contact' : contact.displayName} '
          'from your contacts? Their messages will still arrive over the mesh.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey<String>('contactsRemoveConfirmButton'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repository.remove(contact.id);
    if (!mounted) return;
    setState(_reload);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Contact removed')),
    );
  }

  void _showMyQr() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _MyQrDialog(
        deviceIdentityLabel: widget.myDeviceIdentityLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('contactsMyQrButton'),
            tooltip: 'Show my QR',
            icon: const Icon(Icons.qr_code_2),
            onPressed: _showMyQr,
          ),
          IconButton(
            key: const ValueKey<String>('contactsPairInviteButton'),
            tooltip: 'Pair via invite',
            icon: const Icon(Icons.group_add_outlined),
            onPressed: widget.onPairViaInvite == null ? null : _pairViaInvite,
          ),
          IconButton(
            key: const ValueKey<String>('contactsAddButton'),
            tooltip: 'Add contact',
            icon: const Icon(Icons.person_add),
            onPressed: widget.onAddContactPressed,
          ),
        ],
      ),
      body: FutureBuilder<List<Contact>>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<List<Contact>> snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final contacts = snap.data!;
          if (contacts.isEmpty) {
            return _EmptyContacts(
              onAddContactPressed: widget.onAddContactPressed,
              onPairViaInvite:
                  widget.onPairViaInvite == null ? null : _pairViaInvite,
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              key: const ValueKey<String>('contactsList'),
              itemCount: contacts.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int i) {
                final c = contacts[i];
                return _ContactRow(
                  contact: c,
                  onTap: () => _onTapContact(c),
                  onLongPress: () => _onLongPressContact(c),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Empty-state placeholder shown when the contact list is empty.
class _EmptyContacts extends StatelessWidget {
  const _EmptyContacts({
    this.onAddContactPressed,
    this.onPairViaInvite,
  });

  final VoidCallback? onAddContactPressed;
  final VoidCallback? onPairViaInvite;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.contacts, size: 56, color: Colors.grey),
          const SizedBox(height: 8),
          const Text('No contacts yet'),
          const SizedBox(height: 4),
          const Text(
            'Add a contact by scanning their QR code, or pair via invite.',
            key: ValueKey<String>('contactsEmptySubtitle'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey<String>('contactsEmptyAddButton'),
            onPressed: onAddContactPressed,
            icon: const Icon(Icons.person_add),
            label: const Text('Add contact'),
          ),
          if (onPairViaInvite != null) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey<String>('contactsEmptyPairInviteButton'),
              onPressed: onPairViaInvite,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Pair via invite'),
            ),
          ],
        ],
      ),
    );
  }
}

/// One row in the contacts list.
class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.onTap,
    required this.onLongPress,
  });

  final Contact contact;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final shortId = deriveContactShortId(
      contact.publicKey.isNotEmpty ? contact.publicKey : contact.id,
    );
    final title = contact.displayName.isNotEmpty
        ? contact.displayName
        : 'Unnamed contact';
    final keyLen = contact.publicKey.length;
    final subtitle = contact.publicKey.isEmpty
        ? '$shortId…  •  no key'
        : '$shortId…  •  $keyLen-char key';
    return ListTile(
      key: ValueKey<String>('contactRow::${contact.id}'),
      leading: Semantics(
        label: 'Avatar for ${contact.displayName}',
        child: CircleAvatar(
          child: Text(_initials(contact.displayName)),
        ),
      ),
      title: Text(
        title,
        key: ValueKey<String>('contactRowTitle::${contact.id}'),
      ),
      subtitle: Text(subtitle),
      trailing: contact.hasPhone
          ? const Icon(
              Icons.phone,
              key: ValueKey<String>('contactRowPhoneIcon'),
            )
          : null,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  static String _initials(String name) {
    final t = name.trim();
    if (t.isEmpty) return '?';
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

/// Dialog showing a contact's identity as a QR code. The QR is rendered in
/// pure Dart via `qr_flutter`, so the widget test does not need a camera.
class _ContactQrDialog extends StatelessWidget {
  const _ContactQrDialog({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final payload = _qrPayloadFor(contact);
    return AlertDialog(
      key: const ValueKey<String>('contactQrDialog'),
      title: Text(
        contact.displayName.isNotEmpty
            ? contact.displayName
            : 'Unnamed contact',
      ),
      content: SizedBox(
        width: 240,
        height: 280,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: QrImageView(
                key: const ValueKey<String>('contactQrImage'),
                data: payload,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              deriveContactShortId(
                contact.publicKey.isNotEmpty ? contact.publicKey : contact.id,
              ),
              key: const ValueKey<String>('contactQrShortId'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// "Show my QR" dialog — uses the local device's identity label as the QR
/// payload. The full pubkey here is just whatever the caller put on
/// [ContactsPage.myDeviceIdentityLabel] (in production: the device's 16-hex
/// senderId). For widget tests we accept any string.
class _MyQrDialog extends StatelessWidget {
  const _MyQrDialog({required this.deviceIdentityLabel});

  final String deviceIdentityLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('myQrDialog'),
      title: const Text('My QR'),
      content: SizedBox(
        width: 240,
        height: 280,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: QrImageView(
                key: const ValueKey<String>('myQrImage'),
                data: deviceIdentityLabel.isEmpty
                    ? 'relaylink://identity/empty'
                    : deviceIdentityLabel,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              deviceIdentityLabel.isEmpty
                  ? '(no identity)'
                  : deviceIdentityLabel,
              key: const ValueKey<String>('myQrLabel'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Bottom sheet shown on long-press. Three actions: edit, copy key, remove.
class _ContactActionsSheet extends StatelessWidget {
  const _ContactActionsSheet({
    required this.contact,
    required this.onEdit,
    required this.onCopyKey,
    required this.onRemove,
  });

  final Contact contact;
  final VoidCallback onEdit;
  final VoidCallback onCopyKey;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            key: const ValueKey<String>('contactsActionEdit'),
            leading: const Icon(Icons.edit),
            title: const Text('Edit name & phone'),
            onTap: onEdit,
          ),
          ListTile(
            key: const ValueKey<String>('contactsActionCopyKey'),
            leading: const Icon(Icons.copy),
            title: const Text('Copy public key'),
            onTap: onCopyKey,
          ),
          ListTile(
            key: const ValueKey<String>('contactsActionRemove'),
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove'),
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Result of the edit dialog. Null = cancelled.
class _ContactEditResult {
  const _ContactEditResult({required this.displayName, required this.phoneNumber});
  final String displayName;
  final String? phoneNumber;
}

/// Dialog for editing a contact's display name and phone number.
class _ContactEditDialog extends StatefulWidget {
  const _ContactEditDialog({required this.contact});

  final Contact contact;

  @override
  State<_ContactEditDialog> createState() => _ContactEditDialogState();
}

class _ContactEditDialogState extends State<_ContactEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.contact.displayName);
    _phone = TextEditingController(text: widget.contact.phoneNumber ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (!mounted) return;
    Navigator.of(context).pop(
      _ContactEditResult(
        displayName: name,
        phoneNumber: phone.isEmpty ? null : phone,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('contactsEditDialog'),
      title: const Text('Edit contact'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            key: const ValueKey<String>('contactsEditNameField'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'Display name'),
          ),
          TextField(
            key: const ValueKey<String>('contactsEditPhoneField'),
            controller: _phone,
            decoration: const InputDecoration(
              labelText: 'Phone number (optional)',
              hintText: '+15555550123',
            ),
            keyboardType: TextInputType.phone,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('contactsEditSaveButton'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Build the QR payload for a contact. Encodes the public key plus a
/// small, versioned envelope so future readers can detect format changes.
///
/// The payload is just a string — `qr_flutter` encodes whatever bytes we
/// give it; this is the wire format the camera-side scanner (Ticket #16)
/// would parse back into a paired contact.
String _qrPayloadFor(Contact contact) {
  return 'relaylink://contact/v1?'
      'pk=${Uri.encodeComponent(contact.publicKey)}'
      '&id=${Uri.encodeComponent(contact.id)}';
}

// ---------------------------------------------------------------------------
// Pair-via-invite dialog
// ---------------------------------------------------------------------------

/// Dialog that collects an invite token from the user (paste or scan),
/// then returns the trimmed string when the user taps "Pair". Cancel
/// returns `null`. The actual decode + crypto pairing lives in the
/// production [PairInviteCallback] — this dialog is purely UI.
class _PairViaInviteDialog extends StatefulWidget {
  const _PairViaInviteDialog();

  @override
  State<_PairViaInviteDialog> createState() => _PairViaInviteDialogState();
}

class _PairViaInviteDialogState extends State<_PairViaInviteDialog> {
  late final TextEditingController _token;

  @override
  void initState() {
    super.initState();
    _token = TextEditingController();
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  void _paste() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (!mounted) return;
    setState(() => _token.text = text.trim());
  }

  void _submit() {
    final t = _token.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('contactsPairInviteDialog'),
      title: const Text('Pair via invite'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Paste an invite token from your peer. The token starts with '
            '"relaylink-invite-v1:".',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey<String>('contactsPairInviteField'),
            controller: _token,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'relaylink-invite-v1:...',
            ),
            keyboardType: TextInputType.multiline,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey<String>('contactsPairInvitePasteButton'),
              onPressed: _paste,
              icon: const Icon(Icons.paste),
              label: const Text('Paste from clipboard'),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('contactsPairInviteCancelButton'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('contactsPairInviteSubmitButton'),
          onPressed: _submit,
          child: const Text('Pair'),
        ),
      ],
    );
  }
}
