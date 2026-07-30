// RelayLink — Direct internet messaging (Ticket #20).
//
// Production Transport over Firestore for OWN traffic. Pushes outbound
// messages to `relay/{channel_id}/messages` (BROADCAST) or
// `relay_direct/{recipient_id}/messages` (DIRECT), and polls every 30s
// when the device has internet. Auto-active, no user toggle.
//
// ARCHITECTURE
//   * `FirestoreGateway` is the low-level interface — `pushMessage`,
//     `pullBroadcastSince`, `pullDirectFor`. The production implementation
//     wraps `cloud_firestore`; tests inject a fake.
//   * `InternetTransport` is a [Transport] that uses a [FirestoreGateway]
//     to push outbound messages and poll inbound ones on the configured
//     interval.
//   * Pulled messages are filtered (seen-cache + ttl) and re-broadcast via
//     an `InternetTransportManagerHost.rebroadcast` hook so they re-enter
//     the local pipeline exactly like SMS-arrived messages per SPEC.md §9.
//
// TWO INDEPENDENT POLL LOOPS
//   * `start()` / `stop()` — the OWN-TRAFFIC auto-poll loop. Activates
//     when [isAvailable] is true; gracefully pauses when connectivity
//     drops. This is the production behavior per SPEC.md §10.
//   * `pollStart()` / `pollStop()` — the GATEWAY poll loop driven by
//     `lib/features/gateway/relay.dart` while the user's gateway toggle is
//     ON. Kept for Ticket #22 compatibility. Gateway-relay messages are
//     emitted raw on `incoming` so the relay orchestrator can apply its
//     own dedup/hop rules; the auto-poll applies its own (different) rules.
//
// SAFETY (auto-poll pull-side, per spec §9 "received-via-SMS messages
// re-enter normal pipeline" — same applies here):
//   * Empty id → drop (invalid envelope).
//   * Already in seen-cache → drop (no double rebroadcast).
//   * ttl <= 0 → drop (no point re-injecting).

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../backend/firebase.dart';
import '../backend/schemas.dart';
import '../models/message.dart';
import 'transport.dart';

// We use explicit `parameter: this._field = ...` initializers instead of
// `this._field` initializing formals because the public parameter names
// (`gateway`, `ownSenderId`) read more clearly at the call site than the
// underscored field names would.
// ignore_for_file: prefer_initializing_formals

/// Low-level Firestore operations needed by the transport.
///
/// Production wires up [RealFirestoreGateway]; tests inject a fake.
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
/// initialized. Lets the transport silently no-op without crashing.
class FirestoreGatewayUnavailable implements Exception {
  const FirestoreGatewayUnavailable();
  @override
  String toString() =>
      'FirestoreGatewayUnavailable: FirebaseBackend is not initialized';
}

/// Minimal interface over the seen-cache. Production wires up
/// `LocalDbSeenCache`; tests pass a fake. The `Internet` prefix avoids a
/// name collision with the same-named interface in `lib/features/gateway/relay.dart`
/// (which has the same shape but slightly different method names).
abstract class InternetSeenCache {
  Future<bool> isSeen(String id);
  Future<void> markSeen(String id);
}

/// Minimal interface over the TransportManager. Production wires up the
/// real [TransportManager]; tests pass a fake. We only need a `rebroadcast`
/// entry point: re-injecting an internet-arrived message into the local
/// pipeline so the other transports can carry it forward.
abstract class InternetTransportManagerHost {
  /// Hand an accepted, TTL-decremented message back to the manager so it
  /// lands on the other transports' `send` channels.
  Future<void> rebroadcast(Message msg);
}

/// Real Firestore implementation of [FirestoreGateway].
class RealFirestoreGateway implements FirestoreGateway {
  /// Retention window per SPEC §10. The gateway writes `expires_at` so
  /// the Firestore TTL policy auto-deletes the document.
  static const Duration defaultTtl = Duration(hours: 2);

  /// Lookback window for the pull cursor so we don't miss messages whose
  /// server timestamp trails the local clock.
  static const Duration pullLookbackWindow = Duration(minutes: 5);

  final Duration _ttl;

  RealFirestoreGateway([this._ttl = defaultTtl]);

