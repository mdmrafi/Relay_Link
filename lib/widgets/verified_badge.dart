// RelayLink — Ticket #37 ALERT verified badge (offline-first lookup).
//
// Displays the sender attribution for an ALERT message. The widget does
// NOT trust any field on the Message envelope that claims verification —
// verification is a *receiver-side* concern (see SPEC.md §5: "There is
// NO field in the Message schema that a sender can set to claim
// verification"). The widget looks up the sender's pubkey against the
// offline-first `VerifiedOrgsCache` (Ticket #36) and decides locally.
//
// Two visual branches:
//   * Verified: pubkey is in the cache → green check + "Verified: <name>"
//   * Unsigned: pubkey is NOT in the cache → grey person + "Signed by: <name>"
//
// The cache is injected via the constructor so widget tests can drive
// both branches without touching shared_preferences / Firestore.

import 'package:flutter/material.dart';

import 'package:relaylink/alerts/allowlist.dart';

/// Visual style for [VerifiedBadge]. Default ([VerifiedBadgeStyle.chip])
/// renders a colored pill with an icon; the inline variant renders a
/// smaller text-only row suitable for a list-row trailing slot.
enum VerifiedBadgeStyle { chip, inline }

/// ALERT-message sender attribution.
///
/// Looks up [senderPubkey] against [cache]. If the cache contains that
/// pubkey, renders a "Verified" badge with the supplied [displayName] and
/// a distinct color/icon. Otherwise renders a neutral "Signed by" label.
///
/// The widget never inspects fields on the Message envelope to decide
/// verification — only the cache.
class VerifiedBadge extends StatelessWidget {
  /// Creates a verified/unsigned badge.
  ///
  /// [senderPubkey] is the base64-encoded Ed25519 pubkey of the sender —
  /// exactly the value of `Message.senderId` (the device id is the pubkey
  /// fingerprint in this app).
  ///
  /// [displayName] is the human-readable name shown in either branch.
  /// Typically `Message.senderDisplayName`.
  ///
  /// [cache] is the offline-first allowlist cache. Tests inject a fake
  /// constructed with `VerifiedOrgsCache.withFetcher`; production passes
  /// the real `VerifiedOrgsCache()` instance.
  ///
  /// [style] picks the visual treatment — chip (default, with icon and
  /// background) or inline (text-only, for tight layouts).
  const VerifiedBadge({
    super.key,
    required this.senderPubkey,
    required this.displayName,
    required this.cache,
    this.style = VerifiedBadgeStyle.chip,
  });

  /// Base64-encoded Ed25519 pubkey to look up.
  final String senderPubkey;

  /// Human-readable sender name (shown in both branches).
  final String displayName;

  /// Offline-first verified-org cache (Ticket #36).
  final VerifiedOrgsCache cache;

  /// Visual treatment.
  final VerifiedBadgeStyle style;

  @override
  Widget build(BuildContext context) {
    // Receiver-side decision only — never trust envelope metadata.
    final verified = cache.isVerified(senderPubkey);
    return verified
        ? _VerifiedChip(name: displayName, style: style)
        : _UnsignedChip(name: displayName, style: style);
  }
}

/// Internal: `Verified: <name>` badge. Distinct green check icon + green
/// tinted background. Visually loud enough that a user can immediately
/// tell the alert came from a trusted aid organization.
class _VerifiedChip extends StatelessWidget {
  const _VerifiedChip({required this.name, required this.style});
  final String name;
  final VerifiedBadgeStyle style;

  // Verified palette: green-tinted dark surface. Chosen for high contrast
  // on the dark theme in `lib/main.dart` (scaffold bg #0E1116).
  static const Color _bg = Color(0xFF143626);
  static const Color _fg = Color(0xFF6FE0A1);
  static const Color _icon = Color(0xFF8DEFB6);

  @override
  Widget build(BuildContext context) {
    final label = _compose('Verified', name);
    switch (style) {
      case VerifiedBadgeStyle.chip:
        return Semantics(
          label: 'Verified alert from $name',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _fg.withValues(alpha: 0.4), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.verified, size: 14, color: _icon),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: _fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      case VerifiedBadgeStyle.inline:
        return Semantics(
          label: 'Verified alert from $name',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified, size: 14, color: _icon),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  color: _fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// Internal: `Signed by: <name>` label. Neutral muted color, person icon.
/// This branch is shown when the sender's pubkey is not in the
/// offline allowlist — i.e. the alert came from an unknown device. We do
/// NOT claim the message is unverified at the crypto layer; we simply
/// say who signed it and let the user decide.
class _UnsignedChip extends StatelessWidget {
  const _UnsignedChip({required this.name, required this.style});
  final String name;
  final VerifiedBadgeStyle style;

  // Unsigned palette: neutral grey that recedes against the dark theme.
  static const Color _fg = Color(0xFF9AA4B2);
  static const Color _icon = Color(0xFFB6BFCB);

  @override
  Widget build(BuildContext context) {
    final label = _compose('Signed by', name);
    switch (style) {
      case VerifiedBadgeStyle.chip:
        return Semantics(
          label: 'Alert signed by $name',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F27),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _fg.withValues(alpha: 0.25), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_outline, size: 14, color: _icon),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: _fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      case VerifiedBadgeStyle.inline:
        return Semantics(
          label: 'Alert signed by $name',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 14, color: _icon),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  color: _fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// Joins the prefix ("Verified" / "Signed by") with the name. Handles the
/// edge case where the display name is empty so the UI doesn't render a
/// trailing colon.
String _compose(String prefix, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return prefix;
  return '$prefix: $trimmed';
}
