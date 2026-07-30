// RelayLink — Ticket #32: Vault UI (list, view, delete, compose).
//
// The "Vault" tab renders the local encrypted Evidence Vault as a list of
// metadata-only rows (created date, recipient, status, ciphertext length) —
// NO plaintext preview is shown, on purpose, to prevent shoulder-surfing
// (see SPEC.md §8). Tapping a row opens a view screen that decrypts the
// record on demand. The + button opens a compose screen that captures
// free-text evidence and optionally addresses it to a recipient (from the
// Contacts list or to "self").
//
// The UI is intentionally framework-light: a small set of `StatefulWidget`s
// that consume a `VaultStore` (for capture/list/decrypt) and a `LocalDb`
// (for delete) plus a `List<ContactRecord>` (for the recipient picker).
// The store and DB singletons are wired by the app's main scaffold;
// tests inject in-memory fixtures via `VaultStore.create` and
// `LocalDb.withDatabase`.
//
// Screens exposed:
//   * `VaultListScreen`   — the visible "Vault" tab contents.
//   * `VaultViewScreen`    — decrypts on tap and shows the plaintext.
//   * `VaultComposeScreen` — text input + recipient picker.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:relaylink/contacts/contacts_lookup.dart';
import 'package:relaylink/vault/store.dart';

/// Possible recipient choices for a new capture. The compose screen renders
/// one entry for each contact plus a "self" entry at the top — keeping the
/// data shape flat so the dropdown can be a simple `ListView` of options.
class VaultRecipientChoice {
  /// Device id to bind into the AAD. `null` means self-encrypted.
  final String? deviceId;

  /// Human label shown in the picker.
  final String label;

  const VaultRecipientChoice({required this.deviceId, required this.label});
}

/// "Self" recipient choice. Bound to `null` so the store uses the
/// `self` AAD.
const VaultRecipientChoice kVaultSelfChoice = VaultRecipientChoice(
  deviceId: null,
  label: 'Self',
);

/// Stable [ValueKey] for the recipient-picker dropdown.
const ValueKey<String> kVaultRecipientPickerKey = ValueKey<String>(
  'vaultRecipientPicker',
);

/// Stable [ValueKey] for the text input in the compose screen.
const ValueKey<String> kVaultComposeTextFieldKey = ValueKey<String>(
  'vaultComposeTextField',
);

/// Stable [ValueKey] for the "Capture" / submit button in the compose screen.
const ValueKey<String> kVaultComposeSubmitKey = ValueKey<String>(
  'vaultComposeSubmit',
);

/// Stable [ValueKey] for the "+" FAB on the vault list.
const ValueKey<String> kVaultAddFabKey = ValueKey<String>(
  'vaultAddFab',
);

/// Stable [ValueKey] for the empty-state placeholder row.
const ValueKey<String> kVaultEmptyStateKey = ValueKey<String>(
  'vaultEmptyState',
);

/// Stable [ValueKey] for the delete affordance on a vault record row.
const ValueKey<String> kVaultDeleteButtonKey = ValueKey<String>(
  'vaultDeleteButton',
);

/// Stable [ValueKey] for the confirm-delete alert dialog button.
const ValueKey<String> kVaultDeleteConfirmKey = ValueKey<String>(
  'vaultDeleteConfirm',
);

/// Stable [ValueKey] for the cancel-delete alert dialog button.
const ValueKey<String> kVaultDeleteCancelKey = ValueKey<String>(
  'vaultDeleteCancel',
);

/// Stable [ValueKey] for the decrypted plaintext viewer.
const ValueKey<String> kVaultPlaintextViewKey = ValueKey<String>(
  'vaultPlaintextView',
);

/// Stable [ValueKey] for the recipient chip on each row.
const ValueKey<String> kVaultRowRecipientKey = ValueKey<String>(
  'vaultRowRecipient',
);

/// Stable [ValueKey] for the metadata list on the list screen.
const ValueKey<String> kVaultListKey = ValueKey<String>(
  'vaultList',
);

/// Stable [ValueKey] for the "Decrypt" affordance on the view screen.
const ValueKey<String> kVaultDecryptButtonKey = ValueKey<String>(
  'vaultDecryptButton',
);

