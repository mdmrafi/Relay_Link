// Bloom filter for mesh relay seen-cache (spec §7).
//
// Sizing math (canonical Bloom filter formulas):
//   n = expected entries = 2000
//   p = target false positive rate = 0.01
//   m = number of bits = -n * ln(p) / (ln(2)^2)
//                     = -2000 * ln(0.01) / (ln(2)^2)
//                     = -2000 * (-4.60517) / (0.48045)
//                     = 19,170.08 bits -> ceil -> 19,171 bits
//   k = number of hash functions = (m / n) * ln(2)
//                                = (19171 / 2000) * 0.69315
//                                = 6.6433 -> ceil -> 7 hash functions
//
// At capacity, theoretical FPR = (1 - exp(-k*n/m))^k ≈ 0.00808 (≈ 0.81%).
// Bytes needed = ceil(m/8) = 2397 bytes (≈ 19 kbit, per spec §7).
//
// Hash choice: xxhash was considered but NOT pre-declared in pubspec.yaml
// (HANDOFF.md explicitly excludes it). We use two independent FNV-1a variants
// over UTF-8 bytes to derive the k=7 bit indices via the standard
// double-hashing scheme: h_i(x) = (h1(x) + i * h2(x)) mod m.
// IDs are random UUIDs per ticket #04, so cryptographic strength is not
// required — only independence and uniformity across the bit space.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

class BloomFilter {
  /// Expected number of inserted entries.
  static const int expectedEntries = 2000;

  /// Target false positive rate.
  static const double targetFpr = 0.01;

  /// Number of bits in the filter (m = ceil(-n*ln(p)/(ln(2)^2)) for n=2000, p=0.01).
  static const int mBits = 19171;

  /// Number of hash functions (k = ceil((m/n)*ln(2))).
  static const int kHashes = 7;

  /// Number of bytes needed to store the bit array (ceil(m/8)).
  static const int byteLength = (mBits + 7) >> 3; // 2397

  /// FNV-1a 64-bit constants (different offset_basis / prime for the second
  /// variant to keep the two hashes independent).
  static const int _fnv1aOffset1 = 0xcbf29ce484222325;
  static const int _fnv1aPrime1 = 0x100000001b3;
  static const int _fnv1aOffset2 = 0x6c62272e07bb0142; // arbitrary independent seed
  static const int _fnv1aPrime2 = 0x00000100000001b3; // same prime, different offset

  final Uint8List _bits;

  BloomFilter._(this._bits);

  /// Creates an empty filter with all bits cleared.
  factory BloomFilter.empty() {
    return BloomFilter._(Uint8List(byteLength));
  }

  /// Inserts an ID (String or bytes) into the filter.
  void insert(Object id) {
    final (h1, h2) = _hashPair(id);
    for (var i = 0; i < kHashes; i++) {
      // Combine the two hashes using the Kirsch-Mitzenmacher double-hashing
      // trick: gi(x) = h1(x) + i * h2(x). This is provably as good as
      // k truly independent hashes for uniform inputs.
      final combined = (h1 + i * h2) & 0x7FFFFFFFFFFFFFFF; // mask to non-negative
      final bitIndex = combined % mBits;
      _setBit(bitIndex);
    }
  }

  /// Returns whether the ID *might* be in the set.
  /// False positives are possible; false negatives are not.
  bool mightContain(Object id) {
    final (h1, h2) = _hashPair(id);
    for (var i = 0; i < kHashes; i++) {
      final combined = (h1 + i * h2) & 0x7FFFFFFFFFFFFFFF;
      final bitIndex = combined % mBits;
      if (!_getBit(bitIndex)) return false;
    }
    return true;
  }

  /// Encodes the filter to a compact byte representation:
  ///   [magic 0xB1] [kHashes 1B] [mBits 4B BE] [bits ceil(m/8) bytes]
  /// Round-trippable via [decode]. ~2397 B + 6 B header per filter.
  Uint8List encode() {
    final out = Uint8List(6 + byteLength);
    out[0] = 0xB1; // magic so we can detect garbage
    out[1] = kHashes;
    // Big-endian 32-bit mBits
    out[2] = (mBits >> 24) & 0xFF;
    out[3] = (mBits >> 16) & 0xFF;
    out[4] = (mBits >> 8) & 0xFF;
    out[5] = mBits & 0xFF;
    out.setRange(6, 6 + byteLength, _bits);
    return out;
  }

