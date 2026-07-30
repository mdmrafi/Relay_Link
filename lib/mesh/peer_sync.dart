// RelayLink — Bloom-filter peer-sync on connect (Ticket #11).
//
// When two devices establish a mesh link, each side ships a Bloom filter of
// recently-seen message IDs to the other. After the handshake, each side
// scans its local message store for entries whose ID the peer *probably*
// hasn't seen (`!peerFilter.mightContain(id)`) and pushes those messages.
//
// The symmetric-difference heuristic means we transfer only the IDs that
// *might* be missing from the peer. The Bloom filter has a configurable
// false-positive rate (defaults: ~0.81% theoretical at 2k entries) which
// causes the occasional redundant push. False positives cost us one wasted
// push; false negatives cost us a missed relay. We accept the trade-off
// because the alternative is shipping the full message history on every
// reconnect — see README's "Bloom-filter trade-off" note.
//
// API surface:
//   * `PeerChannel` — small interface so the sync can run over:
//        - a loopback channel (tests live in `test/mesh/peer_sync_test.dart`)
//        - the real MeshTransport (Wave 4 #08 — not yet wired in here).
//   * `PeerSession` — the live handle returned from `PeerChannel.connect()`.
//     Bidirectional control stream (`incoming` / `sendControl`).
//   * `PeerSync` — single class holding the per-device sync state
//      (local Bloom filter, local message store, lifecycle hooks for the
//       BLE/multipeer transport).
//   * `PeerSyncEnvelope` (sealed) — control-frame tagged union. Today only
//      `PeerSyncFilter`; future handshakes extend the discriminator.
//
// Wire format (over the PeerChannel side):
//   * Handshake: `PeerSyncFilter` — `{kind: 'bloom_filter', filter: <b64>}`
//   * Push: standard `Message` JSON (so it rides the same relay pipeline).

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:relaylink/mesh/bloom.dart';
import 'package:relaylink/models/message.dart';

/// Abstract control channel used by [PeerSync] to talk to a single remote
/// peer. Implementations are responsible for serialising control messages
/// onto whatever radio they're sitting on (loopback in tests; Bluetooth /
/// Multipeer Connectivity in production).
///
/// The contract is intentionally minimal — just enough for the
/// symmetric-difference handshake:
///   * `connect()` — establish the link; returns a [PeerSession] that the
///     sync uses to send control frames and observe incoming ones. Until
///     this resolves, no sync happens.
///   * `sendMessage(Message)` — push a relay payload to the peer (used to
///     ship the symmetric-difference messages post-handshake).
abstract class PeerChannel {
  /// Open a session to the peer. Returns when the link is up and the
  /// channel can begin shipping control frames.
  Future<PeerSession> connect();

  /// Send a relay [Message] to the peer. Used post-handshake to push the
  /// payload side of the sync.
  Future<void> sendMessage(Message msg);
}

/// An open [PeerChannel] session. The underlying transport delivers
/// incoming control envelopes via [incoming] and accepts outgoing ones via
/// [sendControl].
abstract class PeerSession {
  /// Stream of incoming handshake envelopes, already decoded into the
  /// tagged forms (currently only [PeerSyncFilter], but extensible).
  Stream<PeerSyncEnvelope> get incoming;

  /// Push a [PeerSyncEnvelope] to the peer. Implementations are expected
  /// to JSON-encode and ship it; the sync deals only in typed objects.
  Future<void> sendControl(PeerSyncEnvelope env);

  /// Tear down the session. After this the streams are closed and any
  /// further [sendControl] is a no-op.
  Future<void> close();
}

// ---------------------------------------------------------------------------
// Envelope types
// ---------------------------------------------------------------------------

/// Tagged union of all control frames we send over a [PeerSession]. Today
/// only the Bloom filter is defined; future sync-protocol extensions (e.g.
/// a "have-list" trap, RTT measurement) can extend the discriminator.
sealed class PeerSyncEnvelope {
  /// JSON discriminator. Used by [PeerSyncEnvelope.decode] to round-trip.
  String get kind;

  /// Serialize to a JSON map. The inverse of the per-subclass `fromJson`
  /// and the dispatch table in [decode].
  Map<String, dynamic> toJson();

  /// Decode a JSON map back into the right subclass. Throws
  /// [FormatException] on unknown / malformed input.
  static PeerSyncEnvelope decode(Map<String, dynamic> json) {
    final kind = json['kind'];
    switch (kind) {
      case 'bloom_filter':
        return PeerSyncFilter.fromJson(json);
      default:
        throw FormatException('Unknown PeerSyncEnvelope kind: $kind');
    }
  }
}

/// "Here is the set of message IDs I have already seen." Sent by each side
/// once during the handshake.
class PeerSyncFilter extends PeerSyncEnvelope {
  /// Stable peer identity. Reserved for future targeted filtering (e.g.
  /// honoring per-peer allowlists). Currently informational.
  final String peerId;

