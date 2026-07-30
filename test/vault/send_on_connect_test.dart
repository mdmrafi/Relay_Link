// RelayLink — Ticket #33 vault send-on-connect tests.
//
// Exercises the success criteria from .scratch/relaylink-build/issues/33
// using a `FakeVaultSource` (in-memory) and a `FakeTransport`. We don't
// touch the real `lib/vault/store.dart` AES-GCM plumbing from these
// tests — the deliverer talks to a `VaultSendSource` interface, so the
// fake is enough to drive every branch of the deliverer.
//
// What this proves:
//   1. When a transport is available, pending records (recipient != null,
//      status != 'sent') are queued for delivery.
//   2. Each queued record produces exactly one DIRECT Message with the
//      encrypted plaintext in `payload` and an EVIDENCE_NOTICE envelope.
//   3. Successful transport.send() flips the record's status to 'sent'.
//   4. Failed transport.send() leaves status unchanged for the next
//      attempt.
//   5. Self-captured records (recipientId == null) are ignored — the
//      vault never tries to deliver them to a peer.
//   6. Already-sent records are not re-delivered.
//   7. When the transport is NOT available, no send is attempted.
//   8. A decrypt failure does not throw and does not block the rest of
//      the queue.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';
import 'package:relaylink/vault/send_on_connect.dart';

