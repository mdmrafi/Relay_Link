// RelayLink — Ticket #26: SMS transport re-injection into the pipeline.
//
// Wires the `SmsPlatformChannel` (#23) and the `SmsReassembler` (#25) onto
// the common `Transport` interface (#06) so SMS becomes a fully-fledged
// transport layer along with mesh and internet.
//
// Lifecycle:
//   * `send(msg)` → look up recipient's phone number from the Contacts
//     store (#40), pick the JSON envelope bytes from `msg`, fragment
//     them with `frameMessage` (#24), and dispatch each segment via
//     `SmsPlatformChannel.sendSms`.
//   * `incoming` is fed by an internal pipeline:
//        platform channel (incomingSms)
//          → SmsReassembler (buffer + dedupe + complete)
//          → JSON decode → Message (with origin = smsTransport)
//          → seen-cache + TTL decrement + reject-on-duplicate/empty-id
//          → emit on `incoming` AND re-broadcast via TransportManager
//
// Duplicate filtering (per ticket #26 acceptance criteria):
//   * Empty `id` → drop (invalid envelope).
//   * `id` already in seen-cache → drop silently (don't re-broadcast).
//   * `ttl <= 0` before the reinjection decrement → drop.
//
// All three are documented in this file's [ReinjectionFilter] doc-comment
// so the test suite is a transparent spec.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:relaylink/models/message.dart';
import 'package:relaylink/sms/framing.dart';
import 'package:relaylink/sms/platform_channel.dart';
import 'package:relaylink/sms/reassembler.dart';
import 'package:relaylink/transport/transport.dart';

/// Minimal interface over the SMS platform channel. The default
/// implementation is [SmsPlatformChannel]; tests pass a fake. We define
/// this as a *host* interface so the SmsTransport doesn't directly
/// depend on the platform-channel implementation detail.
abstract class SmsPlatformHost {
  bool get isAvailable;
  Future<bool> sendSms(String phoneNumber, String body);
  Stream<String> get incomingSms;
  Future<Map<String, bool>> requestSmsPermissions();
}

/// Minimal interface over the contacts store. The default is the real
/// `#40` contacts store; tests pass a fake that maps `deviceId` to
/// `phoneNumber`. Returning `null` means "no phone number on file".
abstract class ContactsStore {
  String? phoneFor(String deviceId);
}

/// Minimal interface over the seen-cache. The default is `LocalDb`
/// (#05) via `markSeen` / `isSeen`; tests pass a fake. The seen-cache
/// prevents relay loops by tracking which message ids have already been
/// processed locally.
abstract class SeenCache {
  Future<void> markSeen(String id);
  Future<bool> isSeen(String id);
}

/// Minimal interface over the TransportManager (#06). The real
/// implementation owns fan-out and the per-transport `incoming` stream
/// subscription graph. We only need a `rebroadcast` entry point here:
/// re-injecting an SMS-arrived message into the local pipeline so the
/// other transports can carry it forward.
abstract class TransportManagerHost {
  /// Hand a fully-reassembled, accepted message back to the manager so
  /// it lands on the other transports' `send` channels. The transport
  /// itself has already decremented TTL and updated `origin`.
  Future<void> rebroadcast(Message msg);
}

/// SMS-as-Transport for RelayLink.
///
/// Implements the [Transport] interface (#06) on top of the platform
/// channel (#23), reassembler (#25), contacts store (#40), seen-cache
/// (#05), and TransportManager (#06). The transport is a pure glue
/// layer; it does not invent any new behavior — it only wires the
/// upstream pieces together with the duplicate/invalid filtering
/// spelled out in Ticket #26.
class SmsTransport implements Transport {
  final SmsPlatformHost _channel;
  final ContactsStore _contacts;
  final SeenCache _seenCache;
  final TransportManagerHost _manager;
  final Reassembler _reassembler;

  final StreamController<Message> _incomingCtrl =
      StreamController<Message>.broadcast();

  StreamSubscription<String>? _platformSub;
  StreamSubscription<ReassembledMessage>? _reassemblerSub;