/// Format a UTC creation timestamp (millis since epoch) as a short
/// human-readable date (yyyy-MM-dd HH:mm local). Visible to the user;
/// tests pin the exact format so it doesn't silently drift.
String formatVaultCreatedAt(int millisSinceEpoch) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millisSinceEpoch, isUtc: true)
      .toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// Format a ciphertext blob length as a short human-readable byte count,
/// e.g. `48 B`. Visible to the user; the suffix is consistent so tests
/// can grep `48 B` reliably.
String formatVaultCipherLength(int bytes) => '$bytes B';

/// The vault list screen.
///
/// Renders one row per [VaultRecord] with metadata-only fields — no
/// plaintext preview. Tapping a row pushes [VaultViewScreen]; the FAB
/// pushes [VaultComposeScreen]. State is reloaded from [store] when the
/// widget is created and after each successful capture/delete.
class VaultListScreen extends StatefulWidget {
  const VaultListScreen({
    super.key,
    required this.store,
    required this.contacts,
  });

  /// The vault store backing this screen. Callers in production wire
  /// `VaultStore.instance()`; tests inject a `VaultStore.create` with
  /// in-memory sqflite + a fresh identity.
  final VaultStore store;

  /// Available contacts for the recipient picker. May be empty —
  /// the compose screen still works (only "Self" is offered).
  final List<ContactRecord> contacts;

  /// Push the vault list screen as a [Navigator] route. Convenience
  /// wrapper that keeps `MaterialPageRoute` assembly in one place.
  static Route<void> route({
    required VaultStore store,
    required List<ContactRecord> contacts,
  }) {
    return MaterialPageRoute<void>(
      builder: (_) => VaultListScreen(
        store: store,
        contacts: contacts,
      ),
    );
  }

  @override
  State<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends State<VaultListScreen> {
  late Future<List<VaultRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.store.list();
  }

  /// Re-fetch after a capture or delete. Called by the screen itself
  /// after a successful mutation.
  void reload() {
    setState(() {
      _future = widget.store.list();
    });
  }

