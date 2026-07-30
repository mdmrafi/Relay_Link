// RelayLink — Production `ChatController` backed by TransportManager + LocalDb.
//
// This is the seam between the chat widget and the rest of the app:
// every outgoing message is encrypted (BROADCAST via channel key,
// DIRECT via the appropriate `DirectSession`), fan-outed through
// `TransportManager`, and persisted to `LocalDb`. Every incoming
// message coming off any registered transport is also persisted and
// mirrored into the chat's in-memory message list so the UI rebuilds.
//
// The `MessageDecryptor` returned by `bootstrapServices()` dispatches
// on `message.mode` to pick the right crypto path. The widget asks
// for plaintext via `decryptForDisplay(msg)`, which calls the same
// decryptor — so what gets stored is ciphertext, and what gets
// rendered is plaintext.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:relaylink/crypto/broadcast.dart';
import 'package:relaylink/crypto/contact_invite.dart';
import 'package:relaylink/crypto/direct.dart';
import 'package:relaylink/crypto/direct_session_store.dart';
import 'package:relaylink/crypto/identity.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/storage/local_db.dart';
import 'package:relaylink/transport/transport.dart';

import 'chat.dart';

/// Production `ChatController` implementation. See file header.
class RemoteChatController extends ChatController {
  /// Construct a remote-backed controller.
  ///
  /// * [db] — local SQLite for message persistence.
  /// * [transports] — fan-out target. The controller subscribes to
  ///   every transport's `incoming` stream.
  /// * [identity] — local device identity used to fill in sender id /
  ///   sender display name and to bootstrap DIRECT sessions.
  /// * [broadcastCrypto] — shared `BroadcastCrypto` for BROADCAST
  ///   encryption/decryption.
  /// * [directSessionStore] — secure-storage-backed cache of per-peer
  ///   `DirectSession` instances.
  /// * [decryptor] — function that turns a stored `Message.payload`
  ///   back into a UTF-8 plaintext string (returns `null` on failure).
  RemoteChatController({
    required LocalDb db,
    required TransportManager transports,
    required DeviceIdentity identity,
    required BroadcastCrypto broadcastCrypto,
    required DirectSessionStore directSessionStore,
    required Future<String?> Function(Message) decryptor,
  })  : _db = db,
        _transports = transports,
        _identity = identity,
        _broadcastCrypto = broadcastCrypto,
        _directSessionStore = directSessionStore,
        _decryptor = decryptor {
    _subscribeToTransports();
    // Hydrate from disk on next microtask so the constructor stays
    // synchronous (the widget never awaits construction).
    Future<void>.microtask(_hydrate);
  }

  final LocalDb _db;
  final TransportManager _transports;
  final DeviceIdentity _identity;
  final BroadcastCrypto _broadcastCrypto;
  final DirectSessionStore _directSessionStore;
  final Future<String?> Function(Message) _decryptor;

  /// All known messages, oldest first.
  final List<Message> _messages = <Message>[];

  /// Per-message status overrides from the protocol layer (ACK / fail).
  final Map<String, MessageStatus> _statuses = <String, MessageStatus>{};

  /// Active subscriptions to every registered transport's incoming
  /// stream. Cancelled in [dispose].
  final List<StreamSubscription<Message>> _subs = <StreamSubscription<Message>>[];

  /// Set to `true` after [dispose] runs. Guards async hydration /
  /// incoming-message paths that may fire after teardown.
  bool _disposed = false;

  /// One-shot hydration flag — `_hydrate` reads from disk on the first
  /// microtask after construction and never again. This protects
  /// in-memory messages added by [sendMessage] from being cleared by
  /// a race with the hydration microtask.
  bool _hydrated = false;

  @override
  List<Message> get messages => List<Message>.unmodifiable(_messages);

  @override
  int get messageCount => _messages.length;

  @override
  Future<String?> decryptForDisplay(Message message) => _decryptor(message);

  @override
  void updateStatus(String messageId, MessageStatus status) {
    if (_statuses[messageId] == status) return;
    _statuses[messageId] = status;
    notifyListeners();
  }

  /// Release the transport subscriptions. Call from `State.dispose`.
  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Outgoing
  // ---------------------------------------------------------------------------

  @override
  Future<Message> sendMessage({
    required MessageType type,
    required String body,
    required String senderId,
    String senderDisplayName = '',
    String channelId = 'public',
  }) async {
    final localId = senderId.isEmpty ? _identity.senderId : senderId;
    final localName = senderDisplayName.isEmpty ? '' : senderDisplayName;

    final msg = await _buildOutgoing(
      type: type,
      body: body,
      channelId: channelId,
      senderId: localId,
      senderDisplayName: localName,
    );
    _messages.add(msg);
    await _db.insertMessage(msg);
    notifyListeners();

    final errors = await _transports.fanOutSend(msg);
    // `fanOutSend` returns a list parallel to `transports` where `null`
    // means either "skipped (unavailable)" or "sent successfully". A
    // non-null entry is an error. We treat "at least one null" as a
    // success because the only way to get a null entry with a
    // registered transport is for that transport's `send` to have
    // returned without throwing.
    final anySucceeded = errors.isEmpty || errors.any((e) => e == null);
    updateStatus(
      msg.id,
      anySucceeded ? MessageStatus.sent : MessageStatus.failed,
    );
    return msg;
  }

  /// Build an outgoing `Message` for the given body, encrypting the
  /// body under the channel key (BROADCAST) via [BroadcastCrypto].
  Future<Message> _buildOutgoing({
    required MessageType type,
    required String body,
    required String channelId,
    required String senderId,
    required String senderDisplayName,
  }) async {
    final payload = await encryptBroadcast(body: body, channelId: channelId);
    return Message.create(
      mode: MessageMode.broadcast,
      type: type,
      channelId: channelId,
      senderId: senderId,
      senderDisplayName: senderDisplayName,
      payload: payload,
    );
  }

