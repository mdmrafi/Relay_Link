// RelayLink — Transport interface tests (Ticket #06).
//
// Covers the four acceptance-criteria behaviours for the transport
// abstraction: loopback round-trip, broadcast stream, availability
// gating, and TransportManager fan-out semantics.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:relaylink/models/message.dart';
import 'package:relaylink/transport/transport.dart';

Message _mkMessage({String id = 'msg-1'}) => Message.create(
      mode: MessageMode.broadcast,
      type: MessageType.chat,
      channelId: 'public',
      senderId: 'device-a',
      payload: Uint8List.fromList([1, 2, 3]),
      ttl: 4,
    ).copyWith(id: id);

void main() {
  group('EchoTransport', () {
    test('round-trips a Message: send() appears on incoming', () async {
      final transport = EchoTransport();
      final msg = _mkMessage();
      final received = transport.incoming.first;
      await transport.send(msg);
      expect(await received, msg);
      transport.close();
    });

    test('default name is "echo" and default isAvailable is true', () {
      final transport = EchoTransport();
      expect(transport.name, 'echo');
      expect(transport.isAvailable(), isTrue);
      transport.close();
    });

    test('custom name and availability flag are honoured', () {
      final transport = EchoTransport(name: 'test-loop', available: false);
      expect(transport.name, 'test-loop');
      expect(transport.isAvailable(), isFalse);
      transport.close();
    });

    test('isAvailable() toggling mutates state without recreating the '
        'stream', () async {
      final transport = EchoTransport();
      // Subscribe first, then toggle availability — the stream should
      // keep working.
      final completer = Completer<Message>();
      final sub = transport.incoming.listen(completer.complete);
      transport.available = false;
      expect(transport.isAvailable(), isFalse);
      transport.available = true;
      expect(transport.isAvailable(), isTrue);

      await transport.send(_mkMessage());
      expect(await completer.future, isA<Message>());
      await sub.cancel();
      transport.close();
    });
  });

  group('EchoTransport.incoming is broadcast', () {
    test('multiple listeners all receive the same message', () async {
      final transport = EchoTransport();
      final msg = _mkMessage();

      final f1 = transport.incoming.first;
      final f2 = transport.incoming.first;
      final f3 = transport.incoming.first;

      await transport.send(msg);

      final r1 = await f1;
      final r2 = await f2;
      final r3 = await f3;
      expect(r1, msg);
      expect(r2, msg);
      expect(r3, msg);
      transport.close();
    });

    test('a late subscriber still receives subsequent messages', () async {
      final transport = EchoTransport();

      // First subscriber drains its first event before we add the second.
      final firstReceived = transport.incoming.first;
      await transport.send(_mkMessage(id: 'm1'));
      expect((await firstReceived).id, 'm1');

      // Second subscriber comes online *after* the first send. With a
      // broadcast stream, it should still receive the next event.
      final secondReceived = transport.incoming.first;
      await transport.send(_mkMessage(id: 'm2'));
      expect((await secondReceived).id, 'm2');

      transport.close();
    });
  });

  group('TransportManager.register / unregister', () {
    test('register adds transports; unregister removes by identity', () {
      final manager = TransportManager();
      final t1 = EchoTransport(name: 'one');
      final t2 = EchoTransport(name: 'two');
      manager.register(t1);
      manager.register(t2);
      expect(manager.transports, [t1, t2]);

      manager.unregister(t1);
      expect(manager.transports, [t2]);
      // Removing the same instance twice is a no-op.
      manager.unregister(t1);
      expect(manager.transports, [t2]);
      manager.unregister(t2);
      expect(manager.transports, isEmpty);
    });

    test('registering the same instance twice is a no-op', () {
      final manager = TransportManager();
      final t = EchoTransport();
      manager.register(t);
      manager.register(t);
      expect(manager.transports.length, 1);
      manager.unregister(t);
    });

    test('transports list is unmodifiable', () {
      final manager = TransportManager();
      manager.register(EchoTransport());
      expect(() => manager.transports.add(EchoTransport()),
          throwsUnsupportedError);
    });
  });

  group('TransportManager.fanOutSend', () {
    test('sends on all available transports, skipping unavailable ones',
        () async {
      final manager = TransportManager();
      final availableA = EchoTransport(name: 'A');
      final unavailable = EchoTransport(name: 'B', available: false);
      final availableC = EchoTransport(name: 'C');
      manager
        ..register(availableA)
        ..register(unavailable)
        ..register(availableC);

      final msg = _mkMessage();
      // Subscribe to each transport so they capture the send.
      final received = <String, Message>{};
      final subs = <StreamSubscription<Message>>[];
      for (final t in manager.transports) {
        subs.add(t.incoming.listen((m) {
          received[t.name] = m;
        }));
      }

      final errors = await manager.fanOutSend(msg);
      // No errors.
      expect(errors, [null, null, null]);
      // Available transports received the message; unavailable did not.
      expect(received['A'], msg);
      expect(received.containsKey('B'), isFalse);
      expect(received['C'], msg);

      for (final s in subs) {
        await s.cancel();
      }
      availableA.close();
      unavailable.close();
      availableC.close();
    });

    test('does not block: a slow transport does not delay a fast one',
        () async {
      final manager = TransportManager();
      final fast = EchoTransport(name: 'fast');
      final slowCompleter = Completer<void>();
      final slow = _SlowLoopback(
        name: 'slow',
        onSend: (_) => slowCompleter.future,
      );
      manager
        ..register(fast)
        ..register(slow);

      final msg = _mkMessage();

      // Subscribe *before* triggering the send so we don't race the
      // broadcast emit.
      final fastReceived = fast.incoming.first
          .timeout(const Duration(seconds: 1));

      final errorsFuture = manager.fanOutSend(msg);

      // The fast transport's incoming should resolve quickly — without
      // waiting for the slow one.
      expect(await fastReceived, msg);

      // Now let the slow transport finish.
      slowCompleter.complete();
      final errors = await errorsFuture;
      expect(errors, [null, null]);

      fast.close();
      await slow.close();
    });

    test('a failing transport does not fail the whole fan-out', () async {
      final manager = TransportManager();
      final ok = EchoTransport(name: 'ok');
      final bad = _FailingLoopback(name: 'bad', error: 'radio off');
      manager
        ..register(ok)
        ..register(bad);

      final errors = await manager.fanOutSend(_mkMessage());

      expect(errors.length, 2);
      expect(errors[0], isNull); // ok succeeded
      expect(errors[1], isA<Object>()); // bad errored
      expect(errors[1].toString(), contains('radio off'));

      ok.close();
      await bad.close();
    });

    test('fanOutSend returns immediately with empty list when no '
        'transports are registered', () async {
      final manager = TransportManager();
      final errors = await manager.fanOutSend(_mkMessage());
      expect(errors, isEmpty);
    });
  });
}

/// Test-only Transport that waits on [onSend] before completing send().
class _SlowLoopback implements Transport {
  _SlowLoopback({required this.name, required this.onSend});

  @override
  final String name;
  final Future<void> Function(Message msg) onSend;

  final StreamController<Message> _controller =
      StreamController<Message>.broadcast();

  @override
  Stream<Message> get incoming => _controller.stream;

  @override
  bool isAvailable() => true;

  @override
  Future<void> send(Message msg) async {
    await onSend(msg);
    if (!_controller.isClosed) _controller.add(msg);
  }

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

/// Test-only Transport whose send() always throws [error].
class _FailingLoopback implements Transport {
  _FailingLoopback({required this.name, required this.error});

  @override
  final String name;
  final String error;

  final StreamController<Message> _controller =
      StreamController<Message>.broadcast();

  @override
  Stream<Message> get incoming => _controller.stream;

  @override
  bool isAvailable() => true;

  @override
  Future<void> send(Message msg) async {
    throw StateError(error);
  }

  Future<void> close() async {
    if (!_controller.isClosed) await _controller.close();
  }
}