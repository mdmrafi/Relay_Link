// RelayLink — Minimal InternetTransport (Ticket #20 minimal compatible stub).
//
// This file implements a thin abstraction layer over Firestore so the
// Gateway relay (Ticket #22) can push and pull messages without a hard
// dependency on the real Firestore SDK in unit tests.
//
// ARCHITECTURE:
//   * `FirestoreGateway` is the low-level interface — `pushMessage`,
//     `pullBroadcastSince`, `pullDirectFor`. The real implementation
//     (Ticket #20) will wrap `cloud_firestore`; a `FakeFirestoreGateway`
//     in `test/` backs the Gateway relay's tests.
//   * `InternetTransport` is a [Transport] that uses a [FirestoreGateway]
//     to push outbound messages and pull inbound ones on a 30s poll loop
//     per SPEC §10 / #20.
//
// The pull loop runs ONLY while [GatewayRelay] has the gateway toggle ON.
// (See [InternetTransport.pollStop] / [InternetTransport.pollStart].)
// Direct Internet Messaging for OWN traffic uses the same transport but
// is wired in by Ticket #20 — the Gateway relay does not depend on it.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../backend/firebase.dart';
import '../backend/schemas.dart';
import '../models/message.dart';
import 'transport.dart';

/// Low-level Firestore operations needed by the relay.
///
/// Ticket #20 owns the production implementation. Tests inject a fake.
abstract class FirestoreGateway {
  /// Push one BROADCAST or DIRECT message into the appropriate relay
  /// collection. Throws [FirestoreGatewayUnavailable] if Firestore is
  /// not initialized.
  Future<void> pushMessage(Message msg);

  /// Pull every BROADCAST message with `created_at > [since]` for any
  /// channel in [channelIds] (the channels the local device has an
  /// interest in). Empty `channelIds` pulls all channels the gateway
  /// knows about.
  Future<List<Message>> pullBroadcastSince(
    DateTime since, {
    Set<String> channelIds = const <String>{},
  });

  /// Pull every DIRECT message addressed to [recipientId] with
  /// `created_at > [since]`.
  Future<List<Message>> pullDirectFor(
    String recipientId,
    DateTime since,
  );
}

/// Thrown by [FirestoreGateway.pushMessage] when Firestore isn't
/// initialized. Lets the relay silently no-op without crashing.
class FirestoreGatewayUnavailable implements Exception {
  const FirestoreGatewayUnavailable();
  @override
  String toString() =>
      'FirestoreGatewayUnavailable: FirebaseBackend is not initialized';
}

/// Real Firestore implementation of [FirestoreGateway]. Will be wired into
/// the app by Ticket #20; here for completeness so the file is self-
/// contained and the abstract class isn't orphaned.
class RealFirestoreGateway implements FirestoreGateway {
  /// Default retention window. Per SPEC §10, relay entries auto-expire
  /// after a few hours — the gateway writes `expires_at` accordingly and
  /// the Firestore TTL policy deletes them.
  static const Duration defaultTtl = Duration(hours: 2);

  /// How long the gateway remembers the "last pulled" cursor so the next
  /// pull only fetches deltas.
  static const Duration pullLookbackWindow = Duration(minutes: 5);

  final Duration _ttl;

  RealFirestoreGateway(this._ttl);

  @override
  Future<void> pushMessage(Message msg) async {
    if (!FirebaseBackend.isInitialized) {
      throw const FirestoreGatewayUnavailable();
    }
    final fs = FirebaseBackend.firestore;
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(_ttl);

    final json = msg.toJson();
    // Add the relay-collection-specific fields.
    json[RelayMessageDoc.expiresAt] =
        Timestamp.fromDate(expiresAt).millisecondsSinceEpoch;

    final docPath = msg.mode == MessageMode.broadcast
        ? FirebaseBackend.relayMessagesPath(msg.channelId)
        : FirebaseBackend.relayDirectMessagesPath(
            msg.recipientId ?? '',
          );

    await fs
        .collection(docPath)
        .doc(msg.id)
        .set(json, SetOptions(merge: true));
  }

