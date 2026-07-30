// RelayLink — Accessibility (a11y) label tokens.
//
// Centralized, reusable label generators for the most common a11y strings
// across the app. Keeping these in one place means: (a) copy is consistent
// across screens, (b) the wording is reviewable in PRs, and (c) future
// localization can be plugged in by swapping this file without touching
// every widget.
//
// Conventions:
//   - Every function returns a non-null, non-empty String. Empty inputs
//     fall back to safe defaults so call sites never accidentally emit a
//     blank Semantics label.
//   - Label strings should be sentence-case and end with a period only when
//     they read as full sentences (e.g. "No signal"). Tighter noun phrases
//     like "Verified by BRAC" omit the trailing period.
//   - Interactive widgets should pair these labels with the appropriate
//     `Semantics(button: true, ...)` flag, but those flags live at the
//     call site so this file stays pure-String.
//
// Usage:
//   ```dart
//   Semantics(
//     label: kA11yLabels.verified('BRAC'),
//     liveRegion: true,
//     child: const Icon(Icons.verified),
//   );
//   ```

/// Reusable a11y label helpers used across RelayLink screens.
///
/// The instance-level API (so callers can write
///   `kA11yLabels.verified('BRAC')`)
/// is intentional — it lets callers mock the labels namespace in tests
/// without changing every call site, and it lets the brief's
/// `kA11yLabelTranslate` alias be exposed as a separate instance if the
/// team later wants a separate translation namespace.
class A11yLabels {
  A11yLabels._();

  /// "Verified by {orgName}" — used for the VerifiedBadge (Ticket #37).
  ///
  /// Falls back to "Verified" when [orgName] is empty or whitespace, so
  /// the live region never silently disappears.
  String verified(String orgName) {
    final trimmed = orgName.trim();
    if (trimmed.isEmpty) return 'Verified';
    return 'Verified by $trimmed';
  }

  /// "Signed by {senderName}" — used for the unsigned/signed branch of
  /// the VerifiedBadge (Ticket #37).
  ///
  /// Falls back to "Signed by unknown sender" when [senderName] is empty.
  String signedBy(String senderName) {
    final trimmed = senderName.trim();
    if (trimmed.isEmpty) return 'Signed by unknown sender';
    return 'Signed by $trimmed';
  }

  /// "Unverified message from {senderName}" — used when verification has
  /// failed or the signer is not in the allowlist.
  String unverified(String senderName) {
    final trimmed = senderName.trim();
    if (trimmed.isEmpty) return 'Unverified message';
    return 'Unverified message from $trimmed';
  }

  /// "{count} peers in range" — for the mesh peer count badge.
  String meshPeers(int count) {
    if (count <= 0) return 'No peers in range';
    if (count == 1) return '1 peer in range';
    return '$count peers in range';
  }

  /// "{count} messages in the last 24 hours" — for the activity count.
  String activityCount(int count) {
    if (count <= 0) return 'No messages in the last 24 hours';
    if (count == 1) return '1 message in the last 24 hours';
    return '$count messages in the last 24 hours';
  }

  /// "Transport: {name}, {available}" — for the transport status row on
  /// the home screen.
  String transport(String name, bool available) {
    final status = available ? 'available' : 'unavailable';
    return 'Transport: $name, $status';
  }
}

/// Convenience top-level instance for the [A11yLabels] helpers.
///
/// Callers should prefer `kA11yLabels.foo(...)` over `A11yLabels.foo(...)`
/// because the top-level instance makes it trivial to wire a different
/// namespace (e.g. for tests) by reassigning this variable.
final A11yLabels kA11yLabels = A11yLabels._();

/// Backwards-compatible alias for the legacy name used in early drafts of
/// the brief. Kept as a stand-in so downstream callers can adopt the new
/// `kA11yLabels` namespace without churn.
final A11yLabels kA11yLabelTranslate = A11yLabels._();
