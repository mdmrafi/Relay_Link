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

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:relaylink/capabilities/detect.dart';

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
    return ListTile(
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
/// Both modes render the same capability list.
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
        title: const Text("This device's capabilities"),
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
                      child: Text(
                        'Platform: ${capabilities.platform}',
                        key: const ValueKey<String>('capabilityPlatform'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (_showIosBanner)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                    const Divider(height: 1),
                    _CapabilityRow(
                      label: 'Bluetooth mesh send/receive',
                      capability: capabilities.bluetoothMeshSend,
                    ),
                    _CapabilityRow(
                      label: 'Bluetooth mesh discovery',
                      capability: capabilities.bluetoothMeshDiscover,
                    ),
                    _CapabilityRow(
                      label: 'Multi-hop store-and-forward relay',
                      capability: capabilities.multiHopRelay,
                    ),
                    _CapabilityRow(
                      label: 'SMS send',
                      capability: capabilities.smsSend,
                    ),
                    _CapabilityRow(
                      label: 'SMS receive',
                      capability: capabilities.smsReceive,
                    ),
                    _CapabilityRow(
                      label: 'Internet (cloud relay)',
                      capability: capabilities.internet,
                    ),
                    _CapabilityRow(
                      label: 'ALERT verification (signature check)',
                      capability: capabilities.alertVerification,
                    ),
                    _CapabilityRow(
                      label: 'Evidence Vault (capture)',
                      capability: capabilities.vaultCapture,
                    ),
                    _CapabilityRow(
                      label: 'Evidence Vault (send-on-connect)',
                      capability: capabilities.vaultSendOnConnect,
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
