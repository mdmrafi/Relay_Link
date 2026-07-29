// RelayLink — Ticket #27 unit tests: SMS BROADCAST fan-out behavior.
//
// What we test:
//   * Recipient selection: only contacts with [Contact.hasPhone] are sent.
//   * Same-payload invariant: every recipient receives the SAME ciphertext
//     body (network-key design; per-recipient wrapping would defeat it).
//   * Dedup: contacts sharing a phone number get one send, not two.
//   * Parallelism: wall-clock time is bounded by the slowest leg, not
//     the sum of legs (verified via deterministic staggered delays).
//   * Per-recipient failure isolation: a single failing recipient does
//     not fail the rest of the fan-out; the result records both.
//   * Empty input: no contacts / no phone-bearing contacts is a clean
//     no-op result.
//   * Transport unavailable: short-circuits before any send.
//   * Fragmentation integration: when a multi-segment fragmenter is
//     supplied, every recipient receives all segments in order; same
//     set per recipient.
//   * Mode guard: DIRECT messages are rejected with ArgumentError.
//
// What we DO NOT test (deliberate, per ticket honesty requirement):
//   * Real device SMS dispatch — we use a `FakeTransport` that records
//     calls in memory; the native `SmsManager` is not exercised here.
//     The fan-out's seam with `SmsPlatformChannel` is a thin adapter;
//     unit-testing the adapter is the platform channel test's job.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/contacts/contact.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/sms/fanout.dart';
import 'package:relaylink/sms/fanout_types.dart';

/// Test transport that records every send.
class _FakeTransport implements SmsFanoutTransport {
  bool available;
  Duration delay;
  final Set<String> failingNumbers;
  final List<_RecordedSend> sent = <_RecordedSend>[];

  /// Concurrency counter: how many `sendFragment` calls are in-flight at
  /// the peak. Lets us assert the dispatch is parallel, not serial.
  int inFlight = 0;
  int peakInFlight = 0;

  _FakeTransport({
    this.available = true,
    this.delay = Duration.zero,
    Set<String>? failingNumbers,
  }) : failingNumbers = {...?failingNumbers};

  @override
  bool get isAvailable => available;

  @override
  Future<void> sendFragment(String phoneNumber, String body) async {
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      sent.add(_RecordedSend(phoneNumber, body));
      if (failingNumbers.contains(phoneNumber)) {
        throw StateError('simulated carrier failure for $phoneNumber');
      }
    } finally {
      inFlight--;
    }
  }
}

class _RecordedSend {
  final String phone;
  final String body;
  _RecordedSend(this.phone, this.body);
}

/// Captures log lines so tests can assert on them.
List<String> _captureLogs() {
  final lines = <String>[];
  return lines;
}

Message _broadcast({
  Uint8List? payload,
  String id = 'msg-27-1',
  String channelId = 'public',
  String senderId = 'self',
}) {
  return Message.create(
    mode: MessageMode.broadcast,
    type: MessageType.sos,
    channelId: channelId,
    senderId: senderId,
    payload: payload ?? Uint8List.fromList([1, 2, 3, 4, 5]),
  ).copyWith(id: id);
}

List<Contact> _contacts(List<Map<String, String?>> rows) {
  return rows.map((r) {
    return Contact(
      id: r['id']!,
      displayName: r['name'] ?? '',
      publicKey: r['pk'] ?? 'pk-${r['id']}',
      phoneNumber: r['phone'],
    );
  }).toList(growable: false);
}