void main() {
  group('VaultSendOnConnect', () {
    test('empty vault: no messages sent, no errors', () async {
      final source = FakeVaultSource();
      final transport = FakeTransport();
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      await sender.onChannelAvailable();

      expect(transport.sent, isEmpty);
      expect(encryptor.calls, isEmpty);
    });

    test('one pending record: decrypts, encrypts DIRECT, sends, marks sent',
        () async {
      final source = FakeVaultSource();
      final transport = FakeTransport();
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      source.addPending(
        id: 'rec-1',
        recipientId: 'verified-org-1',
        plaintext: utf8Bytes('evidence text 1'),
      );

      await sender.onChannelAvailable();

      expect(encryptor.calls, hasLength(1));
      expect(encryptor.calls.single.recipientId, 'verified-org-1');
      expect(
        utf8.decode(encryptor.calls.single.plaintext),
        'evidence text 1',
      );

      expect(transport.sent, hasLength(1));
      final msg = transport.sent.single;
      expect(msg.mode, MessageMode.direct);
      expect(msg.type, MessageType.evidenceNotice);
      expect(msg.recipientId, 'verified-org-1');
      expect(msg.senderId, 'device-a');
      // DIRECT envelope must carry the ratchet header so the recipient
      // can advance its chain.
      expect(msg.ratchetHeader, isA<Uint8List>());
      expect(msg.ratchetHeader, isNotEmpty);
      // Payload must be the ciphertext (not plaintext).
      expect(
        utf8.decode(msg.payload),
        isNot('evidence text 1'),
        reason: 'ciphertext must not contain plaintext bytes',
      );
      // The fake encryptor returns a recognisable ciphertext; verify the
      // message actually carried it.
      expect(utf8.decode(msg.payload), 'FAKE-CT:evidence text 1');

      expect(source.statusOf('rec-1'), 'sent');
    });

    test('multiple pending records: all delivered and all marked sent',
        () async {
      final source = FakeVaultSource();
      final transport = FakeTransport();
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      source.addPending(
        id: 'rec-1',
        recipientId: 'peer-1',
        plaintext: utf8Bytes('first'),
      );
      source.addPending(
        id: 'rec-2',
        recipientId: 'peer-2',
        plaintext: utf8Bytes('second'),
      );
      source.addPending(
        id: 'rec-3',
        recipientId: 'peer-3',
        plaintext: utf8Bytes('third'),
      );

      await sender.onChannelAvailable();

      expect(transport.sent, hasLength(3));
      expect(
        transport.sent.map((m) => m.recipientId).toList(),
        <String?>['peer-1', 'peer-2', 'peer-3'],
      );
      expect(source.statusOf('rec-1'), 'sent');
      expect(source.statusOf('rec-2'), 'sent');
      expect(source.statusOf('rec-3'), 'sent');
    });

    test('transport failure: record status is unchanged', () async {
      final source = FakeVaultSource();
      final transport = FakeTransport(throwOnSend: true);
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      source.addPending(
        id: 'rec-1',
        recipientId: 'peer-1',
        plaintext: utf8Bytes('hello'),
      );

      await sender.onChannelAvailable();

      // The transport threw — the source must NOT have been told the
      // record was delivered. It stays in 'pending' so the next
      // onChannelAvailable() retries it.
      expect(source.statusOf('rec-1'), 'pending');
      expect(source.markSentCalls, 0);
    });

    test('partial failure: only successful sends mark records as sent',
        () async {
      final source = FakeVaultSource();
      final transport = FakeTransport();
      // Fail only when sending to peer-2 — we match on the recipient id
      // embedded in the message envelope.
      transport.failForRecipientIds.add('peer-2');
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      source.addPending(
        id: 'rec-1',
        recipientId: 'peer-1',
        plaintext: utf8Bytes('first'),
      );
      source.addPending(
        id: 'rec-2',
        recipientId: 'peer-2',
        plaintext: utf8Bytes('second'),
      );
      source.addPending(
        id: 'rec-3',
        recipientId: 'peer-3',
        plaintext: utf8Bytes('third'),
      );

      await sender.onChannelAvailable();

      expect(source.statusOf('rec-1'), 'sent');
      expect(source.statusOf('rec-2'), 'pending');
      expect(source.statusOf('rec-3'), 'sent');
    });

    test('self-encrypted records (recipientId == null) are skipped',
        () async {
      final source = FakeVaultSource();
      // Seed a "self" record directly. The fake stores it but
      // listPendingForDelivery() should filter it out.
      source.addSelf(id: 'rec-self', plaintext: utf8Bytes('self note'));

      final transport = FakeTransport();
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      await sender.onChannelAvailable();

      expect(transport.sent, isEmpty);
      expect(encryptor.calls, isEmpty);
      expect(source.statusOf('rec-self'), 'pending');
    });

    test('already-sent records are not re-delivered', () async {
      final source = FakeVaultSource();
      source.addPending(
        id: 'rec-1',
        recipientId: 'peer-1',
        plaintext: utf8Bytes('already sent'),
        status: 'sent',
      );

      final transport = FakeTransport();
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      await sender.onChannelAvailable();

      expect(transport.sent, isEmpty);
      expect(encryptor.calls, isEmpty);
    });

    test('unavailable transport: nothing is sent, statuses unchanged',
        () async {
      final source = FakeVaultSource();
      source.addPending(
        id: 'rec-1',
        recipientId: 'peer-1',
        plaintext: utf8Bytes('hello'),
      );

      final transport = FakeTransport(available: false);
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      await sender.onChannelAvailable();

      expect(transport.sent, isEmpty);
      expect(encryptor.calls, isEmpty);
      expect(source.statusOf('rec-1'), 'pending');
    });

    test('decrypt failure leaves status unchanged and continues', () async {
      final source = FakeVaultSource();
      source.addPending(
        id: 'rec-bad',
        recipientId: 'peer-1',
        plaintext: utf8Bytes('corrupted'),
      );
      source.failDecryptIds.add('rec-bad');
      // A second, good record should still flow through.
      source.addPending(
        id: 'rec-ok',
        recipientId: 'peer-2',
        plaintext: utf8Bytes('fine'),
      );

      final transport = FakeTransport();
      final encryptor = FakeEncryptor();
      final sender = VaultSendOnConnect(
        source: source,
        transport: transport,
        encryptor: encryptor,
        senderId: 'device-a',
      );

      // Should not throw — the deliverer logs and moves on so one bad
      // record can't block the rest of the queue.
      await sender.onChannelAvailable();

      expect(source.statusOf('rec-bad'), 'pending');
      expect(source.statusOf('rec-ok'), 'sent');
      // Only the good record produced a transport send.
      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.recipientId, 'peer-2');
    });
  });
}

// ===========================================================================
// Test doubles
// ===========================================================================

