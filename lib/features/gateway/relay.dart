// RelayLink — Ticket #22: Gateway mode relay code.
//
// When the Gateway toggle (Ticket #21) is ON, this orchestrator:
//   1. Listens to the mesh transport's `incoming` stream.
//   2. For each message that's NOT addressed to this device:
//        a. Marks it seen (so the gateway doesn't push the same id twice).
//        b. Pushes it to Firestore (BROADCAST → relay/{channel}/messages,
//           DIRECT → relay_direct/{recipient}/messages) with the ORIGINAL
//           sender_id preserved — the gateway acts as a "shadow identity",
//           we do not re-sign or rewrite the envelope.
//   3. Listens to the InternetTransport's `incoming` stream (polled at
//      the InternetTransport's configured interval).
//   4. For each pulled message destined for a known mesh peer (DIRECT with
//      a recipient_id matching a mesh peer, or any BROADCAST), re-injects
//      it into the mesh transport's outgoing pipeline via
//      [TransportManager.fanOutSend] (which fans out to ALL available
//      transports — the relay layer's hop_count decrement logic in
//      Ticket #09 will handle the rest).
//
// SAFETY BOUNDARIES (the spec §10 gateway mode promises):
//   * `GatewayRelay` is a no-op while the toggle is OFF. It MUST NOT
//     push, pull, or re-inject in that state.
//   * DIRECT messages addressed to a recipient_id that is neither us nor a
//     known mesh peer are NOT re-injected (we have no one to deliver to).
//   * Messages already seen (in our local seen-cache) are NOT pushed,
//     pushed duplicates are wasteful, and pulled re-injections are also
//     skipped so the mesh layer doesn't see the same id twice.
//   * Pushed messages preserve `sender_id`, `signature`, `payload`, and
//     every other field of the original envelope. The relay is a courier,
//     not an editor.
//   * `hop_count` is incremented once when we re-inject (Firestore pull
//     → mesh); the mesh relay layer decrements `ttl` when it broadcasts
//     onward (Ticket #09).

import 'dart:async';

import '../../../mesh/transport.dart';
import '../../../models/message.dart';
import '../../../storage/local_db.dart';
import '../../../transport/internet.dart';
import '../../../transport/transport.dart';

/// Snapshot of the seen-cache for relay decisions. Decouples the relay
/// from the LocalDb singleton in tests by allowing a fake implementation
/// to be passed in.
abstract class SeenCache {
  /// Has this message id been seen before?
  Future<bool> has(String id);

  /// Mark this message id as seen. Idempotent.
  Future<void> mark(String id);
}

/// [SeenCache] backed by [LocalDb]. The relay uses this in production.
class LocalDbSeenCache implements SeenCache {
  final LocalDb _db;
  LocalDbSeenCache(this._db);

  @override
  Future<bool> has(String id) => _db.isSeen(id);

  @override
  Future<void> mark(String id) => _db.markSeen(id);
}

/// Orchestrates "push others' mesh traffic up to Firestore" and
/// "pull others' Firestore traffic down into mesh" while the gateway
/// toggle is on.
///
/// All side effects are no-ops while [isGatewayEnabled] is `false`. This
/// is the core invariant — verified by tests in
/// `test/features/gateway/relay_test.dart`.
class GatewayRelay {
  /// The mesh transport we listen to and re-inject into.
  final MeshTransport _mesh;

  /// The internet transport whose poll loop we drive.
  final InternetTransport _internet;

  /// The transport manager we use for fan-out re-injection.
  final TransportManager _transportManager;

  /// The local seen-cache. Drives both the push dedup ("don't push
  /// twice") and the pull dedup ("don't re-inject twice").
  final SeenCache _seenCache;

  /// Function returning this device's own sender id.
  ///
  /// Stored as a closure (not a value) so identity can rotate / be loaded
  /// lazily. The relay only needs this for "is this message addressed to
  /// ME?" filtering.
  final String Function() _ownSenderIdProvider;