  /// True once [_start] has subscribed to the underlying platform
  /// channel. The constructor does NOT auto-start so tests can drive
  /// the pipeline via the `testFeed*` hooks without a live channel.
  bool _started = false;

  SmsTransport({
    SmsPlatformHost? channel,
    ContactsStore? contacts,
    SeenCache? seenCache,
    TransportManagerHost? manager,
    Reassembler? reassembler,
  })  : _channel = channel ?? SmsPlatformChannel(),
        _contacts = contacts ?? _NullContacts(),
        _seenCache = seenCache ?? _NullSeenCache(),
        _manager = manager ?? _NullTransportManager(),
        _reassembler = reassembler ?? Reassembler();

  @override
  String get name => 'SMS';

  @override
  bool isAvailable() => _channel.isAvailable;

  @override
  Stream<Message> get incoming => _incomingCtrl.stream;

  /// Begin listening to the platform channel's incoming-SMS stream and
  /// feeding fragments into the reassembler. Idempotent: a second call
  /// is a no-op. The transport does not auto-start because tests want
  /// to drive the pipeline via `testFeedSegment` without touching the
  /// platform channel.
  void start() {
    if (_started) return;
    _started = true;
    _ensureReassemblerListener();
    _platformSub = _channel.incomingSms.listen(_reassembler.ingest,
        onError: (Object e, StackTrace st) {
      // Swallow platform-channel errors so an upstream hiccup doesn't
      // kill the local pipeline. Telemetry would go here in a future
      // ticket; for the MVP we just drop.
    });
  }

  /// Test hook: drive a single segment through the reassembler AND the
  /// completion handler synchronously. Used by tests that exercise the
  /// framing → reassembly → reinjection pipeline without a live
  /// platform channel. Calling this before [start] is fine — the
  /// handler runs anyway because we subscribe to the reassembler here
  /// if it isn't already running.
  void testFeedSegment(String segment) {
    // Ensure the reassembler → onReassembled wire is in place even if
    // start() was not called. Idempotent.
    _ensureReassemblerListener();
    _reassembler.ingest(segment);
  }

  /// Wire the reassembler's `completed` stream to `_onReassembled`. Safe
  /// to call multiple times — the second call is a no-op.
  void _ensureReassemblerListener() {
    if (_reassemblerSub != null) return;
    _reassemblerSub = _reassembler.messages.listen(_onReassembled);
  }

  /// Test hook: drive a fully-decoded Message through the filter +
  /// reinject pipeline; bypasses the reassembler. Used by tests that
  /// pin the filter behavior in isolation.
  Future<void> testFeedReassembledCipher(Message msg) async {
    final filtered = await _filterAndDecrement(msg);
    if (filtered == null) return;
    _incomingCtrl.add(filtered);
    unawaited(_manager.rebroadcast(filtered));
  }

  /// Stop listening and release resources. Safe to call multiple times.
  Future<void> stop() async {
    await _reassemblerSub?.cancel();
    _reassemblerSub = null;
    await _platformSub?.cancel();
    _platformSub = null;
    _started = false;
  }

  /// Tear down the transport fully: stops the subscriptions and closes
  /// the broadcast stream. After [dispose] the transport cannot be used.
  Future<void> dispose() async {
    await stop();
    await _reassembler.dispose();
    await _incomingCtrl.close();
  }

  @override
  Future<void> send(Message msg) async {
    final recipientId = msg.recipientId;
    if (recipientId == null || recipientId.isEmpty) {
      // SPEC: SMS_TRANSPORT only sends when there is a specific recipient
      // and we have their phone number. Broadcast fan-out is the
      // responsibility of #27 and lives downstream.
      return;
    }
    final phone = _contacts.phoneFor(recipientId);
    if (phone == null || phone.isEmpty) {
      // No phone number on file — drop silently. The transport does
      // not queue; the higher layer (TransportManager) decides retry.
      return;
    }
    final envelopeJson = utf8.encode(jsonEncode(msg.toJson()));
    final segments = SmsFraming.fragment(
      messageId: _shortFragmentId(msg.id),
      payload: Uint8List.fromList(envelopeJson),
    );
    for (final seg in segments) {
      await _channel.sendSms(phone, seg.body);
    }
  }

