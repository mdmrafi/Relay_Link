// RelayLink — SMS exceptions (Ticket #24).
//
// Centralized exception type for the SMS transport. Keeping a single
// `SmsFramingException` lets callers distinguish "bad segment metadata"
// from "platform error" or "transport unavailable" without committing to
// a deep exception hierarchy yet.

/// Thrown when an SMS segment or set of segments is malformed: bad
/// header, bad message ID, mismatched totals, missing fragments, invalid
/// base64, etc.
///
/// This is distinct from `PlatformException` (which comes from the native
/// side via `SmsPlatformChannel`) and from "transport unavailable" type
/// errors. Use `on SmsFramingException` to recover by discarding the
/// offending segment or buffer entry and logging.
class SmsFramingException implements Exception {
  /// Human-readable description. Safe to log; never contains plaintext
  /// message bodies (only metadata about the failure).
  final String message;

  const SmsFramingException(this.message);

  @override
  String toString() => 'SmsFramingException: $message';
}