  /// The Bloom-filter bytes — see [BloomFilter.encode] / [BloomFilter.decode].
  final Uint8List filterBytes;

  PeerSyncFilter({required this.peerId, required this.filterBytes});

  @override
  String get kind => 'bloom_filter';

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'peer_id': peerId,
        // Base64 keeps the envelope text-portable across transports that
        // don't have a binary framing layer (e.g. SMS adapter, the
        // simple-JSON loopback channel used in tests).
        'filter': base64.encode(filterBytes),
      };

  static PeerSyncFilter fromJson(Map<String, dynamic> json) {
    final peerId = json['peer_id'];
    final filter = json['filter'];
    if (peerId is! String) {
      throw const FormatException('PeerSyncFilter.peer_id must be a String');
    }
    if (filter is! String) {
      throw const FormatException('PeerSyncFilter.filter must be a String');
    }
    return PeerSyncFilter(
      peerId: peerId,
      filterBytes: base64.decode(filter),
    );
  }
}

// ---------------------------------------------------------------------------
// PeerSync
// ---------------------------------------------------------------------------

/// Maintains the local seen-cache and message-store, and runs the
/// symmetric-difference sync protocol on every peer connect.
///
/// Threading: all public methods are safe to call from the same isolate.
/// The class does not spawn its own timers; sync is purely driven by
/// [handleConnect] calls.
class PeerSync {
  /// Backing Bloom filter. Lives for the lifetime of the [PeerSync].
  final BloomFilter localBloom = BloomFilter.empty();

  /// Locally-known messages by id. Used as the source-of-truth for the
  /// symmetric-difference payload push. Insert order is preserved so the
  /// push is FIFO when the peer expects ordered delivery.
  final LinkedHashMap<String, Message> _messages =
      LinkedHashMap<String, Message>();

  /// Optional observer for diagnostics. Receives one event per
  /// local-store insert. Tests subscribe to this.
  void Function(Message msg)? onInsert;

  /// Optional observer for diagnostics. Receives one event per message
  /// the sync decides to push to the peer. Tests use this to assert
  /// against [Message.id] without poking at the [PeerChannel].
  void Function(Message msg)? onPush;

  /// Local peer id. Stamped on outbound [PeerSyncFilter] envelopes so the
  /// remote side can identify who's handshaking (helpful in star / bus
  /// topologies where multiple peers might converge on one device).
  final String selfPeerId;

  /// Constructs a [PeerSync]. [selfPeerId] is required so the handshake
  /// frame carries an identity.
  PeerSync({required this.selfPeerId});

  /// Read-only view of every locally-stored message, in insertion order.
  List<Message> get storedMessages =>
      List<Message>.unmodifiable(_messages.values);

  /// Number of distinct ids currently in the local store.
  int get storedCount => _messages.length;

  /// Insert a freshly-arrived or freshly-authored [msg] into the local
  /// seen-cache. Adds it to the message store and to the Bloom filter.
  /// Idempotent on id — the second insert for the same id is a no-op so
  /// the relay loop can call us freely even when a duplicate arrives.
  void registerMessage(Message msg) {
    if (_messages.containsKey(msg.id)) return;
    _messages[msg.id] = msg;
    localBloom.insert(msg.id);
    final cb = onInsert;
    if (cb != null) cb(msg);
  }

  /// Records the set of message ids (without payloads). Useful for
  /// tests that only need to populate the seen-cache.
  void registerSeenIds(Iterable<String> ids) {
    for (final id in ids) {
      localBloom.insert(id);
    }
  }

  /// Populate the local store with a known set of [messages]. Each entry
  /// runs through [registerMessage] so the dedup invariants are preserved.
  void registerMessages(Iterable<Message> messages) {
    for (final m in messages) {
      registerMessage(m);
    }
  }