  Future<void> _openCompose() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => VaultComposeScreen(
          store: widget.store,
          contacts: widget.contacts,
        ),
      ),
    );
    if (result == true) {
      reload();
    }
  }

  Future<void> _openView(VaultRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VaultViewScreen(
          store: widget.store,
          record: record,
        ),
      ),
    );
    // No need to reload — viewing doesn't mutate the store.
  }

  Future<void> _confirmAndDelete(VaultRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete record?'),
        content: const Text(
          'This will permanently remove the encrypted record from this '
          'device. The decrypted text is NOT recoverable after deletion.',
        ),
        actions: <Widget>[
          TextButton(
            key: kVaultDeleteCancelKey,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: kVaultDeleteConfirmKey,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.store.delete(record.id);
      if (!mounted) return;
      reload();
    }
  }

  String _recipientLabel(String? recipientId) {
    if (recipientId == null || recipientId.isEmpty) return 'self';
    final match = widget.contacts
        .where((c) => c.deviceId == recipientId)
        .cast<ContactRecord?>()
        .firstWhere((_) => true, orElse: () => null);
    if (match != null && match.displayName.isNotEmpty) {
      return match.displayName;
    }
    return recipientId;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault'),
      ),
      body: SafeArea(
        child: FutureBuilder<List<VaultRecord>>(
          future: _future,
          builder: (BuildContext context,
              AsyncSnapshot<List<VaultRecord>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load vault: ${snapshot.error}'),
              );
            }
            final records = snapshot.data ?? <VaultRecord>[];
            if (records.isEmpty) {
              return Center(
                key: kVaultEmptyStateKey,
                child: const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No evidence captured yet. Tap + to capture.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView.separated(
              key: kVaultListKey,
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int i) {
                final rec = records[i];
                return _VaultRecordTile(
                  record: rec,
                  recipientLabel: _recipientLabel(rec.recipientId),
                  onTap: () => _openView(rec),
                  onDelete: () => _confirmAndDelete(rec),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: kVaultAddFabKey,
        onPressed: _openCompose,
        tooltip: 'Capture evidence',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// One row in the vault list. Shows metadata only — never plaintext.
class _VaultRecordTile extends StatelessWidget {
  const _VaultRecordTile({
    required this.record,
    required this.recipientLabel,
    required this.onTap,
    required this.onDelete,
  });

  final VaultRecord record;
  final String recipientLabel;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(formatVaultCreatedAt(record.createdAt)),
      subtitle: Text(
        'recipient: $recipientLabel · '
        'status: ${record.status} · '
        'length: ${formatVaultCipherLength(record.ciphertext.length)}',
        key: kVaultRowRecipientKey,
      ),
      trailing: IconButton(
        key: kVaultDeleteButtonKey,
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}

/// The view screen. Decrypts the record on tap and shows the plaintext in
/// a scrollable area. The "Decrypt" affordance is explicit so the
/// decryption cost isn't paid on every navigation push.
class VaultViewScreen extends StatefulWidget {
  const VaultViewScreen({
    super.key,
    required this.store,
    required this.record,
  });

  final VaultStore store;
  final VaultRecord record;

  @override
  State<VaultViewScreen> createState() => _VaultViewScreenState();
}

class _VaultViewScreenState extends State<VaultViewScreen> {
  String? _plaintext;
  bool _busy = false;
  Object? _error;

  Future<void> _decrypt() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await widget.store.decrypt(widget.record);
      setState(() {
        _plaintext = utf8.decode(bytes, allowMalformed: true);
      });
    } catch (e) {
      setState(() {
        _error = e;
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault record'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Captured: ${formatVaultCreatedAt(widget.record.createdAt)}',
              ),
              Text(
                'Recipient: ${widget.record.recipientId ?? 'self'}',
              ),
              Text('Status: ${widget.record.status}'),
              Text(
                'Cipher length: '
                '${formatVaultCipherLength(widget.record.ciphertext.length)}',
              ),
              const SizedBox(height: 16),
              if (_plaintext == null && _error == null)
                FilledButton(
                  key: kVaultDecryptButtonKey,
                  onPressed: _busy ? null : _decrypt,
                  child: Text(_busy ? 'Decrypting…' : 'Decrypt'),
                ),
              if (_error != null)
                Text(
                  'Decryption failed: $_error',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              if (_plaintext != null)
                Expanded(
                  child: SingleChildScrollView(
                    key: kVaultPlaintextViewKey,
                    child: SelectableText(_plaintext!),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The compose screen. Free-text input + a recipient picker (contacts +
/// "Self"). On submit, calls `VaultStore.capture` and pops with `true` so
/// the list can reload.
class VaultComposeScreen extends StatefulWidget {
  const VaultComposeScreen({
    super.key,
    required this.store,
    required this.contacts,
  });

  final VaultStore store;
  final List<ContactRecord> contacts;

  @override
  State<VaultComposeScreen> createState() => _VaultComposeScreenState();
}

class _VaultComposeScreenState extends State<VaultComposeScreen> {
  final TextEditingController _controller = TextEditingController();
  VaultRecipientChoice _selected = kVaultSelfChoice;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<VaultRecipientChoice> get _choices {
    return <VaultRecipientChoice>[
      kVaultSelfChoice,
      for (final c in widget.contacts)
        VaultRecipientChoice(
          deviceId: c.deviceId,
          label: c.displayName.isNotEmpty ? c.displayName : c.deviceId,
        ),
    ];
  }

  Future<void> _capture() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.store.capture(text, _selected.deviceId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Capture evidence'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                key: kVaultComposeTextFieldKey,
                controller: _controller,
                enabled: !_busy,
                maxLines: 8,
                minLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Type the evidence here. Plaintext is encrypted '
                      'on this device before being stored.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<VaultRecipientChoice>(
                key: kVaultRecipientPickerKey,
                initialValue: _selected,
                decoration: const InputDecoration(
                  labelText: 'Recipient',
                  border: OutlineInputBorder(),
                ),
                items: choices
                    .map(
                      (c) => DropdownMenuItem<VaultRecipientChoice>(
                        value: c,
                        child: Text(c.label),
                      ),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (VaultRecipientChoice? v) {
                        if (v != null) {
                          setState(() => _selected = v);
                        }
                      },
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: kVaultComposeSubmitKey,
                onPressed: _busy ? null : _capture,
                child: Text(_busy ? 'Capturing…' : 'Capture'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