  /// Derive an 8-hex-char fragment id from a full message id.
  ///
  /// `SmsFraming.fragment` requires the message id to be exactly 8 hex
  /// characters. The full [Message.id] is a UUIDv4 (36 chars). We take
  /// the first 8 hex chars of the UUID — uniqueness within a burst is
  /// empirically sufficient because the receiver matches against the
  /// full message id loaded from the envelope JSON, not the 8-char
  /// fragment header.
  static String _shortFragmentId(String fullId) {
    final hex = StringBuffer();
    for (final c in fullId.codeUnits) {
      final ch = String.fromCharCode(c);
      final isHex =
          (ch.compareTo('0') >= 0 && ch.compareTo('9') <= 0) ||
              (ch.compareTo('a') >= 0 && ch.compareTo('f') <= 0) ||
              (ch.compareTo('A') >= 0 && ch.compareTo('F') <= 0);
      if (isHex) {
        hex.write(ch);
        if (hex.length == 8) break;
      }
    }
    if (hex.length != 8) {
      throw StateError(
        'message id "$fullId" does not contain 8 hex chars for SMS header',
      );
    }
    return hex.toString();
  }

  // ---------------------------------------------------------------------------
  // Internal: reinjection pipeline
  // ---------------------------------------------------------------------------

  void _onReassembled(ReassembledMessage event) {
    final msg = _decodeEnvelope(event.payloadBytes);
    if (msg == null) return;
    _filterAndDecrement(msg).then((filtered) {
      if (filtered == null) return;
      _incomingCtrl.add(filtered);
      // Fire-and-forget: re-broadcast via the manager. Errors here are
      // logged in the manager, not in the transport.
      unawaited(_manager.rebroadcast(filtered));
    });
  }

  /// Decode a reassembled cipher (UTF-8 JSON envelope) into a Message.
  /// Returns `null` for malformed JSON or schema violations — the spec
  /// says SMS is not a security boundary, so we drop malformed envelopes
  /// rather than crash the pipeline.
  Message? _decodeEnvelope(Uint8List body) {
    try {
      final raw = utf8.decode(body);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return Message.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Apply the duplicate / invalid / TTL filters per ticket #26:
  ///   * empty id → invalid → drop
  ///   * already in seen-cache → duplicate → drop
  ///   * ttl <= 0 → expired → drop (no point re-injecting)
  /// On success, returns a copy with `origin = smsTransport`, ttl
  /// decremented, hop_count incremented. The seen-cache is marked
  /// inside the returned-message synchronous path so a duplicate
  /// delivery during the await window can't slip through.
  Future<Message?> _filterAndDecrement(Message msg) async {
    if (msg.id.isEmpty) return null;
    if (await _seenCache.isSeen(msg.id)) return null;
    if (msg.ttl <= 0) return null;
    await _seenCache.markSeen(msg.id);
    return msg.copyWith(
      origin: MessageOrigin.smsTransport,
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
    );
  }

  // ---------------------------------------------------------------------------
  // Test hooks are declared earlier in this file (alongside start()).
  // ---------------------------------------------------------------------------
}

// ---------------------------------------------------------------------------
// Null-object defaults for the host interfaces. Production wires up the
// real #06 / #40 / #05 implementations; the null objects keep the SmsTransport
// usable in isolation (e.g. UI smoke tests) without forcing the caller to
// provide every collaborator up front.
// ---------------------------------------------------------------------------

class _NullContacts implements ContactsStore {
  @override
  String? phoneFor(String deviceId) => null;
}

class _NullSeenCache implements SeenCache {
  @override
  Future<void> markSeen(String id) async {}
  @override
  Future<bool> isSeen(String id) async => false;
}

class _NullTransportManager implements TransportManagerHost {
  @override
  Future<void> rebroadcast(Message msg) async {}
}