  // ---------------------------------------------------------------------------
  // Incoming
  // ---------------------------------------------------------------------------

  void _subscribeToTransports() {
    for (final t in _transports.transports) {
      _subs.add(t.incoming.listen(_onIncoming, onError: (Object e, StackTrace _) {
        // Swallow per-transport errors so one broken transport doesn't
        // kill the rest of the chat pipeline.
      }));
    }
  }

  Future<void> _onIncoming(Message msg) async {
    if (_disposed) return;
    // Skip messages we ourselves sent — we already added them above.
    if (msg.senderId == _identity.senderId) {
      // Persist for history but skip the in-memory mirror to avoid dupes.
      try {
        await _db.insertMessage(msg);
      } catch (_) {/* swallow post-dispose */}
      return;
    }
    // Dedup: if we already have a message with this id, ignore.
    if (_messages.any((m) => m.id == msg.id)) return;
    _messages.add(msg);
    try {
      await _db.insertMessage(msg);
    } catch (_) {/* swallow post-dispose */}
    if (_disposed) return;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Hydration
  // ---------------------------------------------------------------------------

  Future<void> _hydrate() async {
    if (_disposed) return;
    if (_hydrated) return;
    _hydrated = true;
    final persisted = await _db.listMessages();
    if (_disposed) return;
    // Only populate from disk if the in-memory mirror is empty. This
    // guards against a race where `sendMessage` adds a message before
    // the hydration microtask runs.
    if (_messages.isEmpty) {
      _messages.addAll(persisted.reversed);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Public helpers (used by the Contacts screen + dev tools)
  // ---------------------------------------------------------------------------

  /// Build and persist a DIRECT message to [recipientDeviceId]. Encrypts
  /// the body via the peer's `DirectSession` (loaded from the secure-
  /// storage-backed `DirectSessionStore`), packages the ciphertext +
  /// ratchet header into a `Message`, fans it out, and stores the
  /// message in the DB. Returns the stored `Message`.
  ///
  /// Throws [StateError] if no session is paired with [recipientDeviceId].
  Future<Message> sendDirectMessage({
    required String recipientDeviceId,
    required MessageType type,
    required String body,
  }) async {
    final session = await _directSessionStore.get(recipientDeviceId);
    if (session == null) {
      throw StateError(
        'No DirectSession for $recipientDeviceId — pair first',
      );
    }
    final dm = await session.encrypt(body);
    final ratchetHeader = _encodeRatchetHeader(dm.ratchetHeader);
    final msg = Message.create(
      mode: MessageMode.direct,
      type: type,
      channelId: '',
      senderId: _identity.senderId,
      senderDisplayName: '',
      recipientId: recipientDeviceId,
      payload: Uint8List.fromList(dm.ciphertext),
      ratchetHeader: ratchetHeader,
    );
    _messages.add(msg);
    await _db.insertMessage(msg);
    notifyListeners();
    final errors = await _transports.fanOutSend(msg);
    if (errors.isNotEmpty && errors.every((e) => e != null)) {
      updateStatus(msg.id, MessageStatus.failed);
    } else {
      updateStatus(msg.id, MessageStatus.sent);
    }
    return msg;
  }

  /// Persist the freshly-updated session back to the store. Called
  /// after every DIRECT encrypt/decrypt because the chain keys advance.
  Future<void> persistDirectSession(String deviceId, DirectSession session) async {
    await _directSessionStore.put(deviceId, session);
  }

  /// Serialize a `DirectRatchetHeader` to bytes for inclusion in the
  /// `Message.ratchetHeader` field. 5 bytes: 1 byte direction + 4 bytes
  /// big-endian msg index.
  static Uint8List _encodeRatchetHeader(DirectRatchetHeader h) {
    final out = Uint8List(5);
    out[0] = h.directionByte;
    final b = ByteData.sublistView(out, 1);
    b.setUint32(0, h.msgIndex, Endian.big);
    return out;
  }

  /// Inverse of [_encodeRatchetHeader].
  static DirectRatchetHeader decodeRatchetHeader(List<int> bytes) {
    if (bytes.length != 5) {
      throw FormatException(
        'DirectRatchetHeader must be 5 bytes, got ${bytes.length}',
      );
    }
    final b = ByteData.sublistView(Uint8List.fromList(bytes), 1);
    return DirectRatchetHeader(
      msgIndex: b.getUint32(0, Endian.big),
      directionByte: bytes[0],
    );
  }

  /// Encrypt a plaintext string for the BROADCAST channel identified by
  /// [channelId]. Public so the dev loopback tool can drive the same
  /// path that production uses.
  Future<Uint8List> encryptBroadcast({
    required String body,
    required String channelId,
  }) async {
    final env = await _broadcastCrypto.encryptString(body, channelId);
    return Uint8List.fromList(utf8.encode(jsonEncode(env.toJsonMap())));
  }

  /// Pair this device with the peer described by [invite]. Derives the
  /// shared root, creates a `DirectSession`, persists it, and stores
  /// the resulting `ContactRecord` in `LocalDb.contacts` so the
  /// Contacts screen can resolve the device id later.
  ///
  /// Returns the new `DirectSession`.
  Future<DirectSession> pairWithInvite({
    required ContactInvite invite,
    required bool isInitiator,
    String? phoneNumber,
  }) async {
    final session = await ContactInviteCodec.bootstrapSession(
      self: _identity,
      invite: invite,
      isInitiator: isInitiator,
    );
    await _directSessionStore.put(invite.deviceId, session);
    return session;
  }
}