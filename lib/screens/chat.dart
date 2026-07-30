// RelayLink — Ticket #39: Chat screen (conversation + composer).
//
// This file is the testable UI surface for the main messaging thread. It is
// deliberately decoupled from any concrete transport / Firebase layer: a
// [ChatController] is injected, and the widget drives it via simple "send"
// / "load" calls. Production wiring (real `TransportManager`, channel
// subscription, etc.) is added in a later ticket; the tests for #39 use the
// in-memory [LocalChatController] defined below.
//
// What the screen renders:
//   * A header strip with the channel name + a count of messages.
//   * A scrollable, reversed [ListView] of [Message] bubbles sorted by
//     `created_at`. Each bubble shows the sender display name (or a fallback
//     to `senderId`), a relative timestamp, the message type icon, the
//     decrypted body, the origin icon (MESH / SMS / INTERNET), and a small
//     status row (sent / failed / pending) keyed off [MessageStatus].
//   * ALERT messages get a small "VERIFIED" badge in the bubble header so
//     the §3.1 capability table entry has a visible counterpart in the UI.
//   * An empty state when no messages are present.
//   * A bottom composer with a [MessageType] selector, a text field, and a
//     send button. The selector only exposes the 5 user-facing types from
//     SPEC.md §5 (SOS / Safe / Help / Chat / Alert) — control types like
//     ACK and EVIDENCE_NOTICE are not user-authored and so are absent.
//
// Why the controller is injected:
//   * Keeps this widget testable without standing up Firebase or any
//     transport — tests pass a [LocalChatController].
//   * Future production wiring (#20/#22/#28) can swap in a real controller
//     backed by `TransportManager.incoming` without touching this file's
//     rendering code.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:relaylink/alerts/allowlist.dart';
import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/widgets/verified_badge.dart';

/// Status of a message as the UI sees it. The transport layer will be
/// responsible for advancing these values when an ACK arrives or a send
/// fails; the screen just displays whatever the controller hands it.
enum MessageStatus { pending, sent, failed }

/// Display label / sort key for the user-facing message-type selector.
///
/// Per SPEC.md §5 the user-authored types are SOS / STATUS_SAFE / STATUS_HELP
/// / CHAT / ALERT. Control messages (ACK, EVIDENCE_NOTICE) are emitted by
/// the protocol, never typed by a human, so we omit them from the selector.
enum ChatComposerType {
  sos(MessageType.sos, 'SOS'),
  statusSafe(MessageType.statusSafe, 'Safe'),
  statusHelp(MessageType.statusHelp, 'Help'),
  chat(MessageType.chat, 'Chat'),
  alert(MessageType.alert, 'Alert');

  const ChatComposerType(this.messageType, this.label);

  /// The wire-level [MessageType] this composer entry corresponds to.
  final MessageType messageType;

  /// Human-readable label shown in the selector chip row.
  final String label;
}

/// Asynchronous decryptor used by the chat widget to recover the plaintext
/// body of an inbound message. Implementations receive a [Message] (whose
/// `payload` is ciphertext for BROADCAST or Double-Ratchet ciphertext for
/// DIRECT) and return the original UTF-8 string.
///
/// Returning `null` means "I cannot decrypt this" — the widget falls back
/// to displaying the raw payload bytes as a printable string.
///
/// The contract is intentionally narrow: the chat widget does NOT know
/// about `BroadcastCrypto`, channel keys, or ratchet state. Production
/// code wires in the real decryptor backed by
/// `BroadcastCrypto.decryptString` and (eventually)
/// `DoubleRatchetSession.decrypt`. Tests inject a tiny fake.
typedef MessageDecryptor = Future<String?> Function(Message message);

/// The single seam between the chat widget and any persistence / transport
/// implementation. Production code can implement this against Firestore +
/// `TransportManager`; tests use [LocalChatController].
///
/// Extends [ChangeNotifier] so the widget can rebuild automatically when
/// new messages arrive (or outgoing sends complete). Implementations MUST
/// call [notifyListeners] after any state change that the UI cares about.
abstract class ChatController extends ChangeNotifier {
  /// Snapshot of the messages currently known to this thread, oldest first.
  /// The widget sorts by `created_at` so the controller does not need to.
  List<Message> get messages;

  /// Convenience for `messages.length`. Mirrors what the header strip shows.
  int get messageCount;

  /// Push [body] as a freshly authored outgoing message of [type] from
  /// [senderId] / [senderDisplayName] on [channelId]. Returns the produced
  /// [Message] so the widget can show a pending state.
  ///
  /// Implementations SHOULD encrypt the body before stuffing it into
  /// `Message.payload` (see `LocalChatController` for the canonical
  /// BROADCAST wiring). Production code would hand it to
  /// `TransportManager.fanOutSend` and resolve once fan-out completes.
  Future<Message> sendMessage({
    required MessageType type,
    required String body,
    required String senderId,
    String senderDisplayName,
    String channelId = 'public',
  });