/// Minimal fake transport — exposes `sent`, optionally throws on `send`,
/// and optionally toggles `isAvailable()`.
class FakeTransport implements Transport {
  final bool _available;
  final bool throwOnSend;
  final Set<String> failForRecipientIds = <String>{};
  final List<Message> sent = <Message>[];
  final StreamController<Message> _controller =
      StreamController<Message>.broadcast();

  FakeTransport({bool available = true, this.throwOnSend = false})
      // ignore: prefer_initializing_formals
      : _available = available;

  @override
  bool isAvailable() => _available;

  @override
  String get name => 'fake';

  @override
  Stream<Message> get incoming => _controller.stream;

  @override
  Future<void> send(Message msg) async {
    if (throwOnSend) {
      throw StateError('fake transport send failure');
    }
    final rid = msg.recipientId;
    if (rid != null && failForRecipientIds.contains(rid)) {
      throw StateError('fake transport send failure for $rid');
    }
    sent.add(msg);
  }

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

/// Records every call so tests can assert against the exact arguments the
/// implementation handed to the encryptor.
class FakeEncryptor implements DirectMessageEncryptor {
  final List<EncryptCallRecord> calls = <EncryptCallRecord>[];

  @override
  Future<DirectEncryptedPayload> encryptForRecipient({
    required String recipientId,
    required Uint8List plaintext,
  }) async {
    calls.add(EncryptCallRecord(recipientId, plaintext));
    return DirectEncryptedPayload(
      ciphertext: Uint8List.fromList(
        utf8Bytes('FAKE-CT:${utf8.decode(plaintext)}'),
      ),
      ratchetHeader: Uint8List.fromList(<int>[0x01, 0x02, 0x03, 0x04]),
    );
  }
}

class EncryptCallRecord {
  EncryptCallRecord(this.recipientId, this.plaintext);
  final String recipientId;
  final Uint8List plaintext;
}

/// In-memory fake of `VaultSendSource` — no SQL, no crypto. Tests add
/// records with explicit recipientId + status so we can drive every
/// branch of the deliverer.
class FakeVaultSource implements VaultSendSource {
  final List<_FakeRecord> _records = <_FakeRecord>[];
  final List<String> failDecryptIds = <String>[];
  int markSentCalls = 0;

  void addPending({
    required String id,
    required String recipientId,
    required Uint8List plaintext,
    String status = 'pending',
  }) {
    _records.add(_FakeRecord(
      id: id,
      recipientId: recipientId,
      plaintext: plaintext,
      status: status,
    ));
  }

  void addSelf({
    required String id,
    required Uint8List plaintext,
    String status = 'pending',
  }) {
    _records.add(_FakeRecord(
      id: id,
      recipientId: null,
      plaintext: plaintext,
      status: status,
    ));
  }

  String statusOf(String id) => _records.firstWhere((r) => r.id == id).status;

  @override
  Future<List<PendingVaultRecord>> listPendingForDelivery() async {
    return _records
        .where((r) => r.recipientId != null && r.status != 'sent')
        .map((r) => r.toPending())
        .toList(growable: false);
  }

  @override
  Future<Uint8List> decrypt(PendingVaultRecord record) async {
    if (failDecryptIds.contains(record.id)) {
      throw StateError('fake decrypt failure for ${record.id}');
    }
    return _records.firstWhere((r) => r.id == record.id).plaintext;
  }

  @override
  Future<void> markSent(String id) async {
    markSentCalls++;
    final idx = _records.indexWhere((r) => r.id == id);
    if (idx == -1) return;
    _records[idx] = _records[idx].copyWith(status: 'sent');
  }
}

class _FakeRecord {
  _FakeRecord({
    required this.id,
    required this.recipientId,
    required this.plaintext,
    required this.status,
  });

  final String id;
  final String? recipientId;
  final Uint8List plaintext;
  final String status;

  _FakeRecord copyWith({String? status}) => _FakeRecord(
        id: id,
        recipientId: recipientId,
        plaintext: plaintext,
        status: status ?? this.status,
      );

  PendingVaultRecord toPending() {
    return PendingVaultRecord(
      id: id,
      recipientId: recipientId ?? '',
    );
  }
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(s.codeUnits);