  /// Function returning the set of mesh peers' sender ids, used to decide
  /// whether a DIRECT message pulled from Firestore is destined for
  /// someone we could plausibly relay to.
  final Set<String> Function() _knownPeersProvider;

  /// The gateway toggle state, read on every message event.
  final bool Function() _isGatewayEnabled;

  StreamSubscription<Message>? _meshSub;
  StreamSubscription<Message>? _internetSub;

  /// True between [start] and [stop]. Always read [isRunning] externally
  /// instead of inspecting state directly.
  bool _running = false;

  /// For tests / observability: every message the relay has pushed UP to
  /// Firestore (gateway's view of "we relayed out").
  final List<Message> pushedUp = <Message>[];

  /// For tests / observability: every message the relay has re-injected
  /// into the mesh / fan-out (gateway's view of "we relayed in").
  final List<Message> reInjected = <Message>[];

  /// For tests / observability: every message the relay has dropped due
  /// to a safety boundary (toggle off, addressed to self, seen-cache hit,
  /// unknown DIRECT recipient, etc.). Captures the reason so we can
  /// assert on the rule that fired.
  final List<({Message message, String reason})> dropped =
      <({Message message, String reason})>[];

  GatewayRelay({
    required this._mesh,
    required this._internet,
    required this._transportManager,
    required this._seenCache,
    required this._ownSenderIdProvider,
    required this._knownPeersProvider,
    required this._isGatewayEnabled,
  });

  /// Whether the orchestrator is currently subscribed to streams.
  bool get isRunning => _running;

  /// Begin listening to mesh/internet streams and (while toggle is on)
  /// push and pull relay traffic.
  ///
  /// Idempotent — calling twice is a no-op.
  void start() {
    if (_running) return;
    _running = true;
    _meshSub = _mesh.incoming.listen(_onMeshIncoming);
    _internetSub = _internet.incoming.listen(_onInternetIncoming);
    // Drive the internet poll loop ONLY while the gateway toggle is on.
    // This is the orchestrator's contribution to "toggle OFF = no
    // gateway activity": even if the toggle is on right now, we drive
    // the poll so the next toggled-off event can stop it cleanly.
    if (_isGatewayEnabled()) {
      _internet.pollStart();
    }
  }