  @override
  Future<void> pushMessage(Message msg) async {
    if (!FirebaseBackend.isInitialized) {
      throw const FirestoreGatewayUnavailable();
    }
    final fs = FirebaseBackend.firestore;
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(_ttl);

    final json = msg.toJson();
    json[RelayMessageDoc.expiresAt] =
        Timestamp.fromDate(expiresAt).millisecondsSinceEpoch;

    final docPath = msg.mode == MessageMode.broadcast
        ? FirebaseBackend.relayMessagesPath(msg.channelId)
        : FirebaseBackend.relayDirectMessagesPath(msg.recipientId ?? '');

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
    final cursor =
        Timestamp.fromDate(since.subtract(pullLookbackWindow));
    final channels = channelIds.isEmpty ? <String>{'public'} : channelIds;
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
    final cursor =
        Timestamp.fromDate(since.subtract(pullLookbackWindow));
    final qs = await fs
        .collection(FirebaseBackend.relayDirectMessagesPath(recipientId))
        .where(RelayMessageDoc.createdAt, isGreaterThan: cursor)
        .get();
    return qs.docs
        .map((doc) => Message.fromJson(_stripServerFields(doc.data())))
        .toList(growable: false);
  }

  /// Strip server-managed fields (e.g. `expires_at`) so the message
  /// decoder doesn't reject the document.
  Map<String, dynamic> _stripServerFields(Map<String, dynamic> json) {
    final out = Map<String, dynamic>.from(json);
    out.remove(RelayMessageDoc.expiresAt);
    return out;
  }
}

/// [Transport] over Firestore for OWN internet traffic.
///
/// Pushes outbound messages and polls inbound ones. The auto-poll runs
/// while [isAvailable] is true and is driven by [start]. The Gateway
/// relay (#22) drives an additional timer via [pollStart]/[pollStop]
/// for gateway-mode traffic.
class InternetTransport implements Transport {
  @override
  final String name = 'internet';

  final FirestoreGateway _gateway;
  final String _ownSenderId;
  final Duration _pollInterval;
  final Set<String> _channelIds;
  final InternetSeenCache _seenCache;
  final InternetTransportManagerHost _manager;

  final StreamController<Message> _incomingController =
      StreamController<Message>.broadcast();

  /// Timer for the OWN-TRAFFIC auto-poll (started via [start]).
  Timer? _autoPollTimer;

  /// Timer for the GATEWAY poll (started via [pollStart]). Kept
  /// separate from the auto-poll so the two flows don't fight.
  Timer? _gatewayPollTimer;

  /// When true, the device has internet. Drives [isAvailable] and
  /// gates the auto-poll loop. Default false (start offline — the app
  /// flips this once connectivity is detected).
  bool _hasInternet = false;

  /// True between [start] and [stop]. The orchestrator doesn't have to
  /// call these — but they're public so the app shell can opt into
  /// lifecycle management if desired.
  bool _started = false;

  /// Constructor for production: takes a [FirestoreGateway], the device's
  /// own sender id, an [InternetSeenCache], and an
  /// [InternetTransportManagerHost]. The two collaborator parameters are
  /// optional — the transport provides null-object defaults so it can be
  /// used in isolation (e.g. the gateway relay's tests).
  InternetTransport({
    required FirestoreGateway gateway,
    required String ownSenderId,
    Set<String> channelIds = const <String>{'public'},
    Duration pollInterval = const Duration(seconds: 30),
    InternetSeenCache? seenCache,
    InternetTransportManagerHost? manager,
  })  : _gateway = gateway,
        _ownSenderId = ownSenderId,
        _channelIds = channelIds,
        _seenCache = seenCache ?? _NoSeenCache(),
        _manager = manager ?? _NoTransportManager(),
        _pollInterval = pollInterval;

  /// Test/dev hook: pretend the device just lost / regained internet.
  /// Production code should set this from a connectivity listener; for
  /// the hackathon demo we leave the integration to the app shell.
  void setAvailable(bool v) {
    _hasInternet = v;
  }

  /// True iff the device currently has internet. The auto-poll loop and
  /// [send] consult this. [start] must also be called before the poll
  /// loop fires — see the architecture note in the file header.
  @override
  bool isAvailable() => _hasInternet;

  @override
  Future<void> send(Message msg) async {
    if (!_hasInternet) {
      throw TransportUnavailableException(name);
    }
    await _gateway.pushMessage(msg);
  }

  @override
  Stream<Message> get incoming => _incomingController.stream;

  // ---------------------------------------------------------------------------
  // Auto-poll lifecycle (own traffic — production behavior per spec §10)
  // ---------------------------------------------------------------------------

  /// Activate the auto-poll loop. Idempotent.
  ///
  /// After [start], the transport polls every [_pollInterval] whenever
  /// [isAvailable] is true. When connectivity drops, the loop simply
  /// pauses its work for the next tick (no error, no crash). When
  /// connectivity returns, the loop resumes on the next tick.
  void start() {
    if (_started) return;
    _started = true;
    _autoPollTimer = Timer.periodic(_pollInterval, (_) => _autoPollTick());
    // Fire one immediately so the user doesn't wait a full interval for
    // the first pull on app start.
    _autoPollTick();
  }

