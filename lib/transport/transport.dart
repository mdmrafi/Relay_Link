// RelayLink — Transport interface + manager + loopback (Ticket #06).
//
// All channels that carry a `Message` — mesh (Bluetooth), SMS, internet,
// gateway — implement the abstract [Transport]. The app talks to *all*
// transports through this single surface, so fan-out, capability checks,
// and tests stay uniform.
//
// Design notes:
//   * `incoming` is declared as a broadcast-style stream in the interface
//     (`Stream<Message>`) but [LoopbackTransport] is the only place where
//     we enforce `StreamController.broadcast()`. Real transports (mesh,
//     SMS) may use single-subscription controllers wrapped in a broadcast
//     stream if they need to.
//   * [TransportManager.fanOutSend] does not fail fast. A slow or broken
//     transport must never block another (e.g. mesh must keep working when
//     SMS has no coverage). Errors are collected and returned in a list
//     indexed by the *order transports were registered*; available-but-
//     erroring transports get an `Object` error, unavailable transports
//     get `null`.
//   * `unregister(Transport)` uses identity comparison (`identical`).
//     Callers must pass the same instance they registered.

import 'dart:async';

import 'package:relaylink/models/message.dart';

/// Common abstraction for any channel that can carry a [Message].
///
/// Implementations include the mesh transport (Bluetooth/fallback), the
/// SMS transport, the internet transport (Firestore), and the loopback
/// test transport. The rest of the app talks to transports exclusively
/// through this interface, so [TransportManager] and consumers don't need
/// to know which radio is underneath.
abstract class Transport {
  /// Push [msg] out on this transport's radio. The future completes when
  /// the transport has handed the bytes to its underlying channel (or
  /// failed). The manager awaits all available transports in parallel.
  Future<void> send(Message msg);

  /// Messages this transport has just received from the wire. Subscribed
  /// by [TransportManager] (and, in tests, by `expectLater`). Broadcast
  /// streams — multiple listeners are supported.
  Stream<Message> get incoming;

  /// `true` when this device currently has the radio + connectivity for
  /// this transport (e.g. Bluetooth powered on and a peer nearby, or
  /// cellular coverage for SMS). The manager uses this to decide whether
  /// to call [send].
  bool isAvailable();

  /// Human-readable name of the transport (e.g. `'mesh'`, `'sms'`,
  /// `'internet'`, `'loopback'`). Used for logs and the capability
  /// disclosure UI.
  String get name;
}

/// Holds a list of [Transport]s and provides a single fan-out API for
/// sending messages on every available transport in parallel.
///
/// Fan-out is intentionally non-blocking: one slow or failing transport
/// does not delay the others. See [fanOutSend] for the exact semantics.
class TransportManager {
  final List<Transport> _transports = <Transport>[];

  /// Read-only view of the registered transports, in registration order.
  List<Transport> get transports => List.unmodifiable(_transports);

  /// Register [transport]. Adding the same instance twice is a no-op
  /// (the transport will not receive duplicate `send` calls from a
  /// single fan-out).
  void register(Transport transport) {
    if (_transports.any((t) => identical(t, transport))) return;
    _transports.add(transport);
  }

  /// Remove a previously registered [transport]. No-op if [transport]
  /// was not registered. Uses identity comparison.
  void unregister(Transport transport) {
    _transports.removeWhere((t) => identical(t, transport));
  }

  /// Send [msg] on every registered transport whose [Transport.isAvailable]
  /// returns `true`.
  ///
  /// All available transports' `send` futures are awaited in parallel
  /// via `Future.wait`. The returned list is parallel to
  /// [transports] (registration order); index `i` is `null` if transport
  /// `i` was unavailable (skipped), or an [Object] error if it threw.
  ///
  /// Never throws — even if every transport errors, the call returns
  /// normally with a populated error list. This is required by SPEC.md's
  /// "a slow transport must never block SMS" rule.
  Future<List<Object?>> fanOutSend(Message msg) async {
    if (_transports.isEmpty) return const <Object?>[];

    final futures = <Future<Object?>>[];
    final indices = <int>[];
    for (var i = 0; i < _transports.length; i++) {
      final t = _transports[i];
      if (!t.isAvailable()) continue;
      indices.add(i);
      // Wrap each send() so a single transport's error becomes a value
      // (the error object) instead of rejecting the whole `Future.wait`.
      futures.add(_safeSend(t, msg));
    }

    final results = await Future.wait(futures);

    final errors = List<Object?>.filled(_transports.length, null);
    for (var k = 0; k < results.length; k++) {
      errors[indices[k]] = results[k];
    }
    return errors;
  }

  Future<Object?> _safeSend(Transport t, Message msg) async {
    try {
      await t.send(msg);
      return null;
    } catch (e) {
      return e;
    }
  }
}

/// A trivial [Transport] whose `send()` puts the message directly onto its
/// own `incoming` stream. Suitable for unit tests that exercise the
/// transport interface without standing up any radios.
///
/// The `incoming` stream is broadcast so multiple test listeners (and the
/// production manager) can subscribe simultaneously.
class LoopbackTransport implements Transport {
  /// Whether [isAvailable] currently returns `true`. Mutable so tests
  /// can toggle availability mid-run.
  bool available;

  /// Human-readable name. Defaults to `'loopback'`.
  @override
  final String name;

  final StreamController<Message> _controller;

  LoopbackTransport({
    this.name = 'loopback',
    this.available = true,
  }) : _controller = StreamController<Message>.broadcast();

  @override
  Stream<Message> get incoming => _controller.stream;

  @override
  bool isAvailable() => available;

  @override
  Future<void> send(Message msg) async {
    if (!_controller.isClosed) {
      _controller.add(msg);
    }
  }

  /// Close the underlying [StreamController]. After calling this the
  /// transport cannot send or emit any more messages. Mostly useful for
  /// test teardown.
  void close() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}

/// Thrown by a [Transport.send] when the transport is currently
/// unavailable (e.g. Bluetooth radio off, no cellular coverage). Callers
/// should treat this as a non-error condition: the message is dropped
/// silently, the caller may retry later. This is distinct from a wire /
/// serialization failure, which surfaces as a regular [Object] error via
/// the `safeSend` wrapper in [TransportManager].
class TransportUnavailableException implements Exception {
  TransportUnavailableException(this.transportName);

  /// Name of the transport that was unavailable (e.g. `'mesh'`).
  final String transportName;

  @override
  String toString() => 'TransportUnavailableException($transportName)';
}