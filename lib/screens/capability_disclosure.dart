// RelayLink — Ticket #30: Capability disclosure screen (first-launch + Settings/About).
//
// Shows the device's capability table from `DeviceCapabilities` (§3.1) as a
// simple, scannable list — one row per feature with a ✓/✗ mark and an inline
// reason when unavailable. Reused for both the first-launch gate and the
// Settings/About entry; the same widget just renders whatever
// `DeviceCapabilities` it is given. The dismiss-button label varies via the
// `confirmLabel` parameter:
//
//   - First-launch: "Got it" — sets the seen flag and pops back to Home.
//   - Settings/About: "Close" — pops back to Settings.
//
// The verbatim iOS-specific text from SPEC.md §3.1 ("SMS features unavailable
// — Apple doesn't allow apps to send or read SMS automatically.") is shown
// when the device is iOS and at least one SMS feature is unavailable; the
// per-feature reason text is sourced from `DeviceCapabilities` so this
// widget stays in sync with #29.
//
// LIVE STATE (Ticket #10 cut #10): the disclosure now shows the LIVE gate
// state per feature, not the one-shot snapshot from `detectCapabilities()`.
// Each row is wrapped in a `StreamBuilder<CapabilityEvent>` keyed on the
// relevant `CapabilityGateKind` so a permission revoke or a peer
// disappearing reflects in the UI immediately. The platform (Android / iOS)
// and the platform-fixed rows (smsSend on iOS) still come from the static
// `DeviceCapabilities` snapshot because they do not change at runtime.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/capabilities/detect.dart';
import 'package:relaylink/capabilities/timeline.dart';

/// SharedPreferences key for the "first-launch disclosure seen" flag.
///
/// The `_v1` suffix is intentional: if we ever need to re-prompt users after
/// a material capability change (e.g. a future iOS feature ships), bumping
/// the version forces a re-disclosure.
const String kCapabilityDisclosureSeenPrefKey = 'capability_disclosure_seen_v1';

/// The verbatim iOS-specific disclosure text from SPEC.md §3.1 (Capability
/// disclosure). Quoted exactly:
///
///   "SMS features unavailable — Apple doesn't allow apps to send or read
///    SMS automatically."
///
/// Displayed in the disclosure whenever the device is iOS and at least one
/// SMS feature is unavailable, per ticket acceptance criterion #4.
const String kIosDisclosureVerbatim =
    "SMS features unavailable \u2014 Apple doesn't allow apps to send or "
    'read SMS automatically.';

/// Returns `true` if the user has already dismissed the first-launch
/// capability disclosure at least once.
Future<bool> hasSeenCapabilityDisclosure() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(kCapabilityDisclosureSeenPrefKey) ?? false;
}

/// Mark the capability disclosure as seen and persist it. Idempotent.
Future<void> markCapabilityDisclosureSeen() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kCapabilityDisclosureSeenPrefKey, true);
}

/// One live disclosure row.
///
/// Renders the static `DeviceCapabilities` snapshot (label + base availability
/// + reason on iOS), but the final `available` flag is OVERRIDDEN by the
/// most recent timeline event for the matching gate. Before any update
/// arrives, the static snapshot is used so the UI is never empty.
class _LiveRow extends ConsumerWidget {
  const _LiveRow({
    required this.label,
    required this.staticCapability,
    required this.gateKind,
  });

  final String label;
  final FeatureCapability staticCapability;
  final CapabilityGateKind gateKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<CapabilityEvent>(
      // We key on the gate kind so unrelated transitions don't rebuild
      // every row. Each gate's events stream is broadcast so subscription
      // is cheap.
      key: ValueKey<String>('liveRow::$gateKind'),
      stream: CapabilityTimeline.instance().events
          .where((e) => e.gate == gateKind),
      initialData: null,
      builder: (BuildContext context,
          AsyncSnapshot<CapabilityEvent> snapshot) {
        // If no live event has arrived yet, fall back to the static snapshot.
        final live = snapshot.data;
        final available = live?.available ?? staticCapability.available;
        final reason = live?.reason.isNotEmpty == true
            ? live!.reason
            : staticCapability.reason;
        final cap = FeatureCapability(
          available: available,
          reason: available ? '' : reason,
        );
        return _CapabilityRow(label: label, capability: cap);
      },
    );
  }
}