  /// Inverse of [encode]. Throws [FormatException] on malformed input.
  static BloomFilter decode(Uint8List bytes) {
    if (bytes.length < 6) {
      throw FormatException('Bloom filter too short: ${bytes.length} bytes');
    }
    if (bytes[0] != 0xB1) {
      throw FormatException('Bad magic: 0x${bytes[0].toRadixString(16)}');
    }
    if (bytes[1] != kHashes) {
      throw FormatException(
          'k mismatch: got ${bytes[1]}, expected $kHashes');
    }
    final m =
        (bytes[2] << 24) | (bytes[3] << 16) | (bytes[4] << 8) | bytes[5];
    if (m != mBits) {
      throw FormatException('m mismatch: got $m, expected $mBits');
    }
    if (bytes.length != 6 + byteLength) {
      throw FormatException(
          'Length mismatch: got ${bytes.length}, expected ${6 + byteLength}');
    }
    final bits = Uint8List.fromList(bytes.sublist(6));
    return BloomFilter._(bits);
  }

  /// Boolean OR of two filters of identical sizing into a new filter.
  /// Used to compute symmetric difference: `A ∪ B` represents the union of
  /// all IDs known to either side, so `A.mightContain(x) && B.mightContain(x)`
  /// is true exactly for the symmetric difference `A ∆ B`.
  BloomFilter union(BloomFilter other) {
    if (other._bits.length != _bits.length) {
      throw ArgumentError('Bloom filter size mismatch');
    }
    final out = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      out[i] = _bits[i] | other._bits[i];
    }
    return BloomFilter._(out);
  }

  // --- Internal helpers ---

  void _setBit(int bitIndex) {
    final byteIndex = bitIndex >> 3;
    final mask = 1 << (bitIndex & 7);
    _bits[byteIndex] |= mask;
  }

  bool _getBit(int bitIndex) {
    final byteIndex = bitIndex >> 3;
    final mask = 1 << (bitIndex & 7);
    return (_bits[byteIndex] & mask) != 0;
  }

  Uint8List _toBytes(Object id) {
    if (id is Uint8List) return id;
    if (id is List<int>) return Uint8List.fromList(id);
    if (id is String) return Uint8List.fromList(utf8.encode(id));
    throw ArgumentError('Unsupported id type: ${id.runtimeType}');
  }

  /// Returns (h1, h2) where each is a non-negative 63-bit integer derived
  /// from two independent FNV-1a variants over the same input bytes.
  (int, int) _hashPair(Object id) {
    final bytes = _toBytes(id);
    return (
      _fnv1a(bytes, _fnv1aOffset1, _fnv1aPrime1) & 0x7FFFFFFFFFFFFFFF,
      _fnv1a(bytes, _fnv1aOffset2, _fnv1aPrime2) & 0x7FFFFFFFFFFFFFFF,
    );
  }

  /// FNV-1a 64-bit hash. Simple, fast, no dependency on xxhash.
  /// Not cryptographically secure — Bloom does not need that.
  static int _fnv1a(Uint8List bytes, int offset, int prime) {
    var hash = offset & 0xFFFFFFFFFFFFFFFF;
    for (final b in bytes) {
      hash = (hash ^ (b & 0xFF)) & 0xFFFFFFFFFFFFFFFF;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash;
  }

  /// Estimated number of distinct entries currently in the filter.
  /// Useful for tests and diagnostics.
  int estimateCount() {
    final setBits = _countSetBits();
    if (setBits == 0) return 0;
    // m * (-k / n) = ln(1 - setBits/m) -> n = -m/k * ln(1 - setBits/m)
    final ratio = setBits / mBits;
    if (ratio >= 1.0) return expectedEntries;
    return (-mBits / kHashes * math.log(1 - ratio)).round();
  }

  int _countSetBits() {
    var count = 0;
    for (final b in _bits) {
      var x = b;
      while (x != 0) {
        x &= x - 1;
        count++;
      }
    }
    return count;
  }

  /// Number of bits set to 1 (popcount). Exposed for testing/diagnostics.
  int popcount() => _countSetBits();
}
