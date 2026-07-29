// Reassembler for fragmented SMS messages (Ticket #25).
//
// Wire format (defined by #24 - SMS framing):
//   RL:<8-hex msgid>:<idx>/<total>:<base64-chunk>
//
// Design:
//   - Buffers per-msgid until all segments arrive, then emits the
//     reassembled ciphertext bytes via [messages].
//   - Out-of-order arrival is the default; segments are placed by index.
//   - Duplicates (same msgid+idx) are deduped silently.
//   - After [inactivityTimeout] of wall-clock (or [clock]-driven) silence
//     on a msgid, the buffer is evicted via [flushExpired].
//   - Malformed segments are rejected without mutating buffer state.
//
// Composability with #24: ingest accepts any string produced by the
// framing module; the emitted payload is the original ciphertext bytes
// (the framing layer base64-decodes the chunks and concatenates them).
// Composability with #26: [ReassembledMessage] exposes `.messageId` and
// `.payloadBytes` so the SMS reinjection pipeline can re-enter the
// message into the normal pipeline (seen-cache + TTL decrement + relay).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// A successfully reassembled SMS message.
///
/// The [payloadBytes] field is the original ciphertext bytes (concatenated
/// base64-decoded chunks); the SMS reinjection layer (#26) is responsible
/// for pushing this back into the normal pipeline.
class ReassembledMessage {
  ReassembledMessage({
    required this.messageId,
    required this.totalSegments,
    required this.segmentCount,
    required this.payloadBytes,
    required this.assembledAt,
  });

  /// 8-hex-character message id parsed from the segment header.
  final String messageId;

  /// The `total` field from the segment header (constant across segments).
  final int totalSegments;

  /// Number of segments actually received (== totalSegments on success).
  final int segmentCount;

  /// The original ciphertext bytes (concatenated base64-decoded chunks).
  final Uint8List payloadBytes;

  /// Wall-clock time when the message was completed.
  final DateTime assembledAt;
}

/// A clock abstraction used by the [Reassembler] for testable timeouts.
abstract class ReassemblerClock {
  factory ReassemblerClock.system() = _SystemClock;
  DateTime nowUtc();
}

/// Default wall-clock implementation.
class _SystemClock implements ReassemblerClock {
  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Per-msgid buffer state.
class _Buffer {
  _Buffer({
    required this.messageId,
    required this.totalSegments,
    required this.firstSeenAt,
    required this.lastUpdatedAt,
  });

  final String messageId;
  final int totalSegments;
  final DateTime firstSeenAt;
  DateTime lastUpdatedAt;
  final Map<int, String> _chunks = <int, String>{};

  /// True once `chunks` covers indices `[0, totalSegments)`.
  bool get isComplete => _chunks.length == totalSegments;

  /// True if [idx] has already been received.
  bool has(int idx) => _chunks.containsKey(idx);

  /// Insert or replace the chunk for [idx]. Updates lastUpdatedAt via [now].
  void put(int idx, String chunk, DateTime now) {
    _chunks[idx] = chunk;
    lastUpdatedAt = now;
  }

  /// Concatenate the chunks in index order and base64-decode.
  Uint8List assemble() {
    final ordered = StringBuffer();
    for (var i = 0; i < totalSegments; i++) {
      ordered.write(_chunks[i]!);
    }
    var encoded = ordered.toString();
    // Chunks arriving at non-base64-aligned boundaries may lack trailing
    // padding (a single `=` or `==`). Add it so the decoder accepts the
    // payload. This only affects boundary correctness, not content.
    final mod = encoded.length % 4;
    if (mod == 1) {
      // Cannot be valid base64 — odd-length residue is unrecoverable.
      throw FormatException('Invalid base64 payload length');
    } else if (mod != 0) {
      encoded = '$encoded${'=' * (4 - mod)}';
    }
    return base64.decode(encoded);
  }
}

/// Public face of the SMS reassembler. One instance per device is fine; it
/// is cheap and thread-safe-ish (single-threaded Dart isolate).
class Reassembler {
  Reassembler({
    Duration? inactivityTimeout,
    ReassemblerClock? clock,
  })  : inactivityTimeout = inactivityTimeout ?? const Duration(minutes: 10),
        _clock = clock ?? ReassemblerClock.system() {
    _messages = StreamController<ReassembledMessage>.broadcast(
      onListen: _startTicker,
      onCancel: _stopTicker,
    );
  }

  /// How long a msgid can sit incomplete before its buffer is evicted.
  final Duration inactivityTimeout;

  final ReassemblerClock _clock;
  final Map<String, _Buffer> _buffers = <String, _Buffer>{};
  final Set<String> _completed = <String>{}; // replay-suppression
  late final StreamController<ReassembledMessage> _messages;
  Timer? _ticker;

  int _rejectedCount = 0;
  int _duplicateCount = 0;
  int _completedCount = 0;

  /// Total number of malformed segments rejected (for telemetry/tests).
  int get rejectedCount => _rejectedCount;

  /// Total number of duplicate (msgid, idx) pairs silently dropped.
  int get duplicateCount => _duplicateCount;

  /// Total number of messages successfully emitted.
  int get completedCount => _completedCount;

  /// Ids currently in the buffer (incomplete).
  Iterable<String> get activeMessageIds => _buffers.keys;

  /// Stream of completed messages.
  Stream<ReassembledMessage> get messages => _messages.stream;