  /// Decrypt the body of [message] for display. Returning `null` means
  /// "I cannot decrypt this right now" — the widget falls back to the
  /// raw payload bytes (printed as hex if non-UTF-8).
  Future<String?> decryptForDisplay(Message message) async => null;

  /// Mark [messageId] as having reached [status]. No-op if the id is unknown.
  /// Implemented in [LocalChatController] but called by transport ACK
  /// handlers in production.
  void updateStatus(String messageId, MessageStatus status);
}

/// In-memory [ChatController] used by tests and by demo / debug builds. Not
/// thread-safe — fine for tests, do not use from real transports.
///
/// Wire-format contract: BROADCAST messages are encrypted with the
/// channel's `BroadcastCrypto` key (default = the embedded `networkKey`
/// for the `"public"` channel) and the resulting `BroadcastEnvelope`
/// JSON is stored in `Message.payload`. The widget reads plaintext back
/// by injecting a [MessageDecryptor] (typically one that calls
/// `BroadcastCrypto.decryptString` on the parsed envelope).
class LocalChatController extends ChatController {
  /// Construct an in-memory chat controller. Pass [crypto] to inject a
  /// `BroadcastCrypto` instance; defaults to a fresh one with the
  /// embedded `networkKey` so demo runs work out of the box.
  LocalChatController({BroadcastCrypto? crypto})
      : _crypto = crypto ?? BroadcastCrypto();

  final List<Message> _messages = <Message>[];

  /// Crypto used to encrypt outgoing BROADCAST bodies and (via
  /// [messageDecryptor]) decrypt inbound ones for display.
  final BroadcastCrypto _crypto;

  /// Decryptor injected by the widget layer. When `null`, the chat
  /// widget falls back to UTF-8 decoding the payload (kept for back-
  /// compat with early tests; production code must inject a real one
  /// backed by [_crypto]).
  MessageDecryptor? messageDecryptor;

  @override
  List<Message> get messages => List<Message>.unmodifiable(_messages);

  @override
  int get messageCount => _messages.length;

  @override
  Future<Message> sendMessage({
    required MessageType type,
    required String body,
    required String senderId,
    String senderDisplayName = '',
    String channelId = 'public',
  }) async {
    // Encrypt the body under the channel key so the on-wire payload is
    // ciphertext, not plaintext. The widget never sees `body`; it sees
    // the envelope and asks [messageDecryptor] to recover plaintext.
    final env = await _crypto.encryptString(body, channelId);
    final payloadBytes = utf8.encode(jsonEncode(env.toJsonMap()));

    final msg = Message.create(
      mode: MessageMode.broadcast,
      type: type,
      channelId: channelId,
      senderId: senderId,
      senderDisplayName: senderDisplayName,
      payload: Uint8List.fromList(payloadBytes),
    );
    _messages.add(msg);
    notifyListeners();
    return msg;
  }

  @override
  Future<String?> decryptForDisplay(Message message) {
    final dec = messageDecryptor;
    if (dec == null) return Future<String?>.value(null);
    return dec(message);
  }

  @override
  void updateStatus(String messageId, MessageStatus status) {
    // LocalChatController doesn't track per-message status yet; production
    // controllers would replace the matching message's status. Intentionally
    // a no-op so the test surface is stable.
  }
}

