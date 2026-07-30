// RelayLink — Ticket #17: channel routing (tag-aware mesh relay).
//
// Wraps the mesh-layer relay logic from `lib/mesh/relay.dart` (#09) with a
// channel-aware view:
//   * Every incoming message carries a plaintext `channelId` in its
//     envelope (SPEC §5). The mesh relay layer is intentionally
//     content-agnostic — it forwards any envelope whose TTL is positive
//     and which isn't on the seen-cache.
//   * This layer adds the *display-side* join-aware logic on top:
//       * If the local device has a key for `channelId`, the message is
//         classified as `decryptedSurfaceable` — the UI is expected to
//         attempt AEAD decryption with the channel key.
//       * If the local device does NOT have a key for `channelId`, the
//         message is still relayed (per SPEC §6.2 — routing metadata is
//         plaintext, so a non-joined device can still forward), but it
//         is classified as opaque (`relayedForForeignChannel`) so the UI
//         doesn't try to display what it can't read.
//       * DIRECT messages are routed to a single recipient_id and use the
//         Double-Ratchet envelope (#13), not the per-channel AES key.
//         We deliberately leave DIRECT handling to the ratchet layer —
//         the channelId field on a DIRECT message is just metadata and
//         the routing layer's job is "is this addressed to me?", which
//         is decided by `recipientId`, not by channel membership.
//
// Why this layer does NOT do decryption itself:
//   The wire layout in this codebase keeps `Message.payload` as the
//   ciphertext bytes only, with the AES-GCM nonce + MAC tracked
//   separately by the crypto layer (`BroadcastCrypto` in
//   `lib/crypto/broadcast.dart`). That separation is the codebase's
//   standing convention (see ticket #03 + the two-device integration
//   test). The routing layer therefore classifies join/no-join and
//   hands the channelId to the consumer; the actual AEAD work happens
//   downstream, where the consumer has the full envelope in hand.
//
// Threat model (this file):
//   * Plaintext `channelId` is fine — it's metadata, not a secret
//     (SPEC §5, §6.2).
//   * Confidentiality is NOT a routing-layer concern. AEAD does that.
//     Routing only decides forward-or-not and surface-or-not.
//   * Tamper detection happens downstream (in the display layer's
//     AES-GCM MAC check). The routing layer cannot decide "is this
//     ciphertext for me?" without first running AEAD, which it
//     intentionally does not.
//
// Constrained dependency surface:
//   * `lib/channels/keys.dart` — read (#15 shipped).
//   * `lib/transport/transport.dart` — read (#06 shipped, used to be
//     `MeshTransport` from #08, but this layer only depends on the
//     abstract `Transport` interface, not the concrete mesh transport,
//     so it composes cleanly with SMS / internet / gateway relays too).
//   * `lib/models/message.dart` — read (#04 shipped).
//
// Out of scope (explicitly deferred):
//   * Persistence of "channel not joined" history (a non-joined device
//     doesn't even store the ciphertext — there's nothing to store).
//   * Channel auto-discovery from QR invites (#16 owns invite flow).
//   * UI for "this message was relayed but is not for you" (that's a #41
//     concern).
//
// See `test/channels/routing_test.dart` for the behaviour contract.

import 'dart:async';

import '../channels/keys.dart';
import '../models/message.dart';
import '../transport/transport.dart';

/// Outcome of the routing layer's processing of a single received
/// message.
///
/// Exposed via the `events` stream and the `processed` list so tests and
/// the UI can react ("show", "silently relay", "log tampering").
enum ChannelRoutingEventKind {
  /// BROADCAST on a channel we have joined — surface for display +
  /// AEAD-decrypt downstream. Message is also relayed onward.
  decryptedSurfaceable,

  /// BROADCAST on a channel we have NOT joined — message is opaque to
  /// us, but per SPEC §6.2 we still relay it onward to peers. UI must
  /// NOT surface this (we cannot decrypt).
  relayedForForeignChannel,

  /// Message was seen before — silently dropped per the relay layer's
  /// dedup contract. Not forwarded.
  duplicateDropped,

  /// Message originated from this device — not re-broadcast.
  selfOriginated,

  /// TTL reached zero — held for the seen-cache but no further relay.
  ttlExhausted,

  /// DIRECT mode — routing layer passes it through (channelId is not
  /// relevant for ratchet decryption; the ratchet layer decides
  /// surface-or-not based on `recipientId`).
  directPassthrough,
}

/// One decoded routing decision. Surfaced for tests + observability.
class ChannelRoutingEvent {
  /// What happened. See [ChannelRoutingEventKind] for meanings.
  final ChannelRoutingEventKind kind;

  /// The message this event describes.
  final Message message;

  /// The channel this event pertains to (== `message.channelId`).
  final String channelId;

  /// For `decryptedSurfaceable` events, the AES key the consumer should
  /// hand to `BroadcastCrypto` to recover plaintext. `null` for every
  /// other kind. Kept here so a downstream display layer doesn't need
  /// its own membership lookup.
  final List<int>? keyForSurface;

