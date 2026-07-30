// RelayLink — Ticket #21: Gateway mode toggle UI + safety warning.
//
// This file provides the Settings tile that lets the user opt their device into
// "gateway mode" — relaying other nearby devices' encrypted mesh traffic
// through their internet connection. The relay code itself lives in Ticket #22;
// this ticket is UI + state only.
//
// The safety warning text is taken verbatim from SPEC.md §10 (Implementation
// Decisions > Gateway mode > Safety note on enable). Do not edit the
// `kGatewaySafetyWarning` constant without updating the spec.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The exact title shown on the Settings tile.
const String kGatewayToggleTitle = 'Act as gateway for nearby devices';

/// SharedPreferences key for the persisted gateway toggle state.
const String kGatewayEnabledPrefKey = 'relaylink.gateway.enabled';

/// Optional subtitle for the toggle tile (kept brief — the safety warning is
/// shown in the modal, not the tile, to avoid scaring users away from the
/// setting on first glance).
const String kGatewayToggleSubtitle = 'Relay other devices\u2019 traffic '
    'through your internet';

/// Safety warning shown verbatim when the user attempts to enable gateway
/// mode. Sourced from SPEC.md §10 (Implementation Decisions > Gateway mode >
/// "Safety note on enable"). Displaying this exact text is acceptance
/// criterion #4 of Ticket #21.
const String kGatewaySafetyWarning = 'Acting as a Gateway relays encrypted '
    'mesh traffic through your internet connection on behalf of nearby '
    'devices. In a monitored or hostile network environment, this can make '
    'your device identifiable as a bridge point.';

/// The label on the confirmation button in the safety warning modal.
const String kGatewayEnableConfirmLabel = 'Confirm';

/// The cancel button label in the safety warning modal.
const String kGatewayEnableCancelLabel = 'Cancel';

/// The title shown in the safety warning modal.
const String kGatewaySafetyWarningTitle = 'Before you enable gateway mode';

/// The title shown in the "turn off" confirmation dialog.
const String kGatewayDisableDialogTitle = 'Turn off?';

/// The body of the "turn off" confirmation dialog.
const String kGatewayDisableDialogBody = 'Gateway mode is currently on. '
    'Disabling it will stop relaying other devices\u2019 traffic through '
    'your internet connection.';

/// Button label for the affirmative action in the disable dialog.
const String kGatewayDisableConfirmLabel = 'Turn off';

/// Button label for the cancel action in the disable dialog.
const String kGatewayDisableCancelLabel = 'Keep on';

/// Holds the persisted "gateway enabled" flag and broadcasts changes to
/// listeners (Riverpod `StateNotifier`).
///
/// The default state is `false` (off), per SPEC §10. Persistence is handled
/// via `SharedPreferences` so the toggle state survives app restarts and
/// device reboots.
///
/// This is the true singleton state for the app — `gatewayEnabledProvider`
/// below is the single source of truth, and any widget that consumes it will
/// rebuild when the value toggles.
class GatewayEnabledNotifier extends StateNotifier<bool> {
  GatewayEnabledNotifier() : super(false) {
    // Fire-and-forget load on construction. The initial value is `false`
    // (the default per spec); if persisted state is `true`, the value will
    // flip to `true` once `_load()` completes, and any listeners will
    // rebuild with the restored value.
    _load();
  }

  /// Restore the persisted state from SharedPreferences.
  ///
  /// If no value has been persisted yet, the default is `false` (off). If
  /// the value is `true`, the in-memory state is updated, which causes any
  /// listeners (e.g. the toggle tile) to rebuild with the restored value.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(kGatewayEnabledPrefKey);
    if (stored == true && !state) {
      state = true;
    }
  }

  /// Enable gateway mode and persist the new state.
  ///
  /// Persistence happens before the in-memory state is updated so that, if
  /// the prefs write fails (or the process is killed before it completes),
  /// the UI never reflects a state that isn't durably stored. On failure,
  /// `state` is left untouched and the previous value remains the truth.
  Future<void> enable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGatewayEnabledPrefKey, true);
    state = true;
  }

  /// Disable gateway mode and persist the new state.
  ///
  /// Persistence happens before the in-memory state is updated so that, if
  /// the prefs write fails (or the process is killed before it completes),
  /// the UI never reflects a state that isn't durably stored. On failure,
  /// `state` is left untouched and the previous value remains the truth.
  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGatewayEnabledPrefKey, false);
    state = false;
  }

  /// Toggle the state, persisting the result. Used in places where the
  /// caller has already walked the user through the appropriate warnings;
  /// the Settings tile itself drives enable/disable through explicit
  /// confirmations.
  Future<void> toggle() async {
    if (state) {
      await disable();
    } else {
      await enable();
    }
  }
}