  @override
  Future<List<Message>> pullBroadcastSince(
    DateTime since, {
    Set<String> channelIds = const <String>{},
  }) async {
    if (!FirebaseBackend.isInitialized) {
      throw const FirestoreGatewayUnavailable();
    }
    final fs = FirebaseBackend.firestore;
    // The cursor is `since - pullLookbackWindow` so we don't miss messages
    // whose server write timestamp trails the local clock.
    final cursor = Timestamp.fromDate(
      since.subtract(pullLookbackWindow),
    );
    final channels = channelIds.isEmpty
        ? <String>{'public'}
        : channelIds;
    final out = <Message>[];
    for (final ch in channels) {
      final qs = await fs
          .collection(FirebaseBackend.relayMessagesPath(ch))
          .where(RelayMessageDoc.createdAt, isGreaterThan: cursor)
          .get();
      for (final doc in qs.docs) {
        final data = doc.data();
        out.add(Message.fromJson(_stripServerFields(data)));
      }
    }
    return out;
  }

  @override
  Future<List<Message>> pullDirectFor(
    String recipientId,
    DateTime since,
  ) async {
    if (!FirebaseBackend.isInitialized) {
      throw const FirestoreGatewayUnavailable();
    }
    final fs = FirebaseBackend.firestore;
    final cursor = Timestamp.fromDate(since.subtract(pullLookbackWindow));
    final qs = await fs
        .collection(FirebaseBackend.relayDirectMessagesPath(recipientId))
        .where(RelayMessageDoc.createdAt, isGreaterThan: cursor)
        .get();
    return qs.docs
        .map((doc) => Message.fromJson(_stripServerFields(doc.data())))
        .toList(growable: false);
  }

  /// Strip server-managed fields (e.g. `expires_at`) so the message
  /// decoder doesn't reject the document. The relay doesn't use those
  /// fields on the client side — Firestore TTL deletes the docs.
  Map<String, dynamic> _stripServerFields(Map<String, dynamic> json) {
    final out = Map<String, dynamic>.from(json);
    out.remove(RelayMessageDoc.expiresAt);
    return out;
  }
}

/// [Transport] over Firestore. Pushes outbound messages and polls
/// inbound ones on a configurable interval.
///
/// The Gateway relay (`lib/features/gateway/relay.dart`) drives the
/// poll loop ONLY while the gateway toggle is ON. Direct internet
/// messaging for own traffic uses a different wiring (Ticket #20) that
/// does not depend on the toggle.
class InternetTransport implements Transport {
  @override
  final String name = 'internet';

  final FirestoreGateway _gateway;

  /// Our own sender id (used for `pullDirectFor`).
  final String _ownSenderId;

  /// Poll interval for inbound messages.
  final Duration _pollInterval;

  /// Channels the local device is interested in (for BROADCAST pulls).
  final Set<String> _channelIds;

  /// Broadcast stream of messages pulled from Firestore.
  final StreamController<Message> _incomingController =
      StreamController<Message>.broadcast();

  Timer? _pollTimer;

  /// Constructor for production: takes a [RealFirestoreGateway] and the
  /// device's own sender id.
  InternetTransport({
    required FirestoreGateway gateway,
    required String ownSenderId,
    Set<String> channelIds = const <String>{'public'},
    Duration pollInterval = const Duration(seconds: 30),
  })  : _gateway = gateway,
        _ownSenderId = ownSenderId,
        _channelIds = channelIds,
        _pollInterval = pollInterval;

  /// Whether the device has internet connectivity. The real
  /// implementation should check the platform connectivity plugin; for
  /// the relay's tests, [setAvailable] toggles this directly.
  bool _available = false;

  /// Test/dev hook: pretend the device just lost / regained internet.
  void setAvailable(bool v) {
    _available = v;
  }

  @override
  bool isAvailable() => _available && _pollTimer != null;

  @override
  Future<void> send(Message msg) async {
    if (!_available) {
      throw TransportUnavailableException(name);
    }
    await _gateway.pushMessage(msg);
  }

  @override
  Stream<Message> get incoming => _incomingController.stream;

  /// Start the poll loop. Idempotent.
  void pollStart() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    // Fire one immediately so the user doesn't wait a full interval for
    // the first pull on toggle-on.
    _pollOnce();
  }

  /// Stop the poll loop. Idempotent.
  void pollStop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollOnce() async {
    if (!_available) return;
    try {
      final now = DateTime.now().toUtc();
      final broadcast = await _gateway.pullBroadcastSince(
        now,
        channelIds: _channelIds,
      );
      for (final m in broadcast) {
        _incomingController.add(m);
      }
      final directs = await _gateway.pullDirectFor(_ownSenderId, now);
      for (final m in directs) {
        _incomingController.add(m);
      }
    } on FirestoreGatewayUnavailable {
      // Local-only mode — silently no-op.
    } catch (_) {
      // Pull failures are non-fatal; the next tick will retry.
    }
  }

  /// Free resources.
  Future<void> dispose() async {
    pollStop();
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }
}