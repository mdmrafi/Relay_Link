// RelayLink — Fan-out seam types for SMS BROADCAST (Ticket #27).
//
// These types are intentionally kept separate from the canonical
// `lib/transport/transport.dart` (Ticket #06) interface so the fan-out
// module owns its own result vocabulary:
//   * `FanoutRecipientResult` / `FanoutResult` — per-recipient and
//     aggregate fan-out outcomes, including the failed-recipient error
//     payload that the canonical Transport interface deliberately
//     hides (it doesn't model per-recipient failure granularity).
//   * `SmsFanoutTransport` — narrow one-recipient `sendFragment` seam
//     that the fan-out calls per leg. `SmsPlatformChannelTransport`
//     bridges the platform channel to this interface for production.
//   * `FanoutLogger` — typedef for the simple `(String) -> void`
//     logging sink used by the fan-out (defaults to `print`,
//     overridable in tests).
//
// The fan-out consumer in `lib/sms/fanout.dart` depends on these
// types directly; the canonical `Transport`/`TransportManager`
// interface in `lib/transport/transport.dart` is broader and is used
// elsewhere in the app.

/// Per-recipient result of a fan-out leg.
class FanoutRecipientResult {
  /// The phone number (or address) we tried to reach.
  final String address;

  /// True iff this recipient's `send` future completed without throwing.
  final bool success;

  /// Error captured when [success] is false. Null on success.
  final Object? error;

  const FanoutRecipientResult._({
    required this.address,
    required this.success,
    required this.error,
  });

  /// Builds a successful result.
  factory FanoutRecipientResult.ok(String address) =>
      FanoutRecipientResult._(address: address, success: true, error: null);

  /// Builds a failure result carrying [error].
  factory FanoutRecipientResult.failed(String address, Object error) =>
      FanoutRecipientResult._(
        address: address,
        success: false,
        error: error,
      );

  @override
  String toString() => success
      ? 'FanoutRecipientResult.ok($address)'
      : 'FanoutRecipientResult.failed($address, $error)';
}

/// Per-fan-out aggregate result.
class FanoutResult {
  /// True iff at least one recipient succeeded.
  final bool anySuccess;

  /// Number of recipients we attempted to reach.
  final int attempted;

  /// Per-recipient outcomes, in the same order as the input list (after
  /// dedup and phone-number filtering).
  final List<FanoutRecipientResult> perRecipient;

  /// Wall-clock duration of the fan-out, useful for logs and tests.
  final Duration elapsed;

  const FanoutResult({
    required this.anySuccess,
    required this.attempted,
    required this.perRecipient,
    required this.elapsed,
  });
}

/// Abstract SMS-style transport used by the fan-out path.
///
/// The transport here is intentionally narrow — it represents the
/// one-recipient `sendFragment` operation a fan-out leg actually
/// performs. Each fragment (when fragmentation is in play) becomes one
/// such call. The fan-out caller has already done fragmentation,
/// dedup, and encryption — this method only handles the one-shot SMS
/// dispatch per recipient per fragment.
///
/// Implementations:
///   * `SmsPlatformChannelTransport` (production) wraps the
///     `SmsPlatformChannel` (#23).
///   * `FakeSmsFanoutTransport` (tests) records calls in memory.
abstract class SmsFanoutTransport {
  /// Whether this transport is usable on the current device right now
  /// (cell radio on, permissions granted, etc.).
  bool get isAvailable;

  /// Sends one fragment (already encoded by the caller) to [phoneNumber].
  ///
  /// Throws on transport failure. The fan-out caller is responsible for
  /// catching per-recipient errors so a single failure does not abort
  /// the rest of the fan-out.
  Future<void> sendFragment(String phoneNumber, String body);
}

/// Default `print`-based logger for fan-out events.
void defaultFanoutLogger(String message) {
  // Keep this silent in the test environment; production wire-up can
  // replace it with a structured logger.
  // ignore: avoid_print
  print('[fanout] $message');
}

/// Logger sink — defaults to [defaultFanoutLogger] in production; tests
/// inject a list-collector or no-op so they don't pollute the test log.
typedef FanoutLogger = void Function(String message);