  const ChannelRoutingEvent({
    required this.kind,
    required this.message,
    required this.channelId,
    this.keyForSurface,
  });
}

/// Decides whether the local device has joined a channel and knows its
/// AES key.
///
/// Exposed as an abstract method so tests can inject a fake that doesn't
/// need `flutter_secure_storage`, and so production can swap in a
/// notifier-backed implementation if the store ever goes reactive.
abstract class ChannelMembershipResolver {
  /// The 32-byte AES key for [channelId] if we have joined it, else
  /// `null`. Must NOT throw — a missing key is a recoverable condition.
  Future<List<int>?> keyFor(String channelId);
}

/// [ChannelMembershipResolver] backed by a real [ChannelKeyStore].
class KeyStoreMembershipResolver implements ChannelMembershipResolver {
  final ChannelKeyStore _store;
  KeyStoreMembershipResolver(this._store);

  @override
  Future<List<int>?> keyFor(String channelId) =>
      _store.getChannelKey(channelId);
}

/// Plaintext seen-cache for relay-layer dedup. The same `LruSeenCache`
/// pattern is used by `lib/mesh/relay.dart` (#09); we duplicate the
/// tiny list-backed class here to keep `lib/channels/*`'s import graph
/// narrow (no `lib/mesh/*` dependency).
class ChannelSeenCache {
  /// Maximum number of message ids kept before eviction.
  final int capacity;

  final List<String> _ids = <String>[];

  ChannelSeenCache({this.capacity = 2000});

  /// Current number of ids held.
  int get length => _ids.length;

  /// Whether [id] is in the cache. O(n) but n is bounded (default 2000).
  bool contains(String id) => _ids.contains(id);

  /// Add [id]. Evicts oldest entries until the cache is back at or
  /// under [capacity]. Re-adding an existing id refreshes its recency.
  void add(String id) {
    final existing = _ids.indexOf(id);
    if (existing != -1) {
      // Refresh recency: move to the end (newest position).
      _ids.removeAt(existing);
      _ids.add(id);
      return;
    }
    _ids.add(id);
    while (_ids.length > capacity) {
      _ids.removeAt(0);
    }
  }

  /// Drop every entry. Tests only.
  void clear() => _ids.clear();
}

/// Configures a [ChannelRouter]'s behaviour.
class ChannelRouterConfig {
  /// This device's sender id. Messages whose `senderId` equals this
  /// value are treated as self-originated and not re-broadcast.
  final String localDeviceId;

  /// The transports this router listens to / broadcasts on. Order
  /// is irrelevant for correctness — every available transport gets
  /// every relay.
  final List<Transport> transports;

  /// The store that says which channels we've joined. Required.
  final ChannelMembershipResolver membership;

  /// Shared seen-cache. Routing layer re-uses the same LRU as the mesh
  /// relay so cross-layer dedup works (a message the mesh relay dropped
  /// doesn't need to be re-evaluated by the channel router).
  final ChannelSeenCache seenCache;

  /// Optional broadcast of routing decisions. UI / gateway layers can
  /// subscribe to e.g. drive a notification pipeline.
  final StreamController<ChannelRoutingEvent>? eventsController;

  ChannelRouterConfig({
    required this.localDeviceId,
    required this.transports,
    required this.membership,
    required this.seenCache,
    this.eventsController,
  });
}

/// Channel-aware mesh relay.
///
/// Subscribes to every transport's `incoming` stream, classifies each
/// message by channel membership, and ALWAYS re-broadcasts positive-TTL
/// envelopes to peers (per SPEC §6.2 — non-joined devices still relay
/// custom-channel traffic even though they cannot decrypt it).
///
/// This is *not* a replacement for `MeshRelay` from #09 — it's a
/// complementary layer that adds channel-aware classification and
/// decision logging on top. In production the two would be composed:
/// the mesh relay fires for every transport, and a [ChannelRouter]
/// would be a downstream listener of the same stream that also emits
/// per-channel events for the UI. To keep the dependency surface
/// narrow here, we implement the relay behaviour ourselves rather than
/// depending on `lib/mesh/relay.dart`.
class ChannelRouter {
  final ChannelRouterConfig _config;

  final List<StreamSubscription<Message>> _subs = <StreamSubscription<Message>>[];
  bool _started = false;

  /// Inspectable history of every event emitted by this router. Useful
  /// for tests and for debugging "why didn't this message surface?".
  final List<ChannelRoutingEvent> processed = <ChannelRoutingEvent>[];

  /// Inspectable history of every message this router has relayed
  /// onward (i.e. the post-TTL-decrement / hop-bumped copy handed to
  /// `Transport.send`). One entry per *relay decision*, not per
  /// transport — a single relay may produce multiple `t.send` calls
  /// across multiple transports but only ONE entry here.
  ///
  /// Useful for tests and for observability.
  final List<Message> relayed = <Message>[];