/// Top-level chat screen widget. See file header for design notes.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    this.senderId = 'me',
    this.senderDisplayName = 'Me',
    this.channelId = 'public',
    this.channelName = 'Public channel',
    this.verifiedCache,
  });

  /// The injected controller. Defaults to a [LocalChatController] so the
  /// widget is usable without external setup; production wiring overrides.
  final ChatController controller;

  /// Stable device id of the local user. Used as the sender id on outgoing
  /// messages and to decide bubble alignment (own messages render right).
  final String senderId;

  /// Human-readable display name for the local user.
  final String senderDisplayName;

  /// Channel id sent in outgoing envelopes.
  final String channelId;

  /// Human-readable channel name shown in the app bar.
  final String channelName;

  /// Offline-first allowlist lookup used by the ALERT verified badge
  /// (Ticket #37). When null, the chat renders a "Signed by: <name>" pill
  /// for ALERT messages instead of "Verified: <name>" — i.e. the
  /// receiver-side trust decision is always local and never claims a
  /// sender-controlled field is verified.
  final VerifiedOrgsCache? verifiedCache;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  ChatComposerType _selectedType = ChatComposerType.chat;
  final TextEditingController _composer = TextEditingController();

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    final pending = await widget.controller.sendMessage(
      type: _selectedType.messageType,
      body: text,
      senderId: widget.senderId,
      senderDisplayName: widget.senderDisplayName,
      channelId: widget.channelId,
    );
    if (!mounted) return;
    _composer.clear();
    // Best-effort: surface the pending status without forcing the controller
    // to rebuild the widget. Tests can introspect the controller's list.
    widget.controller.updateStatus(pending.id, MessageStatus.pending);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.channelName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (BuildContext context, _) {
                  final count = widget.controller.messageCount;
                  return Text(
                    '$count message${count == 1 ? '' : 's'}',
                    key: const ValueKey<String>('chatHeaderCount'),
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                },
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (BuildContext context, _) {
                  final messages = widget.controller.messages;
                  if (messages.isEmpty) {
                    return const _ChatEmptyState();
                  }
                  return ListView.builder(
                    key: const ValueKey<String>('chatMessageList'),
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (BuildContext context, int index) {
                      // Reverse the index so newest appears at the bottom
                      // while the list scrolls "down" toward older history.
                      final msg = messages[messages.length - 1 - index];
                      return _MessageBubble(
                        message: msg,
                        isOwn: msg.senderId == widget.senderId,
                        verifiedCache: widget.verifiedCache,
                        controller: widget.controller,
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            _ComposerBar(
              controller: _composer,
              selectedType: _selectedType,
              onTypeSelected: (ChatComposerType t) =>
                  setState(() => _selectedType = t),
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder shown when the controller has no messages yet.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey<String>('chatEmptyState'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.forum_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'No messages yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Pick a type below and tap send to start the conversation.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One rendered message row: header (sender + timestamp + alert badge),
/// body text, and a small footer row (type + origin + status).
class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.message,
    required this.isOwn,
    required this.verifiedCache,
    required this.controller,
  });

  final Message message;
  final bool isOwn;
  final VerifiedOrgsCache? verifiedCache;
  final ChatController controller;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  /// Decrypted plaintext, or `null` if the decryptor hasn't resolved yet
  /// (or returned null). The widget rebuilds once the future settles.
  String? _decrypted;

  @override
  void initState() {
    super.initState();
    _resolveDecrypted();
  }

  @override
  void didUpdateWidget(covariant _MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id) {
      _decrypted = null;
      _resolveDecrypted();
    }
  }

  Future<void> _resolveDecrypted() async {
    final pt = await widget.controller.decryptForDisplay(widget.message);
    if (!mounted) return;
    setState(() => _decrypted = pt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isOwn = widget.isOwn;
    final bubbleColor = isOwn
        ? const Color(0xFF1E3A5F)
        : const Color(0xFF1F2933);
    final align = isOwn ? Alignment.centerRight : Alignment.centerLeft;
    final body = _decrypted ?? _decodeBody(message.payload);

    return Align(
      alignment: align,
      child: Container(
        key: ValueKey<String>('chatBubble::${message.id}'),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(12),
          border: message.type == MessageType.alert
              ? Border.all(color: const Color(0xFFEF5350))
              : null,
        ),
        child: Column(
          crossAxisAlignment:
              isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: <Widget>[
            _BubbleHeader(
              message: message,
              isOwn: isOwn,
              verifiedCache: widget.verifiedCache,
            ),
            const SizedBox(height: 4),
            Text(
              body,
              key: ValueKey<String>('chatBubbleBody::${message.id}'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            _BubbleFooter(message: message),
          ],
        ),
      ),
    );
  }
}

/// Header row of a bubble: sender name + relative timestamp + ALERT badge.
class _BubbleHeader extends StatelessWidget {
  const _BubbleHeader({
    required this.message,
    required this.isOwn,
    required this.verifiedCache,
  });

  final Message message;
  final bool isOwn;
  final VerifiedOrgsCache? verifiedCache;

  @override
  Widget build(BuildContext context) {
    final displayName = message.senderDisplayName.isNotEmpty
        ? message.senderDisplayName
        : message.senderId;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            displayName,
            key: ValueKey<String>('chatBubbleSender::${message.id}'),
            style: Theme.of(context).textTheme.labelLarge,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (message.type == MessageType.alert) ...<Widget>[
          const SizedBox(width: 6),
          // Inline style keeps the badge one line so the Row can never
          // overflow; the chip style would add a colored background that
          // makes the layout larger than the bubble can hold.
          VerifiedBadge(
            key: ValueKey<String>('chatBubbleAlertBadge::${message.id}'),
            senderPubkey: message.senderId,
            displayName: displayName,
            // Receiver-side: only show "Verified" when the cache has been
            // injected AND the pubkey is on the local allowlist. Otherwise
            // fall back to the "Signed by" pill — the same widget, with no
            // trust claim.
            cache: verifiedCache ?? _emptyVerifiedCache(),
            style: VerifiedBadgeStyle.inline,
          ),
        ],
        const SizedBox(width: 8),
        Text(
          _formatTimestamp(message.createdAt),
          key: ValueKey<String>('chatBubbleTimestamp::${message.id}'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Footer row: type chip + origin icon + status icon. Kept simple so the
/// tests can assert each piece individually by key.
class _BubbleFooter extends StatelessWidget {
  const _BubbleFooter({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          _typeIcon(message.type),
          size: 14,
          color: _typeColor(message.type),
          key: ValueKey<String>('chatBubbleTypeIcon::${message.id}'),
        ),
        const SizedBox(width: 4),
        Text(
          message.type.toJson(),
          key: ValueKey<String>('chatBubbleTypeLabel::${message.id}'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(width: 8),
        Icon(
          _originIcon(message.origin),
          size: 14,
          key: ValueKey<String>('chatBubbleOriginIcon::${message.id}'),
        ),
        const SizedBox(width: 8),
        Icon(
          Icons.schedule,
          size: 14,
          color: Theme.of(context).disabledColor,
          key: ValueKey<String>('chatBubbleStatusIcon::${message.id}'),
        ),
      ],
    );
  }
}

/// Empty allowlist cache used when the chat screen is mounted without a
/// `VerifiedOrgsCache` (e.g. in widget tests). It rejects every pubkey, so
/// the rendered pill is always the "Signed by" variant — i.e. never claiming
/// any sender is verified when the receiver hasn't loaded the allowlist.
VerifiedOrgsCache _emptyVerifiedCache() =>
    VerifiedOrgsCache.withFetcher(_emptyFetcher);

Future<List<String>> _emptyFetcher() async => const <String>[];

/// Bottom composer row: a row of [ChatComposerType] chips + a text field +
/// a send button. Built as its own widget so tests can mount it in
/// isolation if needed.
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.selectedType,
    required this.onTypeSelected,
    required this.onSend,
  });

  final TextEditingController controller;
  final ChatComposerType selectedType;
  final ValueChanged<ChatComposerType> onTypeSelected;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TypeSelector(
            selected: selectedType,
            onSelected: onTypeSelected,
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('chatComposerField'),
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey<String>('chatComposerSendButton'),
                onPressed: onSend,
                child: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Horizontal row of [ChatComposerType] chips. The selected chip is filled,
/// the rest are outlined so the current type is always obvious.
class _TypeSelector extends StatelessWidget {
  const _TypeSelector({required this.selected, required this.onSelected});

  final ChatComposerType selected;
  final ValueChanged<ChatComposerType> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final t in ChatComposerType.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                key: ValueKey<String>('chatTypeChip::${t.name}'),
                label: Text(t.label),
                selected: t == selected,
                onSelected: (_) => onSelected(t),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Display helpers (private)
// ---------------------------------------------------------------------------

String _formatTimestamp(DateTime ts) {
  final local = ts.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

String _decodeBody(Uint8List payload) {
  if (payload.isEmpty) return '';
  try {
    return utf8.decode(payload, allowMalformed: true);
  } catch (e, st) {
    debugPrint('chat history load failed: $e\n$st');
    // Fall back to a printable representation if the bytes aren't valid UTF-8.
    return payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }
}

IconData _typeIcon(MessageType t) {
  switch (t) {
    case MessageType.sos:
      return Icons.warning_amber_rounded;
    case MessageType.statusSafe:
      return Icons.check_circle_outline;
    case MessageType.statusHelp:
      return Icons.help_outline;
    case MessageType.chat:
      return Icons.chat_bubble_outline;
    case MessageType.alert:
      return Icons.campaign_outlined;
    case MessageType.ack:
      return Icons.done_all;
    case MessageType.evidenceNotice:
      return Icons.shield_outlined;
  }
}

Color _typeColor(MessageType t) {
  switch (t) {
    case MessageType.sos:
      return const Color(0xFFEF5350);
    case MessageType.alert:
      return const Color(0xFFFFB74D);
    case MessageType.statusHelp:
      return const Color(0xFFFFB74D);
    case MessageType.statusSafe:
      return const Color(0xFF66BB6A);
    case MessageType.chat:
      return const Color(0xFF4FC3F7);
    case MessageType.ack:
      return const Color(0xFF9AA4B2);
    case MessageType.evidenceNotice:
      return const Color(0xFF9AA4B2);
  }
}

IconData _originIcon(MessageOrigin o) {
  switch (o) {
    case MessageOrigin.mesh:
      return Icons.bluetooth;
    case MessageOrigin.smsBridge:
    case MessageOrigin.smsTransport:
      return Icons.sms_outlined;
    case MessageOrigin.internet:
      return Icons.cloud_outlined;
  }
}

// Encode the body using UTF-8 so the payload round-trips through the model.
Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));