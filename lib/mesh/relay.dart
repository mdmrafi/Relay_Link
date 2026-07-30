// RelayLink — Mesh relay layer (Ticket #09).
//
// Subscribes to `Transport.incoming` on every registered transport and
// decides what to do with each message:
//   1. If we've already seen the message id, drop it silently (seen-cache
//      dedup).
//   2. Otherwise, mark it seen (so future echoes are dropped).
//   3. If the message is one we ourselves originated, stop here — don't
//      re-broadcast our own messages, even though they go through the
//      seen-cache so neighbor echoes don't bounce back to us.
//   4. If the message's TTL has reached 0, stop here — no more hops.
//   5. Otherwise, decrement `ttl`, increment `hop_count`, and re-broadcast
//      on every *available* transport.
//
// Seen cache
// ----------
// [LruSeenCache] is a small, in-memory, LRU-bounded set of message ids
// the relay has already processed. Bounded so the set cannot grow without
// limit over the device's lifetime — old ids fall out as new ones arrive.
// The cap is 2000 by default, matching SPEC §7's ~19 kbit Bloom filter
// sizing from Ticket #10 (also 2000 entries) and the ticket's explicit
// "cap at 2000" line. Persistence of seen ids to sqflite is the
// responsibility of `LocalDb.markSeen` / `isSeen` (#05); the relay uses
// its own LRU for fast checks during a session and can be wired up to
// `LocalDb` for cross-session / cross-process sharing in a later ticket.
//
// Why TTL, not hop_count?
// -----------------------
// The ticket body informally says "if unseen and `hop_count > 0`,
// decrement and re-broadcast". SPEC.md §5 and the message docstring
// (lib/models/message.dart) both describe `ttl` as "Remaining mesh hops.
// Decremented at each relay", which matches the relay's authoritative
// behavior. We decrement `ttl` and bump `hop_count` in lockstep so both
// stay consistent on the wire.

import 'dart:async';
import 'dart:collection';

import '../models/message.dart';
import '../transport/transport.dart';

/// Default capacity for [LruSeenCache]. Matches the 2000-entry cap called
/// out in the ticket and aligns with the Bloom filter sizing used by the
/// peer's seen-summary protocol in Ticket #10.
const int kDefaultSeenCacheCapacity = 2000;

/// Bounded, in-memory LRU set of message ids the relay has processed.
///
/// Insertion order is preserved; once [capacity] entries are held, the
/// least-recently-added (and least-recently-touched) entry is evicted to
/// make room. Touch semantics: re-adding an existing id moves it to the
/// most-recent position, so the LRU really is recency-ordered, not
/// insertion-ordered.
///
/// All methods are synchronous and O(1) amortized.
class LruSeenCache {
  /// Maximum number of entries before eviction kicks in. Clamped to a
  /// minimum of 1 so a misconfigured cap of 0 or negative does not
  /// silently disable dedup.
  final int capacity;

  final LinkedHashMap<String, _LruEntry> _entries =
      LinkedHashMap<String, _LruEntry>();

  LruSeenCache({int capacity = kDefaultSeenCacheCapacity})
      : capacity = capacity < 1 ? 1 : capacity;

  /// How many ids are currently cached.
  int get length => _entries.length;

  /// Whether [id] is currently in the cache. Returns `false` for ids that
  /// have been evicted.
  bool contains(String id) => _entries.containsKey(id);

  /// Add [id] to the cache. If it was already present, refreshes its
  /// recency. Returns `true` if this call caused an insertion, `false`
  /// if [id] was already in the cache (a refresh / touch).
  bool add(String id) {
    final existing = _entries[id];
    if (existing != null) {
      // Touch: remove and re-insert to move to the back (most recent).
      _entries.remove(id);
      _entries[id] = existing;
      return false;
    }
    _entries[id] = _LruEntry(id);
    // Evict oldest entries until we're back at or under capacity.
    while (_entries.length > capacity) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey);
    }
    return true;
  }

  /// Drop all entries. Mostly useful for tests.
  void clear() => _entries.clear();
}

class _LruEntry {
  const _LruEntry(this.id);
  final String id;
}

/// The mesh relay.
///
/// Listens to [Transport.incoming] on every registered transport and
/// decides whether each message should be dropped, marked-seen-only, or
/// re-broadcast with a decremented TTL. Construction is cheap; call
/// [start] to wire up subscriptions and [stop] to tear them down.
class MeshRelay {
  /// This device's stable pseudonymous id (matches `Message.senderId`).
  /// Messages whose `senderId` equals this value are treated as
  /// self-originated and never re-broadcast.
  final String localDeviceId;

  /// The LRU seen-cache. Shared between relay instances so two
  /// `MeshRelay`s on the same device dedup together.
  final LruSeenCache seenCache;

  /// The transports this relay listens to and broadcasts on. Order
  /// doesn't matter for correctness (a transport doesn't echo back to
  /// itself in the same way a real radio would), but it's typically
  /// `[mesh, sms, internet, …]`.
  final List<Transport> transports;

  /// Optional async hook fired after the relay marks a message seen.
  /// Lets production code persist the id to `LocalDb.markSeen` without
  /// coupling this layer to sqflite. Test code can leave this null.
  final Future<void> Function(String messageId)? onSeen;

  final List<StreamSubscription<Message>> _subs = <StreamSubscription<Message>>[];
  bool _started = false;

  MeshRelay({
    required this.localDeviceId,
    required this.seenCache,
    required this.transports,
    this.onSeen,
  });

  /// Whether [start] has been called and subscriptions are live.
  bool get isRunning => _started;

  /// Subscribe to `incoming` on every transport. Idempotent: a second
  /// call is a no-op so callers don't have to track state.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final t in transports) {
      _subs.add(t.incoming.listen(
        (msg) => _handle(msg),
        onError: (Object _) {
          // Stream errors are not actionable here — the transport layer
          // surfaces its own failures via `send`. Swallow so we don't
          // crash the relay on a single bad frame.
        },
      ));
    }
  }

  /// Cancel every subscription. Safe to call multiple times.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Run the relay algorithm against [msg]. Exposed (rather than just
  /// subscribed internally) so tests can drive the relay synchronously
  /// without spinning up stream listeners.
  Future<void> _handle(Message msg) async {
    // 1. Seen-cache dedup — drop echoes of any id we've already touched.
    if (seenCache.contains(msg.id)) return;

    // 2. Mark seen *before* anything else so a re-entrant incoming for
    //    the same id (e.g. another transport that also saw it) is dropped.
    seenCache.add(msg.id);
    final hook = onSeen;
    if (hook != null) {
      try {
        await hook(msg.id);
      } catch (_) {
        // Persistence is best-effort; the in-memory cache is the source
        // of truth for the relay's dedup decisions this session.
      }
    }

    // 3. Self-originated: don't loop our own messages back out.
    if (msg.senderId == localDeviceId) return;

    // 4. TTL exhausted: drop without re-broadcasting.
    if (msg.ttl <= 0) return;

    // 5. Re-broadcast with ttl-1, hop_count+1.
    final forwarded = msg.copyWith(
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
    );
    for (final t in transports) {
      if (!t.isAvailable()) continue;
      try {
        await t.send(forwarded);
      } catch (_) {
        // A single transport's failure must not poison the others.
        // Errors surface through TransportManager.fanOutSend at a higher
        // layer; the relay's job here is to ship-and-forget.
      }
    }
  }
}