  /// Feed one segment string in. Format:
  /// `RL:<8-hex msgid>:<idx>/<total>:<base64-chunk>`.
  ///
  /// Returns true if the segment was accepted (placed in buffer or
  /// completed a message), false if it was rejected as malformed or
  /// silently dropped as a duplicate.
  bool ingest(String segment) {
    final parsed = _parse(segment);
    if (parsed == null) {
      _rejectedCount++;
      return false;
    }
    final messageId = parsed.messageId;
    final idx = parsed.idx;
    final total = parsed.total;
    final chunk = parsed.chunk;

    // Replay suppression: a completed msgid is treated as a no-op.
    if (_completed.contains(messageId)) {
      _duplicateCount++;
      return false;
    }

    final existing = _buffers[messageId];
    final now = _clock.nowUtc();
    if (existing == null) {
      // First segment seen for this msgid.
      final buf = _Buffer(
        messageId: messageId,
        totalSegments: total,
        firstSeenAt: now,
        lastUpdatedAt: now,
      );
      buf.put(idx, chunk, now);
      _buffers[messageId] = buf;
      _tryComplete(buf, now);
      return true;
    }

    // Validate total consistency.
    if (existing.totalSegments != total) {
      _rejectedCount++;
      return false;
    }

    if (existing.has(idx)) {
      _duplicateCount++;
      return false;
    }

    existing.put(idx, chunk, now);
    _tryComplete(existing, now);
    return true;
  }

  /// Manually evict any msgid whose last-update is older than the timeout.
  /// Returns the list of evicted msgids.
  ///
  /// This is also called periodically by the internal ticker when the
  /// stream has subscribers.
  List<String> flushExpired() {
    if (_buffers.isEmpty) return const <String>[];
    final now = _clock.nowUtc();
    final cutoff = now.subtract(inactivityTimeout);
    final evicted = <String>[];
    _buffers.removeWhere((id, buf) {
      if (buf.lastUpdatedAt.isBefore(cutoff)) {
        evicted.add(id);
        return true;
      }
      return false;
    });
    return evicted;
  }

  /// Cancels the internal ticker and closes the output stream. Idempotent.
  Future<void> dispose() async {
    _ticker?.cancel();
    _ticker = null;
    if (!_messages.isClosed) {
      await _messages.close();
    }
  }

  // --- internals ----------------------------------------------------------

  void _tryComplete(_Buffer buf, DateTime now) {
    if (!buf.isComplete) return;
    final payload = buf.assemble();
    final id = buf.messageId;
    _buffers.remove(id);
    _completed.add(id);
    _completedCount++;
    if (!_messages.isClosed) {
      _messages.add(ReassembledMessage(
        messageId: id,
        totalSegments: buf.totalSegments,
        segmentCount: buf.totalSegments,
        payloadBytes: payload,
        assembledAt: now,
      ));
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    // Tick at a fraction of the timeout to balance responsiveness and cost.
    final interval = inactivityTimeout ~/ 6;
    _ticker = Timer.periodic(
      interval < Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : interval,
      (_) => flushExpired(),
    );
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Parsed segment fields.
  static _Parsed? _parse(String segment) {
    if (segment.isEmpty) return null;
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return null;

    // Header must be exactly 3 colon-separated parts: meta, index, chunk.
    // Meta: 'RL:XXXXXXXX', idx: 'NN/NN', chunk: any base64 (including empty).
    if (!trimmed.startsWith('RL:')) return null;
    const headerPrefix = 'RL:';
    final headerStart = headerPrefix.length;
    final headerEnd = trimmed.indexOf(':', headerStart);
    if (headerEnd < 0) return null;
    final msgId = trimmed.substring(headerStart, headerEnd);
    if (msgId.length != 8) return null;
    if (!_isHex(msgId)) return null;

    final idxStart = headerEnd + 1;
    final idxEnd = trimmed.indexOf(':', idxStart);
    if (idxEnd < 0) return null;
    final idxPart = trimmed.substring(idxStart, idxEnd);
    final slash = idxPart.indexOf('/');
    if (slash < 0) return null;
    final idxStr = idxPart.substring(0, slash);
    final totalStr = idxPart.substring(slash + 1);
    final idx = int.tryParse(idxStr);
    final total = int.tryParse(totalStr);
    if (idx == null || total == null) return null;
    if (total <= 0) return null;
    if (idx < 0 || idx >= total) return null;

    final chunk = trimmed.substring(idxEnd + 1);
    // Empty chunk is valid for single-segment messages only (the whole
    // payload may legitimately be empty). For multi-segment, an empty chunk
    // would be a malformed frame.
    if (chunk.isEmpty && total > 1) return null;
    // Validate that every character is in the base64 alphabet (incl. `=`).
    // We can't decode individual chunks because they may not be aligned
    // to a 4-character boundary — alignment is restored only when all
    // chunks are concatenated at buffer completion.
    if (!_isBase64Alphabet(chunk)) return null;

    return _Parsed(messageId: msgId, idx: idx, total: total, chunk: chunk);
  }

  static bool _isHex(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLower = c >= 0x61 && c <= 0x66;
      final isUpper = c >= 0x41 && c <= 0x46;
      if (!isDigit && !isLower && !isUpper) return false;
    }
    return true;
  }

  static bool _isBase64Alphabet(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final isUpper = c >= 0x41 && c <= 0x5A;
      final isLower = c >= 0x61 && c <= 0x7A;
      final isDigit = c >= 0x30 && c <= 0x39;
      final isPlus = c == 0x2B;
      final isSlash = c == 0x2F;
      final isEq = c == 0x3D;
      if (!isUpper && !isLower && !isDigit && !isPlus && !isSlash && !isEq) {
        return false;
      }
    }
    return true;
  }
}

class _Parsed {
  _Parsed({
    required this.messageId,
    required this.idx,
    required this.total,
    required this.chunk,
  });
  final String messageId;
  final int idx;
  final int total;
  final String chunk;
}