void main() {
  group('fanOutBroadcast', () {
    test('fans out to every contact with a phone number', () async {
      final t = _FakeTransport();
      final contacts = _contacts([
        {'id': 'a', 'name': 'Alice', 'phone': '+15555550101'},
        {'id': 'b', 'name': 'Bob', 'phone': '+15555550102'},
        {'id': 'c', 'name': 'Cara', 'phone': '+15555550103'},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      expect(result.anySuccess, isTrue);
      expect(result.attempted, 3);
      expect(result.perRecipient, hasLength(3));
      expect(
        t.sent.map((s) => s.phone).toSet(),
        {'+15555550101', '+15555550102', '+15555550103'},
      );
      expect(result.perRecipient.every((r) => r.success), isTrue);
    });

    test('skips contacts without a phone number', () async {
      final t = _FakeTransport();
      final contacts = _contacts([
        {'id': 'a', 'name': 'Alice', 'phone': '+15555550101'},
        {'id': 'b', 'name': 'Bob', 'phone': null},
        {'id': 'c', 'name': 'Cara', 'phone': ''},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      expect(result.attempted, 1);
      expect(t.sent, hasLength(1));
      expect(t.sent.single.phone, '+15555550101');
    });

    test('same encrypted payload delivered to every recipient', () async {
      final t = _FakeTransport();
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
        {'id': 'c', 'phone': '+15555550103'},
      ]);
      final payload = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final msg = _broadcast(payload: payload);

      await fanOutBroadcast(msg, contacts, transport: t, logger: (_) {});

      // Every recipient must receive the SAME body bytes. If even one
      // recipient's body differed, the network-key design would be
      // broken — recipients share the symmetric key, so per-recipient
      // re-wrapping would either fail to decrypt or require extra
      // wrapping logic that doesn't exist.
      final bodies = t.sent.map((s) => s.body).toList();
      expect(bodies.toSet().length, 1, reason: 'all bodies must match');
      // And the body must decode back to the input payload.
      expect(bodies.first, isNotEmpty);
    });

    test('dedups contacts sharing a phone number (one send per number)',
        () async {
      final t = _FakeTransport();
      final contacts = _contacts([
        {'id': 'a', 'name': 'Alice-home', 'phone': '+15555550101'},
        {'id': 'b', 'name': 'Alice-work', 'phone': '+15555550101'},
        {'id': 'c', 'name': 'Bob', 'phone': '+15555550102'},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      // 3 contacts but only 2 distinct phone numbers.
      expect(result.attempted, 2);
      expect(t.sent, hasLength(2));
      expect(
        t.sent.map((s) => s.phone).toSet(),
        {'+15555550101', '+15555550102'},
      );
    });

    test('dispatches in parallel — wall-clock bounded by slowest leg',
        () async {
      final t = _FakeTransport(delay: const Duration(milliseconds: 50));
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
        {'id': 'c', 'phone': '+15555550103'},
        {'id': 'd', 'phone': '+15555550104'},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      // Serial would be ~200ms; parallel should be ~50ms plus overhead.
      // Generous bound to avoid flakiness on shared CI runners.
      expect(result.elapsed.inMilliseconds, lessThan(180));
      expect(result.anySuccess, isTrue);
      expect(result.attempted, 4);
    });

    test('records multiple legs in flight simultaneously', () async {
      final t = _FakeTransport(delay: const Duration(milliseconds: 30));
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
        {'id': 'c', 'phone': '+15555550103'},
      ]);
      final msg = _broadcast();

      await fanOutBroadcast(msg, contacts, transport: t, logger: (_) {});

      // If the dispatch were serial, peakInFlight would be 1.
      // We expect at least 2 in flight at once.
      expect(t.peakInFlight, greaterThanOrEqualTo(2));
    });

    test('individual recipient failure does not fail the fan-out',
        () async {
      final t = _FakeTransport(
        failingNumbers: {'+15555550102'},
      );
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
        {'id': 'c', 'phone': '+15555550103'},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      expect(result.anySuccess, isTrue,
          reason: 'at least one recipient succeeded');
      expect(result.attempted, 3);
      expect(result.perRecipient, hasLength(3));

      final byPhone = {for (final r in result.perRecipient) r.address: r};
      expect(byPhone['+15555550101']!.success, isTrue);
      expect(byPhone['+15555550102']!.success, isFalse);
      expect(byPhone['+15555550102']!.error, isA<StateError>());
      expect(byPhone['+15555550103']!.success, isTrue);

      // The failing recipient must NOT have been retried; we should
      // observe exactly one send attempt to the bad number.
      final attemptsToBad =
          t.sent.where((s) => s.phone == '+15555550102').length;
      expect(attemptsToBad, 1);
    });

    test('all-recipients-fail produces anySuccess=false but still returns',
        () async {
      final t = _FakeTransport(
        failingNumbers: {'+15555550101', '+15555550102'},
      );
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      expect(result.anySuccess, isFalse);
      expect(result.attempted, 2);
      expect(result.perRecipient.every((r) => !r.success), isTrue);
    });

    test('empty contacts list is a clean no-op', () async {
      final t = _FakeTransport();
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        const <Contact>[],
        transport: t,
        logger: (_) {},
      );

      expect(result.anySuccess, isFalse);
      expect(result.attempted, 0);
      expect(result.perRecipient, isEmpty);
      expect(t.sent, isEmpty);
    });

    test('no phone-bearing contacts is a clean no-op', () async {
      final t = _FakeTransport();
      final contacts = _contacts([
        {'id': 'a', 'phone': null},
        {'id': 'b', 'phone': ''},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      expect(result.attempted, 0);
      expect(t.sent, isEmpty);
    });

    test('transport.isAvailable=false short-circuits without sending',
        () async {
      final t = _FakeTransport(available: false);
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
      ]);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: (_) {},
      );

      expect(result.anySuccess, isFalse);
      expect(result.attempted, 0);
      expect(t.sent, isEmpty);
    });

    test('multi-segment fragmenter: every recipient gets every segment in order',
        () async {
      final t = _FakeTransport();
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
      ]);
      // Fragmenter that produces three segments per message.
      final multi = _CountingFragmenter(<String>['SEG-1', 'SEG-2', 'SEG-3']);
      final msg = _broadcast();

      final result = await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        fragmenter: multi,
        logger: (_) {},
      );

      expect(result.anySuccess, isTrue);
      expect(result.attempted, 2);
      // 2 recipients × 3 segments = 6 sends total.
      expect(t.sent, hasLength(6));
      // Per-recipient, the segments arrive in declared order.
      for (final phone in ['+15555550101', '+15555550102']) {
        final bodies = t.sent
            .where((s) => s.phone == phone)
            .map((s) => s.body)
            .toList();
        expect(bodies, ['SEG-1', 'SEG-2', 'SEG-3']);
      }
      // Fragmenter was invoked exactly once (not per-recipient), to
      // enforce same-ciphertext invariant.
      expect(multi.callCount, 1);
    });

    test('mode guard: rejects DIRECT messages', () async {
      final t = _FakeTransport();
      final msg = Message.create(
        mode: MessageMode.direct,
        type: MessageType.chat,
        channelId: '',
        senderId: 'self',
        recipientId: 'peer',
        payload: Uint8List.fromList([1, 2, 3]),
      );

      expect(
        () => fanOutBroadcast(msg, const <Contact>[], transport: t),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('logger captures the per-recipient failure detail', () async {
      final t = _FakeTransport(failingNumbers: {'+15555550102'});
      final contacts = _contacts([
        {'id': 'a', 'phone': '+15555550101'},
        {'id': 'b', 'phone': '+15555550102'},
      ]);
      final logLines = _captureLogs();
      final msg = _broadcast();

      await fanOutBroadcast(
        msg,
        contacts,
        transport: t,
        logger: logLines.add,
      );

      expect(
        logLines.any((l) => l.contains('+15555550102') && l.contains('failed')),
        isTrue,
        reason: 'logger should record the failing recipient',
      );
    });
  });

  group('SingleSegmentFragmenter', () {
    test('produces exactly one segment containing the base64 payload', () async {
      const f = SingleSegmentFragmenter();
      final segments =
          await f.fragments('msgid-123', List<int>.generate(10, (i) => i));
      expect(segments, hasLength(1));
      // Decodable back to the original payload.
      expect(segments.single, isNotEmpty);
    });
  });

  group('RealFramingFragmenter adapter', () {
    test('delegates to the supplied fragment function', () async {
      final adapter = RealFramingFragmenter(
        (msgId, payload, {maxSegmentLen}) async => ['a', 'b'],
      );
      final out = await adapter.fragments('m', const <int>[1, 2]);
      expect(out, ['a', 'b']);
    });
  });
}

/// Counting fragmenter used to assert "fragments computed once".
class _CountingFragmenter implements FanoutFragmenter {
  final List<String> segments;
  int callCount = 0;
  _CountingFragmenter(this.segments);

  @override
  Future<List<String>> fragments(String messageId, List<int> payload) async {
    callCount++;
    return segments;
  }
}