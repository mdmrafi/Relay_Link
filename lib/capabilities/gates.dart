// RelayLink — Per-feature capability gating (Ticket #10 cut #10).
//
// This file replaces the "show the capability table once and forget it"
// model from Tickets #29/#30 with a runtime governor: each UI feature
// reads a Riverpod gate that exposes a live boolean, and the gates emit
// structured events to `CapabilityTimeline` whenever they transition.
//
// Why per-feature gates rather than one `bool allOk`:
//   * Different features need different things. Mesh needs bluetooth +
//     permissions + a peer in range; SMS needs an SMS-capable device +
//     permission + a cellular radio. A single global flag would either
//     be too coarse or it would conflate heterogeneous signals.
//   * UI affordances can be hidden/disabled at the granularity of one
//     feature, so a user with no cellular radio still sees internet and
//     mesh options. Coarse gating would force-everyone-off when any one
//     signal dips.
//   * Each gate has its own audit log, so a test failure points at
//     exactly which transition misbehaved.
//
// Riverpod is already wired in this repo (Ticket #21 used
// `flutter_riverpod`'s `StateNotifier` provider for the gateway toggle),
// so each gate is a `StateNotifierProvider<…, bool>` exposing a `bool`.
// Widgets consume them with `ref.watch(meshAvailableProvider)` and get
// rebuilt automatically when the value flips. The notifier itself calls
// `CapabilityTimeline.instance().add(...)` on every transition, which is
// the auditable history Agent C's lifecycle tests subscribe to.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/capabilities/timeline.dart';

/// Base class for a per-feature gate. Each subclass knows the gate's
/// stable name (used in `CapabilityEvent.gate`) and starts in a specific
/// default state (usually `false` while initial detection is in-flight).
///
/// Subclasses set the initial value via the [super] initializer (NOT in
/// `initState`, since `StateNotifier` constructions are synchronous). To
/// defer initialization until an async detector resolves, expose a
/// `Future<void> refresh()` method on the notifier; the first call is
/// expected to be fire-and-forget from `main()` (matching the
/// fire-and-forget pattern used for `VerifiedOrgsCache`).
abstract class CapabilityGate extends StateNotifier<bool> {
  CapabilityGate({
    required this.kind,
    required bool initial,
  }) : super(initial);

  /// Which gate this is. Stable identifier used in timeline events.
  final CapabilityGateKind kind;

  /// Update the gate's value, emitting a [CapabilityEvent] whenever the
  /// new value differs from the previous one.
  ///
  /// [reason] should mirror `FeatureCapability.reason`: empty when
  /// [available] is `true`, non-empty when it is `false`. The reasoning
  /// ends up in the disclosure screen and audit log verbatim.
  ///
  /// Returns `true` if the value changed (i.e. an event was emitted).
  @override
  // ignore: use_setters_to_change_properties
  set state(bool value) {
    _set(value, reason: '');
  }

  /// Like [state], but attach a reason (e.g. when downgrading from
  /// available to unavailable on a permission revocation).
  void update(bool value, {String reason = ''}) {
    _set(value, reason: reason);
  }

