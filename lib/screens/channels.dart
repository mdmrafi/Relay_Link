// RelayLink — Ticket #41: Channels screen.
//
// Lists every channel the local device has joined (always including
// `public`, seeded by `ChannelKeyStore.init()`), lets the user pick
// which one is "active" for chat, and exposes two flows that fan out to
// #16's QR scanner/encoder:
//
//   * Create channel — prompt for a name, generate a fresh 32-byte key
//     via `ChannelKeyStore.generateKey()`, persist it via
//     `ChannelKeyStore.addChannel(...)`, then surface an invite-QR
//     dialog so the creator can show it to a peer. (When #16 ships the
//     real encoder, the QR bytes come from `encodeChannelQR(...)` —
//     for now we render a textual placeholder so this screen is
//     buildable end-to-end.)
//
//   * Join channel — invoke the injected [scanQr] callback; if it
//     returns a non-empty payload, treat it as `<channelId>:<key>`,
//     parse it, and add to the joined set.
//
// Active-channel state is owned by the caller (this widget just emits
// `onActiveChannelChanged`); the chat composer wires its own notifier
// in #39. The "public" row is intentionally not dismissable; that's an
// explicit ticket acceptance criterion, not just a UX nicety.
//
// All side-effects that touch secure storage go through the injected
// [ChannelKeyStore] (a real store in production, a mock-backed one in
// tests). The QR scan step is the same: production uses the #16
// `decodeChannelQR(bytes)` flow; tests inject a scripted future.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:relaylink/channels/keys.dart';
import 'package:relaylink/crypto/broadcast.dart';

/// Decode a channel invite payload ("`<id>`:`<base64-key>`") into a
/// `(channelId, key)` pair.
///
/// Returns `null` if the payload is malformed (missing colon, bad
/// base64, wrong key length, empty id). Exposed at top level (not
/// private) so the test can hit it directly without instantiating the
/// widget tree.
({String channelId, List<int> key})? parseChannelInvite(String payload) {
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return null;
  final colon = trimmed.indexOf(':');
  if (colon <= 0 || colon >= trimmed.length - 1) return null;
  final id = trimmed.substring(0, colon).trim();
  final b64 = trimmed.substring(colon + 1).trim();
  if (id.isEmpty || !_isValidChannelId(id)) return null;
  // Defensive base64 decode: the encoder will always emit standard
  // base64 but we accept URL-safe alphabets too and re-pad so a hand-
  // typed payload doesn't trip the parser.
  List<int> decoded;
  try {
    var s = b64.replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    decoded = base64.decode(s);
  } on Object {
    return null;
  }
  if (decoded.length != 32) return null;
  return (channelId: id, key: decoded);
}

/// True iff [id] is a safe channel identifier: non-empty, only
/// letters/digits/dash/underscore (so the QR encoder doesn't have to
/// escape), no commas or newlines (so it can't corrupt the index).
bool _isValidChannelId(String id) {
  final re = RegExp(r'^[A-Za-z0-9_-]+$');
  return id.isNotEmpty && re.hasMatch(id);
}

/// Signature of the injected QR-scan callback used by the "Join"
/// flow. Returns the raw decoded payload (typically
/// "`<channelId>`:`<base64-key>`"), or `null` if the user cancelled.
typedef ScanQrCallback = Future<String?> Function();