  /// Deactivate the auto-poll loop. Idempotent.
  Future<void> stop() async {
    _autoPollTimer?.cancel();
    _autoPollTimer = null;
    _started = false;
  }

  Future<void> _autoPollTick() async {
    if (!_hasInternet) return;
    try {
      final now = DateTime.now().toUtc();
      final broadcast = await _gateway.pullBroadcastSince(
        now,
        channelIds: _channelIds,
      );
      for (final m in broadcast) {
        await _filterAndRebroadcast(m, MessageOrigin.internet);
      }
      final directs = await _gateway.pullDirectFor(_ownSenderId, now);
      for (final m in directs) {
        await _filterAndRebroadcast(m, MessageOrigin.internet);
      }
    } on FirestoreGatewayUnavailable {
      // Local-only mode — silently no-op.
    } catch (_) {
      // Pull failures are non-fatal; the next tick will retry.
    }
  }

  // ---------------------------------------------------------------------------
  // Gateway poll (compatibility with Ticket #22 — gateway-mode traffic)
  // ---------------------------------------------------------------------------

  /// Start the gateway-driven poll loop. Idempotent. Driven by
  /// [GatewayRelay] while the user's gateway toggle is ON.
  void pollStart() {
    if (_gatewayPollTimer != null) return;
    _gatewayPollTimer =
        Timer.periodic(_pollInterval, (_) => _gatewayPollTick());
    _gatewayPollTick();
  }

  /// Stop the gateway-driven poll loop. Idempotent.
  void pollStop() {
    _gatewayPollTimer?.cancel();
    _gatewayPollTimer = null;
  }

  Future<void> _gatewayPollTick() async {
    if (!_hasInternet) return;
    try {
      final now = DateTime.now().toUtc();
      final broadcast = await _gateway.pullBroadcastSince(
        now,
        channelIds: _channelIds,
      );
      for (final m in broadcast) {
        if (!_incomingController.isClosed) {
          _incomingController.add(m);
        }
      }
      final directs = await _gateway.pullDirectFor(_ownSenderId, now);
      for (final m in directs) {
        if (!_incomingController.isClosed) {
          _incomingController.add(m);
        }
      }
    } on FirestoreGatewayUnavailable {
      // Local-only mode — silently no-op.
    } catch (_) {
      // Pull failures are non-fatal; the next tick will retry.
    }
  }

  // ---------------------------------------------------------------------------
  // Pull-side filter (auto-poll only)
  // ---------------------------------------------------------------------------

  /// Apply the duplicate / invalid / TTL filters per spec §9 / Ticket
  /// #26 (same rules as the SMS re-injection pipeline):
  ///   * empty id → drop
  ///   * already in seen-cache → drop
  ///   * ttl <= 0 → drop
  /// On success, emits a copy with `origin` set, ttl decremented,
  /// hop_count incremented, AND re-broadcasts via the manager so the
  /// other transports can carry it forward.
  Future<void> _filterAndRebroadcast(Message msg, MessageOrigin origin) async {
    if (msg.id.isEmpty) return;
    if (await _seenCache.isSeen(msg.id)) return;
    if (msg.ttl <= 0) return;
    await _seenCache.markSeen(msg.id);
    final relayed = msg.copyWith(
      origin: origin,
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
    );
    if (!_incomingController.isClosed) {
      _incomingController.add(relayed);
    }
    unawaited(_manager.rebroadcast(relayed));
  }

  /// Free resources. After calling this, the transport cannot send or
  /// emit any more messages. Idempotent.
  Future<void> dispose() async {
    pollStop();
    _autoPollTimer?.cancel();
    _autoPollTimer = null;
    _started = false;
    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }
}

// ---------------------------------------------------------------------------
// Null-object defaults so the transport is usable in isolation (e.g. the
// gateway relay test, smoke tests) without forcing the caller to provide
// every collaborator up front. Production wires up the real
// `LocalDbSeenCache` and `TransportManager.rebroadcast`.
// ---------------------------------------------------------------------------

class _NoSeenCache implements InternetSeenCache {
  @override
  Future<bool> isSeen(String id) async => false;
  @override
  Future<void> markSeen(String id) async {}
}

class _NoTransportManager implements InternetTransportManagerHost {
  @override
  Future<void> rebroadcast(Message msg) async {}
}