  ChannelRouter(this._config);

  /// Read-only view of the underlying config (for tests).
  ChannelRouterConfig get config => _config;

  /// Whether [start] has been called and the subscriptions are live.
  bool get isRunning => _started;

  /// Broadcast of routing decisions. Available only if the caller
  /// supplied a controller in [ChannelRouterConfig.eventsController];
  /// otherwise `null`.
  Stream<ChannelRoutingEvent>? get events =>
      _config.eventsController?.stream;

  /// Begin listening to `incoming` on every transport. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    for (final t in _config.transports) {
      _subs.add(t.incoming.listen(
        (msg) => _handle(msg),
        onError: (Object _) {
          // Transport-level stream errors are not actionable at this
          // layer. Matches the `MeshRelay` swallow-and-continue policy.
        },
      ));
    }
  }

  /// Cancel every subscription and tear down. Idempotent.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  // ---------------------------------------------------------------------------
  // Pure decision helpers (exposed for tests, no side effects)
  // ---------------------------------------------------------------------------

  /// Pure: given a message and a synchronous "have we joined this
  /// channel" answer, return the routing event kind this router would
  /// emit. Exposed so unit tests can assert decision logic without
  /// spinning up streams. Does not touch the seen-cache; that's
  /// [_handle]'s job.
  static ChannelRoutingEventKind classify({
    required Message msg,
    required bool channelJoined,
  }) {
    if (msg.mode == MessageMode.direct) {
      return ChannelRoutingEventKind.directPassthrough;
    }
    // BROADCAST paths only from here. `channelJoined` decides whether
    // we surface (and AEAD-decrypt downstream) vs. just forward.
    return channelJoined
        ? ChannelRoutingEventKind.decryptedSurfaceable
        : ChannelRoutingEventKind.relayedForForeignChannel;
  }

  // ---------------------------------------------------------------------------
  // Side effects: subscribe-side
  // ---------------------------------------------------------------------------

  Future<void> _handle(Message msg) async {
    // 1. Dedup against the seen-cache. Drop on hit.
    if (_config.seenCache.contains(msg.id)) {
      _emit(ChannelRoutingEvent(
        kind: ChannelRoutingEventKind.duplicateDropped,
        message: msg,
        channelId: msg.channelId,
      ));
      return;
    }

    // 2. Mark seen *before* anything else so a re-entrant incoming
    //    (multiple transports seeing the same id) is dropped.
    _config.seenCache.add(msg.id);

    // 3. Self-originated: stop here, never re-broadcast our own.
    if (msg.senderId == _config.localDeviceId) {
      _emit(ChannelRoutingEvent(
        kind: ChannelRoutingEventKind.selfOriginated,
        message: msg,
        channelId: msg.channelId,
      ));
      return;
    }

    // 4. TTL exhausted: stop here, no further relay.
    if (msg.ttl <= 0) {
      _emit(ChannelRoutingEvent(
        kind: ChannelRoutingEventKind.ttlExhausted,
        message: msg,
        channelId: msg.channelId,
      ));
      return;
    }

    // 5. Decide whether we have a key for this channel.
    //
    //    Direct messages route on `recipientId`, not on `channelId`
    //    (SPEC §5 — channelId on a DIRECT is metadata, not the
    //    addressing key). They use the Double-Ratchet envelope (#13)
    //    and are NOT decrypted by this layer.
    final isBroadcast = msg.mode == MessageMode.broadcast;
    List<int>? key;
    if (isBroadcast && msg.channelId.isNotEmpty) {
      key = await _config.membership.keyFor(msg.channelId);
    }

    final ChannelRoutingEventKind kind;
    if (isBroadcast) {
      kind = key == null
          ? ChannelRoutingEventKind.relayedForForeignChannel
          : ChannelRoutingEventKind.decryptedSurfaceable;
    } else {
      kind = ChannelRoutingEventKind.directPassthrough;
    }

    _emit(ChannelRoutingEvent(
      kind: kind,
      message: msg,
      channelId: msg.channelId,
      keyForSurface: kind == ChannelRoutingEventKind.decryptedSurfaceable
          ? key
          : null,
    ));

    // 6. Relay onward. Per SPEC §6.2, this happens regardless of
    //    whether we have the channel key — routing metadata is
    //    plaintext, so non-joined devices still act as store-and-
    //    forward couriers for custom-channel traffic. Decrement TTL,
    //    bump hop_count.
    final forwarded = msg.copyWith(
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
    );
    relayed.add(forwarded);
    for (final t in _config.transports) {
      if (!t.isAvailable()) continue;
      try {
        await t.send(forwarded);
      } catch (_) {
        // One transport's failure must not block the others; mirror
        // the `MeshRelay` swallow-and-continue policy.
      }
    }
  }

  void _emit(ChannelRoutingEvent ev) {
    processed.add(ev);
    final ctrl = _config.eventsController;
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(ev);
    }
  }
}