  /// Stop listening and stop the internet poll loop. Idempotent.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _meshSub?.cancel();
    await _internetSub?.cancel();
    _meshSub = null;
    _internetSub = null;
    _internet.pollStop();
  }

  /// Toggle-driven refresh: if the toggle just flipped ON, start the
  /// poll loop; if it flipped OFF, stop it. Called by the app shell
  /// when [GatewayEnabledNotifier] emits a new value (the Gateway tile
  /// in Settings).
  ///
  /// This is separate from [start] / [stop] so the orchestrator can be
  /// "alive" (subscribed to streams, which is a no-op while toggle is
  /// OFF) but only ACTIVE when the toggle flips on.
  void onGatewayToggleChanged(bool enabled) {
    if (!_running) return;
    if (enabled) {
      _internet.pollStart();
    } else {
      _internet.pollStop();
    }
  }

  // ---------------------------------------------------------------------------
  // Safety decisions (pure / synchronous, exposed for tests)
  // ---------------------------------------------------------------------------

  /// Pure decision: should this mesh-received message be pushed UP to
  /// Firestore?
  ///
  /// Rules (any failure → drop, NOT push):
  ///   * R1: toggle is OFF.
  ///   * R2: message originated here (sender_id == me). We don't relay
  ///        our own messages up — they're going out via the normal mesh
  ///        send path.
  ///   * R3: DIRECT message addressed to ME. We have the original; no
  ///        need to push to Firestore.
  ///
  /// Returns `null` if the message should be pushed, or a reason string
  /// if it should be dropped.
  String? shouldPushToFirestore(Message msg) {
    if (!_isGatewayEnabled()) return 'toggle-off';
    if (msg.senderId == _ownSenderIdProvider()) {
      return 'originated-here';
    }
    if (msg.mode == MessageMode.direct &&
        msg.recipientId == _ownSenderIdProvider()) {
      return 'addressed-to-self';
    }
    return null;
  }

  /// Pure decision: should this Firestore-pulled message be re-injected
  /// into the mesh?
  ///
  /// Rules (any failure → drop):
  ///   * R1: toggle is OFF.
  ///   * R2: we've already seen this id (seen-cache hit).
  ///   * R3: DIRECT addressed to a recipient we don't recognize AND not
  ///        to us.
  ///
  /// BROADCAST messages are always re-injected if the toggle is on and
  /// we haven't seen them — custom channels are also relayed by spec §7
  /// ("non-joined devices still relay custom-channel messages").
  bool shouldReInjectIntoMesh(Message msg, {required Set<String> seenIds}) {
    if (!_isGatewayEnabled()) return false;
    if (seenIds.contains(msg.id)) return false;
    if (msg.mode == MessageMode.direct) {
      final r = msg.recipientId;
      if (r == null) return false;
      final ownId = _ownSenderIdProvider();
      if (r != ownId && !_knownPeersProvider().contains(r)) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Mesh → Firestore (push)
  // ---------------------------------------------------------------------------

  Future<void> _onMeshIncoming(Message msg) async {
    final reason = shouldPushToFirestore(msg);
    if (reason != null) {
      dropped.add((message: msg, reason: reason));
      return;
    }
    // Seen-cache dedup: skip pushing if we've already pushed this id.
    if (await _seenCache.has(msg.id)) {
      dropped.add((message: msg, reason: 'seen-cache-hit'));
      return;
    }
    await _seenCache.mark(msg.id);
    try {
      await _internet.send(msg);
      pushedUp.add(msg);
    } catch (e) {
      // We do NOT roll back the seen-cache mark on push failure. The
      // window is small (the durability of the seen-cache is bounded by
      // the deployment, not by an exact frame), and a coerced retry on
      // the next hop would re-push anyway. Logging the failure is the
      // pragmatic hit — the orchestrator's test suite asserts on the
      // dropped list.
      dropped.add((message: msg, reason: 'push-failed: $e'));
    }
  }

  // ---------------------------------------------------------------------------
  // Firestore → mesh (pull)
  // ---------------------------------------------------------------------------

  Future<void> _onInternetIncoming(Message msg) async {
    if (!_isGatewayEnabled()) {
      dropped.add((message: msg, reason: 'toggle-off'));
      return;
    }
    if (await _seenCache.has(msg.id)) {
      dropped.add((message: msg, reason: 'seen-cache-hit'));
      return;
    }
    final ownId = _ownSenderIdProvider();
    if (msg.mode == MessageMode.direct) {
      final r = msg.recipientId;
      if (r == null) {
        dropped.add((message: msg, reason: 'direct-missing-recipient'));
        return;
      }
      if (r != ownId && !_knownPeersProvider().contains(r)) {
        dropped.add((message: msg, reason: 'unknown-direct-recipient'));
        return;
      }
    }
    await _seenCache.mark(msg.id);
    // Fan-out sends over every available transport. The mesh transport
    // will pick up the call and re-broadcast to connected peers (per
    // Ticket #08). The seen-cache layer (Ticket #09) handles TTL
    // decrement on relay.
    final errors = await _transportManager.fanOutSend(
      msg.copyWith(hopCount: msg.hopCount + 1),
    );
    for (final e in errors) {
      if (e != null) {
        dropped.add((message: msg, reason: 'reinject-failed: $e'));
      }
    }
    reInjected.add(msg);
  }

  /// Test hook: filter a list of candidate Firestore-pulled messages to
  /// only those the relay would re-inject, given the current
  /// [seenIds]. Useful for asserting safety-boundary behaviour without
  /// wiring the full push path.
  List<Message> filterPullable({
    required List<Message> candidate,
    required Set<String> seenIds,
  }) {
    return candidate
        .where((m) => shouldReInjectIntoMesh(m, seenIds: seenIds))
        .toList(growable: false);
  }
}
