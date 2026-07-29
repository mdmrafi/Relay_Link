// Tests for the Bloom filter (Ticket #10).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/mesh/bloom.dart';

void main() {
  group('BloomFilter sizing', () {
    test('mBits and kHashes match the documented formulas', () {
      // m = ceil(-n * ln(p) / (ln(2)^2))
      const n = BloomFilter.expectedEntries;
      const p = BloomFilter.targetFpr;
      final mExpected = (-n * math.log(p) / (math.log(2) * math.log(2))).ceil();
      final kExpected = ((mExpected / n) * math.log(2)).ceil();
      expect(BloomFilter.mBits, mExpected);
      expect(BloomFilter.kHashes, kExpected);
      expect(BloomFilter.byteLength, (BloomFilter.mBits + 7) >> 3);
    });

    test('empty filter has zero popcount', () {
      final f = BloomFilter.empty();
      expect(f.popcount(), 0);
    });
  });

  group('insert / mightContain', () {
    test('inserted IDs always report as present (no false negatives)', () {
      final f = BloomFilter.empty();
      const ids = ['alpha', 'beta', 'gamma', 'delta', 'epsilon'];
      for (final id in ids) {
        f.insert(id);
      }
      for (final id in ids) {
        expect(f.mightContain(id), isTrue, reason: '$id should be present');
      }
    });

    test('accepts String and Uint8List IDs', () {
      final f = BloomFilter.empty();
      f.insert('hello');
      f.insert(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(f.mightContain('hello'), isTrue);
      expect(f.mightContain(Uint8List.fromList([1, 2, 3, 4, 5])), isTrue);
      expect(f.mightContain('missing'), isFalse);
    });
  });

  group('false positive rate', () {
    test('FPR < 2% on 1000 unseen IDs after inserting 2000 random IDs', () {
      // Re-run several trials to be confident the bound holds across seeds.
      final rng = math.Random(0xB100C0DE);
      const trials = 5;
      var worstFpr = 0.0;
      for (var t = 0; t < trials; t++) {
        final f = BloomFilter.empty();
        const n = 2000;
        const q = 1000;
        final inserted = <String>[];
        for (var i = 0; i < n; i++) {
          final id = _randomUuid(rng);
          f.insert(id);
          inserted.add(id);
        }
        final insertedSet = inserted.toSet();
        final unseen = <String>[];
        while (unseen.length < q) {
          final candidate = _randomUuid(rng);
          if (!insertedSet.contains(candidate)) unseen.add(candidate);
        }
        final fp = unseen.where(f.mightContain).length;
        final fpr = fp / q;
        if (fpr > worstFpr) worstFpr = fpr;
        expect(fpr, lessThan(0.02),
            reason: 'trial $t: FPR $fpr > 2% (fp=$fp/$q)');
        // Also assert no false negatives, sanity.
        expect(inserted.every(f.mightContain), isTrue);
      }
      // Sanity log: the worst observed FPR across all trials.
      // ignore: avoid_print
      print('Bloom worst FPR over $trials trials: '
          '${(worstFpr * 100).toStringAsFixed(2)}%');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('encode / decode', () {
    test('round-trips an empty filter', () {
      final f = BloomFilter.empty();
      final bytes = f.encode();
      expect(bytes.length, 6 + BloomFilter.byteLength);
      final g = BloomFilter.decode(bytes);
      expect(g.popcount(), 0);
      expect(g.mightContain('anything'), isFalse);
    });

    test('round-trips a populated filter exactly', () {
      final f = BloomFilter.empty();
      for (var i = 0; i < 100; i++) {
        f.insert('id-$i');
      }
      final bytes = f.encode();
      final g = BloomFilter.decode(bytes);
      expect(g.popcount(), f.popcount());
      for (var i = 0; i < 100; i++) {
        expect(g.mightContain('id-$i'), isTrue);
      }
      expect(g.mightContain('id-101'), isFalse);
    });

    test('decode rejects malformed input', () {
      expect(() => BloomFilter.decode(Uint8List(0)),
          throwsA(isA<FormatException>()));
      expect(() => BloomFilter.decode(Uint8List.fromList([0xFF, 0, 0, 0, 0, 0])),
          throwsA(isA<FormatException>()));
      expect(
        () => BloomFilter.decode(
            Uint8List(6 + BloomFilter.byteLength)..[0] = 0xB1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('union (symmetric difference)', () {
    test('union contains all inserts from both filters', () {
      final a = BloomFilter.empty();
      final b = BloomFilter.empty();
      for (var i = 0; i < 50; i++) {
        a.insert('a-$i');
      }
      for (var i = 0; i < 50; i++) {
        b.insert('b-$i');
      }
      final u = a.union(b);
      for (var i = 0; i < 50; i++) {
        expect(u.mightContain('a-$i'), isTrue);
        expect(u.mightContain('b-$i'), isTrue);
      }
      // Either-side-present test (A ∪ B):
      final unique = <String>{
        for (var i = 0; i < 50; i++) 'a-$i',
        'b-0',
        'b-49',
      };
      for (final id in unique) {
        expect(u.mightContain(id), isTrue);
      }
    });

    test('union OR-s the bit arrays (popcount <= sum of individual popcounts)',
        () {
      final a = BloomFilter.empty();
      final b = BloomFilter.empty();
      for (var i = 0; i < 200; i++) {
        a.insert('a-$i');
        b.insert('b-$i');
      }
      final u = a.union(b);
      expect(u.popcount(), lessThanOrEqualTo(a.popcount() + b.popcount()));
    });

    test('union of disjoint filters has popcount <= sum of individual popcounts',
        () {
      final a = BloomFilter.empty();
      final b = BloomFilter.empty();
      final rng = math.Random(42);
      for (var i = 0; i < 500; i++) {
        a.insert(_randomUuid(rng));
      }
      for (var i = 0; i < 500; i++) {
        b.insert(_randomUuid(rng));
      }
      final u = a.union(b);
      // The OR of two bitsets is at most the sum of their popcounts
      // (and strictly less whenever there is any overlap).
      expect(u.popcount(), lessThanOrEqualTo(a.popcount() + b.popcount()));
      // And it must be at least max(a, b) — every bit in either input is set.
      expect(u.popcount(),
          greaterThanOrEqualTo(math.max(a.popcount(), b.popcount())));
      // With 500+500 ≈ 1000 inserts in a 19,171-bit filter, the union should
      // be near-saturated but not exceed mBits.
      expect(u.popcount(), lessThanOrEqualTo(BloomFilter.mBits));
    });
  });
}

String _randomUuid(math.Random rng) {
  // Generate a 36-char random hex string shaped like a UUIDv4.
  const hex = '0123456789abcdef';
  final sb = StringBuffer();
  for (var i = 0; i < 36; i++) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      sb.write('-');
    } else {
      sb.write(hex[rng.nextInt(16)]);
    }
  }
  return sb.toString();
}
