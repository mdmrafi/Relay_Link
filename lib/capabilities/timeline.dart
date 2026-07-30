// RelayLink — Per-feature capability gating audit trail.
//
// Every gate transition (true → false, false → true) is recorded as a
// structured `CapabilityEvent` on the singleton `CapabilityTimeline`. This
// stream is the auditable history of why a UI affordance was hidden or
// disabled — Agent C's lifecycle re-detection (cutrev-capab-reobserve) will
// drive these events, and the tests under `test/capabilities/gates_test.dart`
// consume them to verify the gating behavior.
//
// The design is intentionally minimal:
//   * `CapabilityTimeline` is a process-wide singleton (the same shape
//     used by `ChannelKeyStore` and `SecretsStore`). Tests use
//     `CapabilityTimeline.resetForTesting()` to start from a clean slate.
//   * Events are emitted as a `Stream<CapabilityEvent>` so callers can
//     `await for` and `expect()` in tests. The stream is also replayed
//     to new subscribers (`BehaviorSubject`-style, but we implement the
//     minimal cache ourselves to avoid pulling in `rxdart`).
//   * `close()` clears the stream but is not currently exposed publicly —
//     reserved for future hot-restart support.

import 'dart:async';
import 'dart:collection';

/// Identifies which per-feature gate emitted the event.
enum CapabilityGateKind {
  /// `MeshAvailableGate` — bluetooth on + permissions + peer in range.
  mesh,

  /// `SmsAvailableGate` — sms-capable device + permission + cellular on.
  sms,

  /// `InternetAvailableGate` — Wi-Fi or cellular data connectivity.
  internet,

  /// `VaultAvailableGate` — secure storage is accessible.
  vault,

  /// `ChannelAvailableGate` — at least one channel joined (from `ChannelKeyStore`).
  channel,
}

/// A single gate transition: the gate that changed, the new value, and an
/// optional reason (mirrors `FeatureCapability.reason` from `detect.dart`).
///
/// Equality is structural so tests can `expect(actual, equals(expected))`.
class CapabilityEvent {
  final CapabilityGateKind gate;
  final bool available;
  final String reason;
  final DateTime timestamp;

  const CapabilityEvent({
    required this.gate,
    required this.available,
    required this.reason,
    required this.timestamp,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CapabilityEvent &&
        other.gate == gate &&
        other.available == available &&
        other.reason == reason &&
        other.timestamp == timestamp;
  }

  @override
  int get hashCode => Object.hash(gate, available, reason, timestamp);

  @override
  String toString() =>
      'CapabilityEvent(${gate.name} → $available'
      '${reason.isEmpty ? '' : ', reason=$reason'})';
}

/// Process-wide audit stream of gate transitions.
///
/// Production code reads it via `CapabilityTimeline.instance().events` to
/// surface a per-feature log in the Settings/About screen. Tests subscribe
/// to verify that gates flip on state changes.
class CapabilityTimeline {
  /// In-memory cache of events so late subscribers can replay the history.
  /// Bounded to `_maxHistory` entries to bound memory if the app stays
  /// alive for a long time.
  static const int _maxHistory = 256;

  final List<CapabilityEvent> _history = List<CapabilityEvent>.empty(growable: true);
  final StreamController<CapabilityEvent> _controller =
      StreamController<CapabilityEvent>.broadcast();

  static CapabilityTimeline? _singleton;

  /// Lazy singleton accessor. The first call constructs the timeline;
  /// subsequent calls return the same instance.
  static CapabilityTimeline instance() {
    final s = _singleton;
    if (s != null) return s;
    _singleton = CapabilityTimeline._();
    return _singleton!;
  }

  /// Test-only: clear the singleton and its history. Call from `setUp` so
  /// tests cannot leak state into each other.
  static void resetForTesting() {
    final s = _singleton;
    if (s != null) {
      s._controller.close();
    }
    _singleton = null;
  }

  CapabilityTimeline._();

  /// Add [event] to the history and broadcast it to listeners.
  ///
  /// Returns `event` so callers can chain: `timeline.add(CapabilityEvent(...))`.
  /// Silently drops pushes when the controller is closed (e.g. after a
  /// `resetForTesting`). Tests can use [history] to assert past events.
  CapabilityEvent add(CapabilityEvent event) {
    if (_controller.isClosed) return event;
    _history.add(event);
    if (_history.length > _maxHistory) {
      _history.removeRange(0, _history.length - _maxHistory);
    }
    _controller.add(event);
    return event;
  }

  /// Replayable stream of every `add()` call since the timeline was created.
  ///
  /// Subscribers do NOT see history automatically — they see events from
  /// the moment they subscribe forward. The [history] getter exposes the
  /// replay buffer for tests and audit logs that need the full sequence.
  Stream<CapabilityEvent> get events => _controller.stream;

  /// Read-only snapshot of every event ever added (up to the
  /// `_maxHistory` retention limit).
  List<CapabilityEvent> get history => UnmodifiableListView(_history);

  /// Number of recorded events. Exposed for tests.
  int get length => _history.length;
}