/// Single row of the disclosure: a feature label, a leading ✓/✗ icon, and a
/// reason subtitle when the feature is unavailable.
///
/// Extracted to a small widget so widgets can key off the row title for
/// tests and accessibility.
class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.label,
    required this.capability,
  });

  final String label;
  final FeatureCapability capability;

  @override
  Widget build(BuildContext context) {
    final available = capability.available;
    final reason = capability.reason;
    final iconColor =
        available ? const Color(0xFF66BB6A) : const Color(0xFFEF5350);
    // The icon already conveys ✓/✗ visually; the Semantics label spells
    // that out for screen readers and adds the reason / "available"
    // suffix so the row is self-contained when announced out of context.
    final semanticsLabel = available
        ? '$label, available'
        : '$label, unavailable: $reason';
    return Semantics(
      label: semanticsLabel,
      liveRegion: true,
      child: ListTile(
        key: ValueKey<String>('capabilityRow::$label'),
        leading: Icon(
          available ? Icons.check_circle : Icons.cancel,
          color: iconColor,
        ),
        title: Text(label),
        subtitle: Text(
          available ? 'available' : reason,
          key: ValueKey<String>('capabilityRowReason::$label'),
        ),
      ),
    );
  }
}

/// The capability disclosure screen.
///
/// Display modes:
///   - `mode: CapabilityDisclosureMode.firstLaunch` — shows a single "Got it"
///     button that sets the seen flag and pops the route.
///   - `mode: CapabilityDisclosureMode.settingsAbout` — shows a "Close"
///     button that pops without touching the seen flag.
///
/// Both modes render the same capability list, with live state.
enum CapabilityDisclosureMode { firstLaunch, settingsAbout }

/// The disclosure page widget. Use [buildCapabilityDisclosureRoute] below
/// for the full route (with shared_preferences wiring).
class CapabilityDisclosurePage extends StatelessWidget {
  const CapabilityDisclosurePage({
    super.key,
    required this.capabilities,
    this.mode = CapabilityDisclosureMode.firstLaunch,
  });

  final DeviceCapabilities capabilities;
  final CapabilityDisclosureMode mode;

  /// Confirm-dismiss button label. Exposed as a getter (not a field) so the
  /// UI stays in sync with [mode] regardless of how callers instantiate the
  /// page.
  String get _confirmLabel =>
      mode == CapabilityDisclosureMode.firstLaunch ? 'Got it' : 'Close';

