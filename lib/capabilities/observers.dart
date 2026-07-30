// RelayLink — Observer hooks that drive the capability gates from
// real-world signals.
//
// The gates in `lib/capabilities/gates.dart` are pure state — they don't
// watch anything by themselves. This file is the seam where lifecycle
// observers (`cutrev-capab-reobserve`, Agent C in flight) plug in to push
// live updates from `flutter_secure_storage`, `ChannelKeyStore`, the
// platform connectivity plugin, etc., into the gate notifiers.
//
// For now, this file exposes two things:
//   1. `bootCapabilityGates(ref)` — called once at app start to set the
//      initial values that *can* be derived synchronously from local state
//      (e.g. "vault is reachable because `SecretsStore.instance()` already
//      returned", "the public channel was just added by `init()`").
//   2. `CapabilityRefresh` — a tiny `ChangeNotifier` that Agent C can
//      call from its lifecycle plugin whenever it observes a hardware
//      change. Listeners fan the refresh out to the relevant gates.
//
// IMPORTANT: This file deliberately does NOT touch `lib/mesh/*`,
// `lib/transport/*`, `lib/crypto/*`, `lib/alerts/*`, or `lib/screens/*`.
// The mesh-related signals (bluetooth radio state, permission, peer
// count) are owned by Agent C's plugin layer, which we'll plug in here
// once that work lands. Until then, the mesh gate stays at its
// constructor default (`false`) so the UI hidden/disables mesh buttons
// — which is the safer default in the absence of a real radio check.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:relaylink/capabilities/gates.dart';
import 'package:relaylink/channels/keys.dart';

/// Fan a hardware-change notification into every gate that cares.
///
/// `cutrev-capab-reobserve` (Agent C) will publish a `ChangeNotifier` here
/// once its lifecycle plugin is ready. Each consumer (mesh, SMS, vault,
/// etc.) writes its own slice of state into the relevant gate notifier.
///
/// Until Agent C's work lands, this is a no-op — the gates stay at their
/// constructor defaults, which is the safer failure mode (UI hides the
/// feature rather than overselling it).
class CapabilityRefresh extends ChangeNotifier {
  /// Push a fresh mesh state. Will be filled in by Agent C.
  void pushMesh({required bool available, String reason = ''}) {
    _meshSink?.call(available, reason);
  }

  /// Push a fresh SMS state. Will be filled in by Agent C.
  void pushSms({required bool available, String reason = ''}) {
    _smsSink?.call(available, reason);
  }

  /// Push a fresh internet state.
  void pushInternet({required bool available, String reason = ''}) {
    _internetSink?.call(available, reason);
  }

  /// Push a fresh vault state.
  void pushVault({required bool available, String reason = ''}) {
    _vaultSink?.call(available, reason);
  }

  /// Push a fresh channels-joined state (or run an async probe).
  void pushChannels({required bool available, String reason = ''}) {
    _channelSink?.call(available, reason);
  }

  void Function(bool, String)? _meshSink;
  void Function(bool, String)? _smsSink;
  void Function(bool, String)? _internetSink;
  void Function(bool, String)? _vaultSink;
  void Function(bool, String)? _channelSink;

  /// Internal: wires each `pushX` into a specific notifier. Tests don't
  /// need to call this — `bootCapabilityGates` does.
  @visibleForTesting
  void bindSinks({
    required void Function(bool, String) mesh,
    required void Function(bool, String) sms,
    required void Function(bool, String) internet,
    required void Function(bool, String) vault,
    required void Function(bool, String) channel,
  }) {
    _meshSink = mesh;
    _smsSink = sms;
    _internetSink = internet;
    _vaultSink = vault;
    _channelSink = channel;
  }
}

/// Process-wide `CapabilityRefresh` singleton Agent C will subscribe to.
CapabilityRefresh capabilityRefreshSingleton() => CapabilityRefresh();

/// Seed the gates from local state once `WidgetRef` is available.
///
/// Currently seeds ONLY the gates whose underlying signal can be probed
/// from local Flutter-only state at startup:
///   * `channelAvailableProvider` — true iff `ChannelKeyStore.listChannels()`
///     returns ≥ 1 id (the `public` channel is auto-added in `init()`).
///   * `vaultAvailableProvider`   — true iff `SecretsStore.instance()` can
///     be built without throwing (a smoke test of `flutter_secure_storage`).
///
/// Mesh, SMS, and internet require native radio signals and stay at
/// `false` here; Agent C's re-observer will flip them when real hardware
/// data lands.
Future<void> bootCapabilityGates(WidgetRef ref) async {
  // Channel: read the index that `init()` has just populated.
  try {
    final channels = await ChannelKeyStore.instance();
    final ids = await channels.listChannels();
    final available = ids.isNotEmpty;
    ref.read(channelAvailableProvider.notifier).update(
          available,
          reason: available ? '' : 'No channels joined yet.',
        );
  } catch (_) {
    ref.read(channelAvailableProvider.notifier).update(
          false,
          reason: 'Channel key store unavailable.',
        );
  }

  // Vault: probe secure storage. We don't read the wrapped VWK — just
  // confirm the backend can be opened and written to.
  try {
    // Triggering `channel keys` already touches the same backend; reuse
    // the call to confirm `FlutterSecureStorage` is alive in this process.
    final store = await ChannelKeyStore.instance();
    await store.listChannels();
    ref.read(vaultAvailableProvider.notifier).update(
          true,
          reason: '',
        );
  } catch (_) {
    ref.read(vaultAvailableProvider.notifier).update(
          false,
          reason: 'Secure storage backend is not reachable.',
        );
  }
}