/// The channels screen.
///
/// Pure presentation + state: reads/writes via [keyStore], injects QR
/// scanning via [scanQr]. The widget does NOT own "active channel"
/// state — it just emits `onActiveChannelChanged` so the chat composer
/// (when it lands) can wire a shared notifier in #39.
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({
    super.key,
    required this.keyStore,
    required this.activeChannelId,
    required this.onActiveChannelChanged,
    this.scanQr,
    this.showQrInvite,
  });

  /// The persistent store to read joined channels from and write new
  /// ones into. Required.
  final ChannelKeyStore keyStore;

  /// The id of the channel the chat composer is currently sending on.
  /// Used purely as a display hint (highlighted row).
  final String activeChannelId;

  /// Called whenever the user picks a different active channel. The
  /// caller is responsible for actually updating [activeChannelId].
  final ValueChanged<String> onActiveChannelChanged;

  /// Optional scan callback. Production passes a closure that opens
  /// `mobile_scanner` and returns the decoded payload; tests pass a
  /// scripted `Future.value(...)`.
  final ScanQrCallback? scanQr;

  /// Optional builder for the invite-QR overlay shown after a channel
  /// is created. Receives `(channelId, key)`; defaults to a small
  /// textual placeholder so this widget compiles before #16's
  /// `encodeChannelQR` lands.
  final Widget Function(BuildContext, String, List<int>)? showQrInvite;

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  /// `null` while the initial `listChannels()` future is in flight.
  List<String>? _channels;

  /// Last scan/parse error to surface under the "Join" button, if any.
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final ids = await widget.keyStore.listChannels();
    if (!mounted) return;
    setState(() => _channels = ids);
  }

  Future<void> _onCreate() async {
    setState(() => _scanError = null);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _CreateChannelDialog(),
    );
    if (name == null) return;
    final trimmed = name.trim();
    if (!_isValidChannelId(trimmed)) {
      if (!mounted) return;
      setState(() => _scanError = 'Invalid channel name');
      return;
    }
    final key = widget.keyStore.generateKey();
    await widget.keyStore.addChannel(trimmed, key);
    await _refresh();
    if (!mounted) return;
    await _showInviteOverlay(trimmed, key);
  }

  Future<void> _onJoin() async {
    setState(() => _scanError = null);
    final scan = widget.scanQr;
    if (scan == null) {
      setState(() => _scanError = 'QR scanner not available');
      return;
    }
    final String? payload;
    try {
      payload = await scan();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _scanError = 'Scan failed: $e');
      return;
    }
    if (payload == null) return; // user cancelled
    final parsed = parseChannelInvite(payload);
    if (parsed == null) {
      if (!mounted) return;
      setState(() => _scanError = 'QR did not contain a channel invite');
      return;
    }
    await widget.keyStore.addChannel(parsed.channelId, parsed.key);
    await _refresh();
  }

  Future<void> _showInviteOverlay(String id, List<int> key) async {
    final builder = widget.showQrInvite;
    if (builder == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        key: const ValueKey<String>('inviteQrDialog'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: builder(ctx, id, key),
        ),
      ),
    );
  }

  void _onPick(String id) {
    if (id == widget.activeChannelId) return;
    widget.onActiveChannelChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    final channels = _channels;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Channels'),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: channels == null
                  ? const Center(child: CircularProgressIndicator())
                  : (channels.isEmpty
                      ? const Center(
                          child: Text('No channels joined'),
                        )
                      : ListView(
                          children: <Widget>[
                            for (final id in channels)
                              _ChannelRow(
                                key: ValueKey<String>('channelRow::$id'),
                                channelId: id,
                                isActive: id == widget.activeChannelId,
                                isPublic: id == kPublicChannelId,
                                onTap: () => _onPick(id),
                              ),
                          ],
                        )),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: <Widget>[
                  if (_scanError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _scanError!,
                        key: const ValueKey<String>('channelsScanError'),
                        style: const TextStyle(
                          color: Color(0xFFEF5350),
                        ),
                      ),
                    ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey<String>('joinChannelButton'),
                          onPressed: widget.scanQr == null ? null : _onJoin,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Join'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey<String>('createChannelButton'),
                          onPressed: _onCreate,
                          icon: const Icon(Icons.add),
                          label: const Text('Create'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    super.key,
    required this.channelId,
    required this.isActive,
    required this.isPublic,
    required this.onTap,
  });

  final String channelId;
  final bool isActive;
  final bool isPublic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        isActive ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: isActive
            ? const Color(0xFF4FC3F7)
            : const Color(0xFF9AA4B2),
      ),
      title: Text(channelId),
      subtitle: Text(
        isPublic
            ? 'default public channel (cannot leave)'
            : (isActive ? 'active — chat will send here' : 'tap to activate'),
      ),
      trailing: isPublic
          ? const Icon(Icons.lock, key: ValueKey<String>('channelLockIcon'))
          : null,
      onTap: onTap,
    );
  }
}

/// Dialog used by the "Create channel" flow. Owns its own
/// [TextEditingController] so it can be disposed when the dialog is
/// dismissed (otherwise the controller leaks until GC, and rapid
/// re-open accumulates in production).
class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog();

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('createChannelDialog'),
      title: const Text('Create channel'),
      content: TextField(
        key: const ValueKey<String>('createChannelNameField'),
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Channel name',
          helperText: 'Letters, digits, dashes, underscores',
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('createChannelCancel'),
          onPressed: () => Navigator.of(context).pop<String>(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('createChannelConfirm'),
          onPressed: () =>
              Navigator.of(context).pop<String>(_controller.text),
          child: const Text('Create'),
        ),
      ],
    );
  }
}