/// The singleton provider exposing the gateway enabled flag to the widget
/// tree. Read with `ref.watch(gatewayEnabledProvider)` and mutate through
/// `ref.read(gatewayEnabledProvider.notifier).enable()` / `.disable()`.
final StateNotifierProvider<GatewayEnabledNotifier, bool>
    gatewayEnabledProvider =
    StateNotifierProvider<GatewayEnabledNotifier, bool>(
        (Ref ref) => GatewayEnabledNotifier());

/// A reusable Settings tile that shows the current gateway state and triggers
/// the appropriate confirmation flow on tap.
///
/// - When the tile is tapped with the toggle currently OFF, the safety
///   warning modal is shown. The user must press "Confirm" to actually
///   enable gateway mode.
/// - When the tile is tapped with the toggle currently ON, a "Turn off?"
///   confirmation dialog is shown. The user must confirm explicitly to
///   disable.
///
/// The tile itself reflects the current state via Riverpod, so external
/// changes (e.g. another widget disabling the toggle) will be reflected
/// automatically.
///
/// This widget is the public API surface for Ticket #21 and is consumed by
/// the Settings screen in Ticket #42. The sample app below demonstrates
/// usage in a stand-alone `MaterialApp` for development and testing.
class GatewayToggleTile extends ConsumerWidget {
  const GatewayToggleTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(gatewayEnabledProvider);
    return SwitchListTile(
      key: const ValueKey<String>('gatewayToggleTile'),
      title: const Text(kGatewayToggleTitle),
      subtitle: const Text(kGatewayToggleSubtitle),
      secondary: const Icon(Icons.cell_tower),
      value: enabled,
      // The provider is the source of truth, so we ignore `newValue` and
      // re-read the current state inside `_onTap`.
      onChanged: (_) => _onTap(context, ref),
    );
  }

  /// Internal tap handler. Reads the latest state from the provider (the
  /// provider is the single source of truth) and shows the appropriate
  /// confirmation flow.
  Future<void> _onTap(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final currentlyEnabled = ref.read(gatewayEnabledProvider);
    final notifier = ref.read(gatewayEnabledProvider.notifier);
    if (currentlyEnabled) {
      final confirmed = await _showDisableDialog(context);
      if (confirmed) {
        await notifier.disable();
      }
    } else {
      final confirmed = await _showSafetyWarning(context);
      if (confirmed) {
        await notifier.enable();
      }
    }
  }

  /// Show the safety warning modal verbatim from SPEC §10, requiring an
  /// explicit "Confirm" tap to enable. Returns `true` if the user confirmed,
  /// `false` otherwise.
  Future<bool> _showSafetyWarning(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      // BarrierDismissible: false — we want the user to make an explicit
      // choice. Tapping outside shouldn't enable a high-risk feature.
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          key: const ValueKey<String>('gatewaySafetyWarningDialog'),
          title: const Text(kGatewaySafetyWarningTitle),
          content: const Text(kGatewaySafetyWarning),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('gatewaySafetyWarningCancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(kGatewayEnableCancelLabel),
            ),
            FilledButton(
              key: const ValueKey<String>('gatewaySafetyWarningConfirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(kGatewayEnableConfirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  /// Show the "Turn off?" confirmation dialog. Returns `true` if the user
  /// confirmed the disable action.
  Future<bool> _showDisableDialog(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          key: const ValueKey<String>('gatewayDisableDialog'),
          title: const Text(kGatewayDisableDialogTitle),
          content: const Text(kGatewayDisableDialogBody),
          actions: <Widget>[
            TextButton(
              key: const ValueKey<String>('gatewayDisableCancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text(kGatewayDisableCancelLabel),
            ),
            FilledButton(
              key: const ValueKey<String>('gatewayDisableConfirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(kGatewayDisableConfirmLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }
}

/// A standalone `MaterialApp` that demonstrates the [GatewayToggleTile] in
/// a Settings-like screen. This is the entry point for testing and local
/// development of the gateway toggle without spinning up the full app
/// scaffold from #42.
class GatewayToggleSampleApp extends StatelessWidget {
  const GatewayToggleSampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        title: 'RelayLink — Gateway toggle',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4FC3F7)),
          useMaterial3: true,
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: SafeArea(
            child: ListView(
              children: const <Widget>[
                // The reusable widget — same shape used in Ticket #42.
                GatewayToggleTile(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