  void _set(bool value, {required String reason}) {
    if (state == value && reason.isEmpty) return;
    super.state = value;
    CapabilityTimeline.instance().add(
      CapabilityEvent(
        gate: kind,
        available: value,
        reason: reason,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }
}

/// Mesh gate. True iff the device has bluetooth radio on, the user has
/// granted the BLUETOOTH_SCAN / BLUETOOTH_CONNECT permissions (Android 12+),
/// AND there is at least one peer visible to the discovery scan.
///
/// The initial value is `false`; lifecycle re-detection (Agent C's
/// `cutrev-capab-reobserve` ticket) is responsible for calling
/// `meshNotifier.update(...)` whenever the underlying signals change.
class MeshAvailableNotifier extends CapabilityGate {
  MeshAvailableNotifier()
      : super(kind: CapabilityGateKind.mesh, initial: false);
}

/// SMS gate. True iff the device has an SMS-capable radio (Android, not iOS),
/// the SEND_SMS permission is granted, and the cellular radio is on.
///
/// Always `false` on iOS — the OS does not let apps send SMS, so there's no
/// path from `false → true` on that platform. The reason is the iOS
/// verbatim message from `detect.dart` so the disclosure screen shows
/// the same text as the §3.1 first-launch disclosure.
class SmsAvailableNotifier extends CapabilityGate {
  SmsAvailableNotifier()
      : super(kind: CapabilityGateKind.sms, initial: false);

  /// Standard iOS reason — extracted from `detect.dart` so this file does
  /// not need to import `dart:io` or take a hard dependency on the
  /// platform-detect module.
  static const String iosReason =
      "Apple doesn't allow apps to send or read SMS automatically";

  /// Force the gate to its iOS-false state with the spec reason. This is
  /// the one transition Agent C cannot trigger from real signals on iOS
  /// (no permission revoke callback) — so the gate keeps a toggle for it.
  void setUnavailableIos() {
    super.update(false, reason: iosReason);
  }
}

/// Internet gate. True iff the device has connectivity — Wi-Fi or
/// cellular data. The actual reachability check is the platform
/// connectivity plugin's responsibility (out of scope for this file);
/// the gate is the runtime cache.
class InternetAvailableNotifier extends CapabilityGate {
  InternetAvailableNotifier()
      : super(kind: CapabilityGateKind.internet, initial: false);
}

/// Vault gate. True iff the Evidence Vault secure-storage backing is
/// accessible (we can read the wrapped vault wrapping key from
/// `flutter_secure_storage` without throwing). The same `VaultStore`
/// already probes this lazily when `decrypt` is called; the gate just
/// caches the result.
class VaultAvailableNotifier extends CapabilityGate {
  VaultAvailableNotifier()
      : super(kind: CapabilityGateKind.vault, initial: false);
}

/// Channels gate. True iff the local `ChannelKeyStore` reports at least
/// one joined channel. The `public` channel is auto-added by `init()`
/// (Ticket #15) so this is `true` immediately after `ChannelKeyStore`
/// finishes its bootstrap in `main.dart`.
class ChannelAvailableNotifier extends CapabilityGate {
  ChannelAvailableNotifier()
      : super(kind: CapabilityGateKind.channel, initial: false);
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// The single source of truth for the mesh-available flag. Read with
/// `ref.watch(meshAvailableProvider)`; write via
/// `ref.read(meshAvailableProvider.notifier).update(...)`.
final StateNotifierProvider<MeshAvailableNotifier, bool>
    meshAvailableProvider =
    StateNotifierProvider<MeshAvailableNotifier, bool>(
        (Ref ref) => MeshAvailableNotifier());

/// The single source of truth for the SMS-available flag.
final StateNotifierProvider<SmsAvailableNotifier, bool> smsAvailableProvider =
    StateNotifierProvider<SmsAvailableNotifier, bool>(
        (Ref ref) => SmsAvailableNotifier());

/// The single source of truth for the internet-available flag.
final StateNotifierProvider<InternetAvailableNotifier, bool>
    internetAvailableProvider =
    StateNotifierProvider<InternetAvailableNotifier, bool>(
        (Ref ref) => InternetAvailableNotifier());

/// The single source of truth for the vault-available flag.
final StateNotifierProvider<VaultAvailableNotifier, bool> vaultAvailableProvider =
    StateNotifierProvider<VaultAvailableNotifier, bool>(
        (Ref ref) => VaultAvailableNotifier());

/// The single source of truth for the channels-joined flag.
final StateNotifierProvider<ChannelAvailableNotifier, bool>
    channelAvailableProvider =
    StateNotifierProvider<ChannelAvailableNotifier, bool>(
        (Ref ref) => ChannelAvailableNotifier());

// ---------------------------------------------------------------------------
// CapabilityTimeline provider
// ---------------------------------------------------------------------------

/// Riverpod bridge over the process-wide [CapabilityTimeline] singleton.
///
/// Most code should subscribe to `capabilityEventsProvider`'s `Stream` and
/// rebuild on every event. Tests can also assert on
/// `CapabilityTimeline.instance().history` directly without going through
/// Riverpod.
final StreamProvider<CapabilityEvent> capabilityEventsProvider =
    StreamProvider<CapabilityEvent>(
        (Ref ref) => CapabilityTimeline.instance().events);