  /// Drive the bloom handshake against [channel]. Resolves when both
  /// sides have completed the exchange (or when the channel closes).
  ///
  /// The function never throws — connection / IO failures are caught and
  /// surfaced via [onError] (if set) or swallowed. The handshake has
  /// these steps:
  ///
  ///   1. Open the channel via `channel.connect()`.
  ///   2. Ship our local Bloom filter.
  ///   3. Wait for the peer's filter envelope.
  ///   4. Compute the symmetric-difference push list against the peer's
  ///      filter and ship each candidate message.
  ///   5. The actual *receipt* of those messages happens through the
  ///      caller's normal relay pipeline (the same `incoming` stream the
  ///      device subscribes to for mesh) — we don't double-handle them
  ///      here to avoid breaking the relay's signature / re-broadcast path.
  ///   6. Close the session.
  Future<void> handleConnect(
    PeerChannel channel, {
    Duration handshakeTimeout = const Duration(seconds: 5),
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    PeerSession? session;
    try {
      session = await channel.connect();
    } catch (e, st) {
      if (onError != null) onError(e, st);
      return;
    }

    try {
      await _runHandshake(
        channel,
        session,
        handshakeTimeout: handshakeTimeout,
        onError: onError,
      );
    } finally {
      // Best-effort close — never let a hangup block the next connect.
      try {
        await session.close();
      } catch (_) {/* ignore */}
    }
  }

  Future<void> _runHandshake(
    PeerChannel channel,
    PeerSession session, {
    required Duration handshakeTimeout,
    void Function(Object error, StackTrace stack)? onError,
  }) async {
    // Subscribe FIRST, then send. The subscription is what makes the
    // listener live, so the order matters: if we sent first and the
    // peer's filter round-tripped before we subscribed, we'd lose it
    // (broadcast streams drop events that arrive before listeners).
    final filterFuture = _awaitFilterEnvelope(session, handshakeTimeout);

    // Build our outbound filter and ship it.
    final outbound = PeerSyncFilter(
      peerId: selfPeerId,
      filterBytes: localBloom.encode(),
    );

    try {
      await session.sendControl(outbound);
    } catch (e, st) {
      if (onError != null) onError(e, st);
      // If we can't even send our own filter, the handshake is dead.
      return;
    }

    late final PeerSyncFilter peerFilter;
    try {
      peerFilter = await filterFuture;
    } on TimeoutException catch (e, st) {
      if (onError != null) {
        onError(e, st);
      }
      return;
    } catch (e, st) {
      if (onError != null) onError(e, st);
      return;
    }

    // Decode the peer's filter (well-formed-ness is enforced here).
    late final BloomFilter peerBloom;
    try {
      peerBloom = BloomFilter.decode(peerFilter.filterBytes);
    } on FormatException catch (e, st) {
      if (onError != null) onError(e, st);
      return;
    }

    // Step 4: compute symmetric-difference candidates and push each.
    final pushList = _computePushList(peerBloom);
    for (final msg in pushList) {
      final cb = onPush;
      if (cb != null) cb(msg);
      try {
        await channel.sendMessage(msg);
      } catch (e, st) {
        if (onError != null) onError(e, st);
        return;
      }
    }

    // Step 5 is intentionally NOT performed here. Inbound messages should
    // arrive via the channel's relay stream and be processed by the caller's
    // normal relay pipeline. Re-registering them here would skip signature
    // verification and the chain of `hop_count` / `ttl` decrements.
  }

  /// Resolve to the first [PeerSyncFilter] envelope on [session.incoming].
  /// Any other envelope kinds are ignored for now.
  ///
  /// The returned future is sensitive to the `session` stream being closed
  /// before the first filter arrives — in that case it completes with a
  /// [StateError]. If [timeout] elapses first, the future completes with
  /// a [TimeoutException]. In both failure cases the listener is
  /// cancelled before the future resolves so a subsequent session close
  /// does not race-fire an additional onDone.
  Future<PeerSyncFilter> _awaitFilterEnvelope(
    PeerSession session,
    Duration timeout,
  ) async {
    final completer = Completer<PeerSyncFilter>();
    late final StreamSubscription<PeerSyncEnvelope> sub;
    late final Timer timer;
    var settled = false;

    void cleanup() {
      timer.cancel();
      // cancel() is synchronous-ish; we don't need to await it.
      sub.cancel();
    }

    sub = session.incoming.listen((env) {
      if (settled) return;
      if (env is PeerSyncFilter) {
        settled = true;
        cleanup();
        completer.complete(env);
      }
    }, onError: (Object e, StackTrace st) {
      if (settled) return;
      settled = true;
      cleanup();
      completer.completeError(e, st);
    }, onDone: () {
      if (settled) return;
      settled = true;
      cleanup();
      completer.completeError(
        StateError('Session closed before peer filter arrived'),
      );
    });

    // Race the filter-await against the timeout. Whichever settles first
    // wins; the loser is cancelled / allowed to no-op.
    timer = Timer(timeout, () {
      if (settled) return;
      settled = true;
      cleanup();
      completer.completeError(
        TimeoutException(
            'Peer did not return a bloom filter within $timeout', timeout),
      );
    });

    return completer.future;
  }

  /// Pure helper: given a peer's Bloom filter, return the messages that we
  /// hold whose IDs are *probably* new to the peer. Order is stable
  /// (insertion order via [LinkedHashMap]).
  ///
  /// False-positive handling: a `mightContain` hit means we skip the push
  /// (we believe the peer already has the message). On a miss we push.
  /// A false-negative from `mightContain` (peer actually doesn't have the
  /// message) results in a missed relay — accepted per spec §7 / README.
  List<Message> _computePushList(BloomFilter peerBloom) {
    final out = <Message>[];
    for (final m in _messages.values) {
      if (!peerBloom.mightContain(m.id)) {
        out.add(m);
      }
    }
    return out;
  }
}