  /// True if the iOS-specific §3.1 verbatim banner should appear.
  bool get _showIosBanner =>
      capabilities.platform == 'ios' &&
      (!capabilities.smsSend.available || !capabilities.smsReceive.available);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Semantics(
          header: true,
          label: "This device's capabilities",
          child: const Text("This device's capabilities"),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Semantics(
                        label: 'Device platform: ${capabilities.platform}',
                        header: true,
                        child: Text(
                          'Platform: ${capabilities.platform}',
                          key: const ValueKey<String>('capabilityPlatform'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                    if (_showIosBanner)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: Semantics(
                          label:
                              'Important iOS notice. $kIosDisclosureVerbatim',
                          liveRegion: true,
                          child: Container(
                            key: const ValueKey<String>('iosDisclosureBanner'),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F2933),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFF4FC3F7),
                              ),
                            ),
                            child: Text(
                              kIosDisclosureVerbatim,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ),
                      ),
                    const Divider(height: 1),
                    _LiveRow(
                      label: 'Bluetooth mesh send/receive',
                      staticCapability: capabilities.bluetoothMeshSend,
                      gateKind: CapabilityGateKind.mesh,
                    ),
                    _LiveRow(
                      label: 'Bluetooth mesh discovery',
                      staticCapability: capabilities.bluetoothMeshDiscover,
                      gateKind: CapabilityGateKind.mesh,
                    ),
                    _LiveRow(
                      label: 'Multi-hop store-and-forward relay',
                      staticCapability: capabilities.multiHopRelay,
                      gateKind: CapabilityGateKind.mesh,
                    ),
                    _LiveRow(
                      label: 'SMS send',
                      staticCapability: capabilities.smsSend,
                      gateKind: CapabilityGateKind.sms,
                    ),
                    _LiveRow(
                      label: 'SMS receive',
                      staticCapability: capabilities.smsReceive,
                      gateKind: CapabilityGateKind.sms,
                    ),
                    _LiveRow(
                      label: 'Internet (cloud relay)',
                      staticCapability: capabilities.internet,
                      gateKind: CapabilityGateKind.internet,
                    ),
                    // ALERT verification is local and does not have a gate —
                    // its static snapshot is the source of truth.
                    _CapabilityRow(
                      label: 'ALERT verification (signature check)',
                      capability: capabilities.alertVerification,
                    ),
                    _LiveRow(
                      label: 'Evidence Vault (capture)',
                      staticCapability: capabilities.vaultCapture,
                      gateKind: CapabilityGateKind.vault,
                    ),
                    _LiveRow(
                      label: 'Evidence Vault (send-on-connect)',
                      staticCapability: capabilities.vaultSendOnConnect,
                      gateKind: CapabilityGateKind.channel,
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: Semantics(
                  // Confirm-dismiss button — first-launch dismisses the
                  // gate and persists the seen flag; Settings/About pops
                  // back. The hint tells screen-reader users what the
                  // action will do beyond the visible label.
                  label: mode == CapabilityDisclosureMode.firstLaunch
                      ? '$_confirmLabel, dismiss capability disclosure'
                      : '$_confirmLabel, return to settings',
                  button: true,
                  enabled: true,
                  excludeSemantics: true,
                  child: FilledButton(
                    key: const ValueKey<String>('capabilityConfirmButton'),
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      if (mode == CapabilityDisclosureMode.firstLaunch) {
                        await markCapabilityDisclosureSeen();
                      }
                      if (navigator.canPop()) {
                        navigator.pop();
                      }
                    },
                    child: Text(_confirmLabel),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First-launch gate. Returns `true` once the user has dismissed the
/// disclosure (either now or previously). Exposed so the app's root router
/// (in `lib/main.dart`) can decide whether to push the disclosure route.
///
/// The widget is intentionally framework-light: a simple [FutureBuilder] that
/// shows a loading spinner while reading prefs, then either the home page or
/// nothing (the caller pushes the disclosure on top when `shouldShow` is
/// `true`).
class CapabilityDisclosureGate extends StatelessWidget {
  const CapabilityDisclosureGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: hasSeenCapabilityDisclosure(),
      builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
        if (!snapshot.hasData) {
          // While prefs are loading, render a placeholder rather than the
          // home screen — avoids a flash of Home before the disclosure
          // route is pushed.
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return child;
      },
    );
  }
}

/// Build a [MaterialPageRoute] for navigating to the disclosure screen from
/// the Settings/About page (i.e. not on first-launch). The route never
/// touches the seen flag — viewing the disclosure from Settings is always
/// allowed.
MaterialPageRoute<void> buildSettingsAboutCapabilitiesRoute(
  DeviceCapabilities capabilities,
) {
  return MaterialPageRoute<void>(
    builder: (_) => CapabilityDisclosurePage(
      capabilities: capabilities,
      mode: CapabilityDisclosureMode.settingsAbout,
    ),
  );
}